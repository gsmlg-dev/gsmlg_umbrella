defmodule GSMLG.BrowserAgent.CDPAdapterTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{Action, Locator}
  alias GSMLG.BrowserAgent.SafeBrowser.CDP, as: Adapter

  defmodule Client do
    def navigation_history(client, _timeout) do
      record(client, :navigation_history)

      {:ok,
       %{
         "currentIndex" => 0,
         "entries" => [
           %{
             "id" => 1,
             "url" => "https://gemini.google.com/app",
             "title" => "Gemini"
           }
         ]
       }}
    end

    def document_epoch(_client), do: {:ok, 0}

    def accessibility_tree(client, _timeout) do
      record(client, :accessibility_tree)

      {:ok,
       %{
         "nodes" => [
           %{
             "nodeId" => "root",
             "role" => %{"value" => "document"},
             "name" => %{"value" => "Gemini"},
             "childIds" => ["submit"]
           },
           %{
             "nodeId" => "submit",
             "parentId" => "root",
             "backendDOMNodeId" => 41,
             "role" => %{"value" => "button"},
             "name" => %{"value" => "Submit"},
             "properties" => [%{"name" => "focused", "value" => %{"value" => true}}]
           },
           %{
             "nodeId" => "email",
             "parentId" => "root",
             "backendDOMNodeId" => 42,
             "role" => %{"value" => "textbox"},
             "name" => %{
               "value" => "Email",
               "sources" => [%{"attribute" => "aria-labelledby"}]
             },
             "value" => %{"value" => "person@example.com"}
           },
           %{
             "nodeId" => "password",
             "parentId" => "root",
             "backendDOMNodeId" => 43,
             "role" => %{"value" => "textbox"},
             "name" => %{
               "value" => "密碼",
               "sources" => [%{"nativeSource" => "label"}]
             },
             "value" => %{"value" => "super-secret"}
           },
           %{
             "nodeId" => "placeholder-only",
             "parentId" => "root",
             "backendDOMNodeId" => 44,
             "role" => %{"value" => "searchbox"},
             "name" => %{
               "value" => "Search terms",
               "sources" => [%{"attribute" => "placeholder"}]
             },
             "value" => %{"value" => "private search"}
           },
           %{
             "nodeId" => "unclassified",
             "parentId" => "root",
             "backendDOMNodeId" => 45,
             "role" => %{"value" => "textbox"},
             "name" => %{"value" => "秘密"},
             "value" => %{"value" => "unmarked secret"}
           }
         ]
       }}
    end

    def describe_backend_node(client, backend_node_id, _timeout) do
      record(client, {:describe_backend_node, backend_node_id})

      node =
        case backend_node_id do
          41 ->
            %{
              "backendNodeId" => 41,
              "localName" => "button",
              "attributes" => ["data-testid", "submit", "onclick", "stealSecrets()"]
            }

          42 ->
            %{
              "backendNodeId" => 42,
              "localName" => "input",
              "attributes" => [
                "type",
                "email",
                "placeholder",
                "Email address",
                "data-test",
                "prompt",
                "value",
                "person@example.com"
              ]
            }

          43 ->
            %{
              "backendNodeId" => 43,
              "localName" => "input",
              "attributes" => [
                "type",
                "password",
                "autocomplete",
                "current-password",
                "value",
                "super-secret"
              ]
            }

          44 ->
            %{
              "backendNodeId" => 44,
              "localName" => "input",
              "attributes" => [
                "type",
                "search",
                "placeholder",
                "Search terms",
                "value",
                "private search"
              ]
            }

          45 ->
            raise "DOM metadata unavailable"
        end

      {:ok, %{"node" => node}}
    end

    def navigate(client, url, _timeout), do: ok(client, {:navigate, url})
    def focus(client, id, _timeout), do: ok(client, {:focus, id})

    def box_model(client, id, _timeout) do
      record(client, {:box_model, id})
      {:ok, %{"model" => %{"content" => [10, 20, 30, 20, 30, 40, 10, 40]}}}
    end

    def mouse_event(client, type, x, y, _timeout), do: ok(client, {:mouse, type, x, y})
    def insert_text(client, text, _timeout), do: ok(client, {:insert_text, text})

    def key_event(client, type, key, modifiers, _timeout),
      do: ok(client, {:key, type, key, modifiers})

    def scroll(client, x, y, _timeout), do: ok(client, {:scroll, x, y})

    def screenshot(client, _timeout),
      do:
        (
          record(client, :screenshot)
          {:ok, %{"data" => "cG5n"}}
        )

    def prepare_download(client, _timeout) do
      record(client, :prepare_download)
      {:ok, :download_token}
    end

    def await_download(client, :download_token, _timeout) do
      record(client, :await_download)

      {:ok,
       %{
         content: "{}",
         source_url: "https://gemini.google.com/report.json?secret=query",
         suggested_filename: "../report.json"
       }}
    end

    def finish_download(client, :download_token, _timeout),
      do:
        (
          record(client, :finish_download)
          :ok
        )

    def document(client, _timeout),
      do:
        (
          record(client, :document)
          {:ok, %{"root" => %{"nodeId" => 1}}}
        )

    def query_selector(client, 1, selector, _timeout),
      do:
        (
          record(client, {:query_selector, selector})
          {:ok, %{"nodeId" => 9}}
        )

    def describe_node(client, 9, _timeout),
      do:
        (
          record(client, :describe_node)
          {:ok, %{"node" => %{"backendNodeId" => 99}}}
        )

    defp ok(client, event),
      do:
        (
          record(client, event)
          {:ok, %{}}
        )

    defp record(client, event), do: Agent.update(client, &[event | &1])
  end

  defmodule ChangingEpochClient do
    def document_epoch(client) do
      Agent.get_and_update(client, fn %{epochs: [epoch | rest]} = state ->
        {{:ok, epoch}, %{state | epochs: rest}}
      end)
    end

    def navigation_history(client, _timeout) do
      Agent.update(client, &Map.update!(&1, :captures, fn count -> count + 1 end))

      {:ok,
       %{
         "currentIndex" => 0,
         "entries" => [%{"url" => "https://gemini.google.com/app", "title" => "Gemini"}]
       }}
    end

    def accessibility_tree(_client, _timeout), do: {:ok, %{"nodes" => []}}
  end

  defmodule LargeTreeClient do
    def document_epoch(_client), do: {:ok, 0}

    def navigation_history(_client, _timeout) do
      {:ok,
       %{
         "currentIndex" => 0,
         "entries" => [%{"url" => "https://gemini.google.com/app", "title" => "Gemini"}]
       }}
    end

    def accessibility_tree(_client, _timeout) do
      nodes =
        for id <- 1..300 do
          %{
            "nodeId" => Integer.to_string(id),
            "backendDOMNodeId" => id,
            "role" => %{"value" => "button"},
            "name" => %{"value" => "Button"}
          }
        end

      {:ok, %{"nodes" => nodes}}
    end

    def describe_backend_node(client, id, _timeout) do
      Agent.update(client, &(&1 + 1))

      {:ok,
       %{
         "node" => %{
           "backendNodeId" => id,
           "localName" => "button",
           "attributes" => [
             "data-testid",
             String.duplicate("🌙", 200),
             "onclick",
             String.duplicate("x", 10_000)
           ]
         }
       }}
    end
  end

  defmodule DeadlineClient do
    def focus(state, _id, timeout), do: step(state, {:focus, timeout}, timeout)

    def key_event(state, type, _key, _modifiers, timeout),
      do: step(state, {:key, type, timeout}, timeout)

    def insert_text(state, _text, timeout), do: step(state, {:insert_text, timeout}, timeout)

    def prepare_download(state, timeout),
      do: step(state, {:prepare_download, timeout}, timeout, :token)

    def box_model(state, _id, timeout) do
      step(
        state,
        {:box_model, timeout},
        timeout,
        %{"model" => %{"content" => [0, 0, 2, 0, 2, 2, 0, 2]}}
      )
    end

    def mouse_event(state, type, _x, _y, timeout),
      do: step(state, {:mouse, type, timeout}, timeout)

    def await_download(state, :token, timeout),
      do: step(state, {:await_download, timeout}, timeout, %{})

    def finish_download(state, :token, timeout) do
      Agent.update(
        state,
        &update_in(&1.calls, fn calls -> [{:finish_download, timeout} | calls] end)
      )

      :ok
    end

    def document(state, timeout),
      do: step(state, {:document, timeout}, timeout, %{"root" => %{"nodeId" => 1}})

    def query_selector(state, 1, _selector, timeout),
      do: step(state, {:query_selector, timeout}, timeout, %{"nodeId" => 9})

    def describe_node(state, 9, timeout),
      do: step(state, {:describe_node, timeout}, timeout, %{"node" => %{"backendNodeId" => 99}})

    defp step(state, event, timeout, result \\ %{}) do
      Agent.update(state, fn current ->
        current
        |> Map.update!(:now, &(&1 + current.step_ms))
        |> update_in([:calls], &[event | &1])
      end)

      if timeout > 0, do: {:ok, result}, else: {:error, :cdp_timeout}
    end
  end

  setup do
    {:ok, client} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(client), do: Agent.stop(client) end)
    %{client: {Client, client}, state: client}
  end

  test "derives a semantic observation from navigation and accessibility domains", context do
    assert {:ok,
            %{
              "url" => "https://gemini.google.com/app",
              "title" => "Gemini",
              "nodes" => [root, submit, email, password, placeholder_only, unclassified]
            }} = Adapter.observe(context.client, 1_000)

    assert root["node_id"] == "root"
    assert root["depth"] == 0
    assert submit["node_id"] == "submit"
    assert submit["backend_node_id"] == 41
    assert submit["depth"] == 1
    assert submit["state"] == %{"focused" => true}
    assert submit["attributes"] == %{"data-testid" => "submit"}
    refute Map.has_key?(submit["attributes"], "onclick")

    assert email["label"] == "Email"
    assert email["placeholder"] == "Email address"
    assert email["input_type"] == "email"

    assert email["attributes"] == %{
             "data-test" => "prompt",
             "placeholder" => "Email address",
             "type" => "email"
           }

    assert email["value"] == "[REDACTED]"

    assert password["input_type"] == "password"
    assert password["label"] == "密碼"
    assert password["attributes"]["autocomplete"] == "current-password"
    assert password["value"] == "[REDACTED]"
    refute JSON.encode!([root, submit, email, password]) =~ "super-secret"

    assert placeholder_only["placeholder"] == "Search terms"
    refute Map.has_key?(placeholder_only, "label")
    assert placeholder_only["value"] == "[REDACTED]"
    assert unclassified["value"] == "[REDACTED]"

    assert {:ok, %{"node_id" => "email"}} =
             Locator.find(%{"semantic_tree" => [root, submit, email, password]}, %Locator{
               type: :label,
               value: "Email"
             })

    assert {:ok, %{"node_id" => "email"}} =
             Locator.find(%{"semantic_tree" => [root, submit, email, password]}, %Locator{
               type: :placeholder,
               value: "Email address"
             })

    assert {:ok, %{"node_id" => "submit"}} =
             Locator.find(%{"semantic_tree" => [root, submit, email, password]}, %Locator{
               type: :attribute,
               name: "data-testid",
               value: "submit"
             })

    assert [
             :navigation_history,
             :accessibility_tree,
             {:describe_backend_node, 41},
             {:describe_backend_node, 42},
             {:describe_backend_node, 43},
             {:describe_backend_node, 44},
             {:describe_backend_node, 45}
           ] = events(context.state)
  end

  test "maps structured actions to fixed CDP operations without script evaluation", context do
    target = %{"backend_node_id" => 41}

    actions = [
      action(:navigate, nil, %{"url" => "https://gemini.google.com/app"}),
      action(:click),
      action(:focus),
      action(:fill, nil, %{"text" => "replace"}),
      action(:insert_text, nil, %{"text" => "append"}),
      action(:press_key, nil, %{"key" => "Enter"}),
      action(:select_option, nil, %{"value" => "Fast"}),
      action(:scroll, nil, %{"delta_x" => 0, "delta_y" => 500}),
      action(:extract),
      action(:screenshot),
      action(:download)
    ]

    for action <- actions do
      target =
        if action.type in [:navigate, :press_key, :scroll, :screenshot], do: nil, else: target

      assert {:ok, output} = Adapter.execute(context.client, action, target, 1_000)

      if action.type == :download do
        assert {:artifact, "download", "application/json", "{}", _metadata,
                {:download, :download_token, deadline} = cleanup} = output

        assert is_integer(deadline)

        refute :finish_download in events(context.state)
        assert :ok = Adapter.cleanup_output(context.client, cleanup)
      end
    end

    events = events(context.state)
    assert {:navigate, "https://gemini.google.com/app"} in events
    assert {:mouse, "mousePressed", 20.0, 30.0} in events
    assert {:mouse, "mouseReleased", 20.0, 30.0} in events
    assert {:insert_text, "replace"} in events
    assert {:insert_text, "append"} in events
    assert {:key, "keyDown", "Enter", 0} in events
    assert {:scroll, 0, 500} in events
    assert :screenshot in events
    assert :prepare_download in events
    assert :await_download in events
    assert :finish_download in events
    refute inspect(events) =~ "Runtime.evaluate"
  end

  test "CSS fallback is resolved only through fixed DOM methods", context do
    locator = %Locator{type: :css, value: "[data-testid=submit]"}
    assert {:ok, %{"backend_node_id" => 99}} = Adapter.resolve_css(context.client, locator, 1_000)

    assert [:document, {:query_selector, "[data-testid=submit]"}, :describe_node] =
             events(context.state)
  end

  test "multi-command actions spend one injected monotonic deadline budget" do
    {:ok, state} = Agent.start_link(fn -> %{now: 0, step_ms: 4, calls: []} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    clock = fn -> Agent.get(state, & &1.now) end
    client = {DeadlineClient, state, clock}

    assert {:error, :cdp_timeout} =
             Adapter.execute(
               client,
               action(:fill, nil, %{"text" => "bounded"}),
               %{"backend_node_id" => 41},
               10
             )

    assert [
             {:focus, 10},
             {:key, "rawKeyDown", 6},
             {:key, "keyUp", 2}
           ] = state |> Agent.get(& &1.calls) |> Enum.reverse()
  end

  test "CSS locator commands cannot reset their injected deadline" do
    {:ok, state} = Agent.start_link(fn -> %{now: 0, step_ms: 4, calls: []} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    clock = fn -> Agent.get(state, & &1.now) end
    client = {DeadlineClient, state, clock}

    assert {:error, :cdp_timeout} =
             Adapter.resolve_css(client, %Locator{type: :css, value: "#submit"}, 10)

    assert [
             {:document, 10},
             {:query_selector, 6},
             {:describe_node, 2}
           ] = state |> Agent.get(& &1.calls) |> Enum.reverse()
  end

  test "download preparation, click, wait, and cleanup share one injected deadline" do
    {:ok, state} = Agent.start_link(fn -> %{now: 0, step_ms: 3, calls: []} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    clock = fn -> Agent.get(state, & &1.now) end
    client = {DeadlineClient, state, clock}

    assert {:error, :cdp_timeout} =
             Adapter.execute(client, action(:download), %{"backend_node_id" => 41}, 10)

    assert [
             {:prepare_download, 10},
             {:box_model, 7},
             {:mouse, "mousePressed", 4},
             {:mouse, "mouseReleased", 1},
             {:finish_download, 1}
           ] = state |> Agent.get(& &1.calls) |> Enum.reverse()
  end

  test "observation retries once then fails when the document changes during capture" do
    {:ok, state} = Agent.start_link(fn -> %{epochs: [0, 1, 2, 3], captures: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    assert {:error, :stale_observation} =
             Adapter.observe({ChangingEpochClient, state}, 1_000)

    assert Agent.get(state, & &1.captures) == 2
  end

  test "DOM enrichment is node-count and UTF-8 byte bounded" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    assert {:ok, %{"nodes" => nodes}} = Adapter.observe({LargeTreeClient, calls}, 1_000)
    assert length(nodes) == 256
    assert Agent.get(calls, & &1) == 256

    value = get_in(hd(nodes), ["attributes", "data-testid"])
    assert byte_size(value) <= 512
    assert String.valid?(value)
    refute Map.has_key?(hd(nodes)["attributes"], "onclick")
  end

  defp action(type, locator \\ nil, input \\ nil) do
    %Action{
      action_id: "a",
      session_id: "s",
      type: type,
      locator: locator,
      input: input,
      timeout_ms: 1_000
    }
  end

  defp events(agent), do: Agent.get(agent, &Enum.reverse/1)
end
