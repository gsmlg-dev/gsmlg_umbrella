defmodule GSMLG.BrowserAgent.SafeBrowser.CDP do
  @moduledoc "Fixed CDP implementation behind the structured SafeBrowser contract."

  @behaviour GSMLG.BrowserAgent.SafeBrowser.Adapter

  alias GSMLG.BrowserAgent.{Action, Locator}
  alias GSMLG.BrowserAgent.CDP.Client

  @form_elements ~w(button input select textarea)
  @editable_roles ~w(combobox searchbox spinbutton textbox)
  @safe_dom_attributes ~w(data-testid data-test id name aria-label type autocomplete placeholder)
  @sensitive_autocomplete ~w(current-password new-password one-time-code cc-number cc-csc)
  @max_dom_metadata_nodes 256
  @max_dom_attribute_pairs 32
  @max_dom_attribute_bytes 512

  @impl true
  def observation_epoch(client), do: client_call(client, :document_epoch, [])

  @impl true
  def cleanup_output(client, {:download, token, deadline}),
    do: client_call(client, :finish_download, [token, cleanup_timeout(client, deadline)])

  @impl true
  def observe(client, timeout) when is_integer(timeout) and timeout > 0 do
    deadline = now(client) + timeout
    observe_consistent(client, deadline, 1)
  end

  defp observe_consistent(client, deadline, retries_left) do
    with {:ok, before_epoch} <- client_call(client, :document_epoch, []),
         {:ok, observation} <- capture_observation(client, deadline),
         true <- remaining(client, deadline) > 0,
         {:ok, after_epoch} <- client_call(client, :document_epoch, []) do
      if before_epoch == after_epoch do
        {:ok, observation}
      else
        retry_inconsistent_observation(client, deadline, retries_left)
      end
    else
      false -> {:error, :cdp_timeout}
      {:error, _reason} = error -> error
      _invalid -> {:error, :cdp_invalid_response}
    end
  end

  defp retry_inconsistent_observation(client, deadline, retries_left)
       when retries_left > 0 do
    if remaining(client, deadline) > 0,
      do: observe_consistent(client, deadline, retries_left - 1),
      else: {:error, :stale_observation}
  end

  defp retry_inconsistent_observation(_client, _deadline, _retries_left),
    do: {:error, :stale_observation}

  defp capture_observation(client, deadline) do
    {module, socket} = client(client)

    with {:ok, history} <- timed_apply(client, module, socket, :navigation_history, [], deadline),
         {:ok, page} <- current_page(history),
         {:ok, %{"nodes" => nodes}} when is_list(nodes) <-
           timed_apply(client, module, socket, :accessibility_tree, [], deadline),
         true <- Enum.all?(nodes, &is_map/1) do
      semantic_nodes =
        normalize_ax_nodes(client, Enum.take(nodes, @max_dom_metadata_nodes), deadline)

      {:ok,
       %{
         "url" => page["url"],
         "title" => page["title"],
         "loading_state" => "complete",
         "page_kind" => "document",
         "alerts" => alerts(semantic_nodes),
         "nodes" => semantic_nodes,
         "focused_element" => Enum.find(semantic_nodes, &get_in(&1, ["state", "focused"]))
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :cdp_invalid_response}
    end
  end

  @impl true
  def execute(client, %Action{type: :navigate, input: %{"url" => url}}, nil, timeout) do
    deadline = now(client) + timeout
    timed_client_call(client, :navigate, [url], deadline) |> empty_output()
  end

  def execute(client, %Action{type: :click}, target, timeout) do
    click(client, target, now(client) + timeout)
  end

  def execute(client, %Action{type: :download}, target, timeout) do
    deadline = now(client) + timeout

    case timed_client_call(client, :prepare_download, [], deadline) do
      {:ok, token} -> execute_download(client, target, token, deadline)
      {:error, _reason} = error -> error
    end
  end

  def execute(client, %Action{type: :focus}, target, timeout) do
    deadline = now(client) + timeout

    with {:ok, backend_node_id} <- backend_node_id(client, target, deadline),
         {:ok, _result} <- timed_client_call(client, :focus, [backend_node_id], deadline) do
      {:ok, %{}}
    end
  end

  def execute(client, %Action{type: :fill, input: %{"text" => text}}, target, timeout) do
    deadline = now(client) + timeout

    with {:ok, backend_node_id} <- backend_node_id(client, target, deadline),
         {:ok, _} <- timed_client_call(client, :focus, [backend_node_id], deadline),
         {:ok, _} <- timed_client_call(client, :key_event, ["rawKeyDown", "a", 2], deadline),
         {:ok, _} <- timed_client_call(client, :key_event, ["keyUp", "a", 2], deadline),
         {:ok, _} <- timed_client_call(client, :insert_text, [text], deadline) do
      {:ok, %{}}
    end
  end

  def execute(client, %Action{type: :insert_text, input: %{"text" => text}}, target, timeout) do
    deadline = now(client) + timeout

    with {:ok, backend_node_id} <- backend_node_id(client, target, deadline),
         {:ok, _} <- timed_client_call(client, :focus, [backend_node_id], deadline),
         {:ok, _} <- timed_client_call(client, :insert_text, [text], deadline) do
      {:ok, %{}}
    end
  end

  def execute(client, %Action{type: :press_key, input: %{"key" => key}}, nil, timeout) do
    deadline = now(client) + timeout

    with {:ok, _} <- timed_client_call(client, :key_event, ["keyDown", key, 0], deadline),
         {:ok, _} <- timed_client_call(client, :key_event, ["keyUp", key, 0], deadline) do
      {:ok, %{}}
    end
  end

  def execute(
        client,
        %Action{type: :select_option, input: %{"value" => value}},
        target,
        timeout
      ) do
    deadline = now(client) + timeout

    with {:ok, backend_node_id} <- backend_node_id(client, target, deadline),
         {:ok, _} <- timed_client_call(client, :focus, [backend_node_id], deadline),
         {:ok, _} <- timed_client_call(client, :insert_text, [value], deadline),
         {:ok, _} <- timed_client_call(client, :key_event, ["keyDown", "Enter", 0], deadline),
         {:ok, _} <- timed_client_call(client, :key_event, ["keyUp", "Enter", 0], deadline) do
      {:ok, %{}}
    end
  end

  def execute(
        client,
        %Action{type: :scroll, input: %{"delta_x" => x, "delta_y" => y}},
        nil,
        timeout
      ) do
    deadline = now(client) + timeout
    timed_client_call(client, :scroll, [x, y], deadline) |> empty_output()
  end

  def execute(_client, %Action{type: :wait_for}, _target, _timeout), do: {:ok, %{}}
  def execute(_client, %Action{type: :extract}, target, _timeout), do: {:ok, %{"node" => target}}

  def execute(client, %Action{type: :screenshot}, nil, timeout) do
    deadline = now(client) + timeout

    with {:ok, %{"data" => data}} when is_binary(data) <-
           timed_client_call(client, :screenshot, [], deadline),
         {:ok, content} <- Base.decode64(data),
         true <- remaining(client, deadline) > 0 do
      {:ok, {:artifact, "screenshot", "image/png", content}}
    else
      false -> {:error, :cdp_timeout}
      {:error, _reason} = error -> error
      _invalid -> {:error, :cdp_invalid_response}
    end
  end

  def execute(_client, _action, _target, _timeout), do: {:error, :action_not_allowed}

  @spec resolve_css(term(), Locator.t(), pos_integer()) ::
          {:ok, map()} | {:error, :action_target_not_found | atom()}
  def resolve_css(client, %Locator{type: :css, value: selector}, timeout) do
    resolve_css_until(client, selector, now(client) + timeout)
  end

  defp resolve_css_until(client, selector, deadline) do
    with {:ok, %{"root" => %{"nodeId" => root_id}}} <-
           timed_client_call(client, :document, [], deadline),
         {:ok, %{"nodeId" => node_id}} when is_integer(node_id) and node_id > 0 <-
           timed_client_call(client, :query_selector, [root_id, selector], deadline),
         {:ok, %{"node" => %{"backendNodeId" => backend_node_id}}}
         when is_integer(backend_node_id) and backend_node_id > 0 <-
           timed_client_call(client, :describe_node, [node_id], deadline) do
      {:ok, %{"backend_node_id" => backend_node_id}}
    else
      {:ok, %{"nodeId" => 0}} -> {:error, :action_target_not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :cdp_invalid_response}
    end
  end

  @impl true
  def resolve_locator(client, %Locator{type: :css} = locator, timeout),
    do: resolve_css(client, locator, timeout)

  def resolve_locator(_client, _locator, _timeout), do: {:error, :action_target_not_found}

  defp click(client, target, deadline) do
    with {:ok, backend_node_id} <- backend_node_id(client, target, deadline),
         {:ok, %{"model" => %{"content" => quad}}} <-
           timed_client_call(client, :box_model, [backend_node_id], deadline),
         {:ok, {x, y}} <- quad_center(quad),
         {:ok, _} <- timed_client_call(client, :mouse_event, ["mousePressed", x, y], deadline),
         {:ok, _} <- timed_client_call(client, :mouse_event, ["mouseReleased", x, y], deadline) do
      {:ok, %{}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :action_target_not_found}
    end
  end

  defp execute_download(client, target, token, deadline) do
    with {:ok, %{}} <- click(client, target, deadline),
         {:ok,
          %{
            content: content,
            source_url: source_url,
            suggested_filename: filename
          }} <- timed_client_call(client, :await_download, [token], deadline) do
      mime = download_mime(filename)

      {:ok,
       {:artifact, "download", mime, content,
        %{"source_url" => source_url, "suggested_filename" => filename},
        {:download, token, deadline}}}
    else
      {:error, _reason} = error ->
        case client_call(client, :finish_download, [token, cleanup_timeout(client, deadline)]) do
          :ok -> error
          {:error, _reason} = cleanup_error -> cleanup_error
        end
    end
  end

  defp download_mime(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".pdf" -> "application/pdf"
      ".json" -> "application/json"
      ".html" -> "text/html"
      ".md" -> "text/markdown"
      ".txt" -> "text/plain"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      _extension -> "application/octet-stream"
    end
  end

  defp backend_node_id(client, %Locator{type: :css, value: selector}, deadline) do
    with {:ok, %{"backend_node_id" => backend_node_id}} <-
           resolve_css_until(client, selector, deadline),
         do: {:ok, backend_node_id}
  end

  defp backend_node_id(_client, %{"backend_node_id" => id}, _timeout)
       when is_integer(id) and id > 0,
       do: {:ok, id}

  defp backend_node_id(_client, _target, _timeout), do: {:error, :action_target_not_found}

  defp quad_center([x1, y1, x2, y2, x3, y3, x4, y4])
       when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) and
              is_number(x3) and is_number(y3) and is_number(x4) and is_number(y4),
       do: {:ok, {(x1 + x2 + x3 + x4) / 4, (y1 + y2 + y3 + y4) / 4}}

  defp quad_center(_invalid), do: {:error, :action_target_not_found}

  defp current_page(%{"currentIndex" => index, "entries" => entries})
       when is_integer(index) and is_list(entries) do
    case Enum.at(entries, index) do
      %{"url" => url, "title" => title} = page when is_binary(url) and is_binary(title) ->
        {:ok, page}

      _invalid ->
        {:error, :cdp_invalid_response}
    end
  end

  defp current_page(_invalid), do: {:error, :cdp_invalid_response}

  defp normalize_ax_nodes(client, nodes, deadline) do
    parents = Map.new(nodes, fn node -> {node["nodeId"], node["parentId"]} end)

    nodes
    |> Enum.map(fn node ->
      normalized =
        %{
          "node_id" => node["nodeId"],
          "backend_node_id" => node["backendDOMNodeId"],
          "role" => ax_value(node["role"]),
          "name" => ax_value(node["name"]),
          "value" => ax_value(node["value"]),
          "state" => ax_properties(node["properties"]),
          "depth" => node_depth(node["nodeId"], parents),
          "visible" => node["ignored"] != true
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      enrich_from_dom(client, normalized, node, deadline)
    end)
  end

  defp enrich_from_dom(
         client,
         %{"backend_node_id" => backend_id} = node,
         ax_node,
         deadline
       )
       when is_integer(backend_id) and backend_id > 0 do
    case remaining(client, deadline) do
      remaining when remaining > 0 ->
        fetch_dom_metadata(client, node, ax_node, backend_id, remaining)

      _expired ->
        redact_unclassified_input(node)
    end
  end

  defp enrich_from_dom(_client, node, _ax_node, _deadline),
    do: redact_unclassified_input(node)

  defp fetch_dom_metadata(client, node, ax_node, backend_id, timeout) do
    case client_call(client, :describe_backend_node, [backend_id, timeout]) do
      {:ok, %{"node" => dom_node}} when is_map(dom_node) ->
        merge_dom_metadata(node, ax_node, dom_node)

      _unavailable ->
        redact_unclassified_input(node)
    end
  end

  defp merge_dom_metadata(node, ax_node, dom_node) do
    attributes = dom_attributes(dom_node["attributes"])
    safe_attributes = Map.take(attributes, @safe_dom_attributes)

    metadata =
      %{
        "attributes" => safe_attributes,
        "input_type" => attributes["type"],
        "placeholder" => attributes["placeholder"],
        "label" => semantic_label(node, ax_node, attributes)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    enriched = Map.merge(node, metadata)

    if editable_form_control?(enriched, dom_node) or sensitive_attributes?(attributes) do
      Map.put(enriched, "value", "[REDACTED]")
    else
      enriched
    end
  end

  defp dom_attributes(attributes) when is_list(attributes),
    do: dom_attributes(attributes, %{}, 0)

  defp dom_attributes(_attributes), do: %{}

  defp dom_attributes(_attributes, attributes, count) when count >= @max_dom_attribute_pairs,
    do: attributes

  defp dom_attributes([name, value | rest], attributes, count)
       when is_binary(name) and is_binary(value) do
    normalized_name = String.downcase(name)

    attributes =
      if normalized_name in @safe_dom_attributes and String.valid?(value) do
        Map.put(attributes, normalized_name, truncate_utf8(value, @max_dom_attribute_bytes))
      else
        attributes
      end

    dom_attributes(rest, attributes, count + 1)
  end

  defp dom_attributes([_name, _value | rest], attributes, count),
    do: dom_attributes(rest, attributes, count + 1)

  defp dom_attributes(_rest, attributes, _count), do: attributes

  defp semantic_label(node, ax_node, attributes) do
    cond do
      present_string?(attributes["aria-label"]) -> attributes["aria-label"]
      label_source?(ax_node["name"]) and present_string?(node["name"]) -> node["name"]
      true -> nil
    end
  end

  defp label_source?(%{"sources" => sources}) when is_list(sources) do
    Enum.any?(sources, fn
      %{"superseded" => true} -> false
      %{"nativeSource" => source} when source in ["label", "labelfor", "labelwrapped"] -> true
      %{"attribute" => attribute} when attribute in ["aria-label", "aria-labelledby"] -> true
      _other -> false
    end)
  end

  defp label_source?(_name), do: false

  defp sensitive_attributes?(attributes) do
    String.downcase(attributes["type"] || "") == "password" or
      String.downcase(attributes["autocomplete"] || "") in @sensitive_autocomplete
  end

  defp editable_form_control?(node, dom_node) do
    node["role"] in @editable_roles or
      String.downcase(to_string(dom_node["localName"] || "")) in @form_elements
  end

  defp redact_unclassified_input(%{"role" => role, "value" => _value} = node)
       when role in @editable_roles,
       do: Map.put(node, "value", "[REDACTED]")

  defp redact_unclassified_input(node), do: node

  defp present_string?(value), do: is_binary(value) and value != ""

  defp truncate_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_utf8(value, max_bytes) do
    candidate = binary_part(value, 0, max_bytes)
    trim_to_valid_utf8(candidate)
  end

  defp trim_to_valid_utf8(value) do
    if String.valid?(value),
      do: value,
      else: trim_to_valid_utf8(binary_part(value, 0, byte_size(value) - 1))
  end

  defp remaining(client, deadline), do: max(deadline - now(client), 0)

  defp cleanup_timeout(client, deadline), do: max(remaining(client, deadline), 1)

  defp node_depth(node_id, parents), do: node_depth(node_id, parents, MapSet.new(), 0)

  defp node_depth(node_id, parents, seen, depth) when depth < 64 do
    case Map.get(parents, node_id) do
      parent when is_binary(parent) ->
        if MapSet.member?(seen, parent) do
          depth
        else
          node_depth(parent, parents, MapSet.put(seen, node_id), depth + 1)
        end

      _root ->
        depth
    end
  end

  defp node_depth(_node_id, _parents, _seen, depth), do: depth

  defp ax_value(%{"value" => value})
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: value

  defp ax_value(_invalid), do: nil

  defp ax_properties(properties) when is_list(properties) do
    properties
    |> Enum.reduce(%{}, fn
      %{"name" => name, "value" => value}, state when is_binary(name) ->
        case ax_value(value) do
          nil -> state
          normalized -> Map.put(state, name, normalized)
        end

      _invalid, state ->
        state
    end)
  end

  defp ax_properties(_invalid), do: %{}

  defp alerts(nodes) do
    nodes
    |> Enum.filter(&(&1["role"] in ["alert", "alertdialog", "status"]))
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  defp client({module, socket, clock}) when is_atom(module) and is_function(clock, 0),
    do: {module, socket}

  defp client({module, socket}) when is_atom(module), do: {module, socket}
  defp client(socket), do: {Client, socket}

  defp now({_module, _socket, clock}) when is_function(clock, 0), do: clock.()
  defp now(_client), do: System.monotonic_time(:millisecond)

  defp timed_client_call(client, function, arguments, deadline) do
    {module, socket} = client(client)
    timed_apply(client, module, socket, function, arguments, deadline)
  end

  defp timed_apply(client, module, socket, function, arguments, deadline) do
    case remaining(client, deadline) do
      timeout when timeout > 0 ->
        case safe_apply(module, function, [socket | arguments] ++ [timeout]) do
          {:ok, _result} = result ->
            if remaining(client, deadline) > 0, do: result, else: {:error, :cdp_timeout}

          result ->
            result
        end

      _expired ->
        {:error, :cdp_timeout}
    end
  end

  defp client_call(client, function, arguments) do
    {module, socket} = client(client)
    safe_apply(module, function, [socket | arguments])
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> {:error, :cdp_disconnected}
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  defp empty_output({:ok, _result}), do: {:ok, %{}}
  defp empty_output({:error, _reason} = error), do: error
end
