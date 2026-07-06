defmodule GSMLG.AdminWeb.GaoNoteLive.MCPLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias Backplane.McpProtocol.Server.Response
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.MCP.Tools
  alias Phoenix.LiveView.AsyncResult

  @server_name "gsmlg-gao-note-admin"
  @server_version "0.1.0"
  @endpoint_path "/mcp/gao_note"

  @impl true
  def mount(_params, _session, socket) do
    selected_tool = List.first(Tools.admin_tools())

    {:ok,
     socket
     |> assign(:active_menu, "gao_note_mcp")
     |> assign(:mcp_info, AsyncResult.loading())
     |> assign(:mcp_setting, AsyncResult.loading())
     |> assign(:selected_tool, selected_tool)
     |> assign(:arguments_json, default_arguments_json(selected_tool))
     |> assign(:tool_result, nil)
     |> assign(:generated_api_key, nil)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "GaoNote MCP")
     |> assign(:active_menu, "gao_note_mcp")
     |> assign_mcp_info_async()
     |> assign_mcp_setting_async()}
  end

  @impl true
  def handle_event("save_api_key", %{"mcp_api_key" => %{"api_key" => api_key}}, socket) do
    case GaoNote.set_mcp_api_key(api_key, current_actor(socket)) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> assign(:generated_api_key, nil)
         |> put_flash(:info, "MCP API key saved")
         |> assign_mcp_setting_async()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "MCP API key save failed: #{format_error(reason)}")}
    end
  end

  def handle_event("generate_api_key", _params, socket) do
    api_key = GaoNote.generate_mcp_api_key()

    case GaoNote.set_mcp_api_key(api_key, current_actor(socket)) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> assign(:generated_api_key, api_key)
         |> put_flash(:info, "MCP API key generated")
         |> assign_mcp_setting_async()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "MCP API key generate failed: #{format_error(reason)}")}
    end
  end

  def handle_event("select_tool", %{"mcp_test" => params}, socket) do
    tool = Map.get(params, "tool", socket.assigns.selected_tool)
    arguments = Map.get(params, "arguments", socket.assigns.arguments_json)

    arguments =
      if tool == socket.assigns.selected_tool do
        arguments
      else
        default_arguments_json(tool)
      end

    {:noreply,
     socket
     |> assign(:selected_tool, tool)
     |> assign(:arguments_json, arguments)}
  end

  def handle_event("run_tool", %{"mcp_test" => params}, socket) do
    tool = Map.get(params, "tool", socket.assigns.selected_tool)
    arguments_json = Map.get(params, "arguments", "{}")

    result =
      with {:ok, arguments} <- decode_arguments(arguments_json),
           {:ok, response} <- execute_tool(tool, arguments, current_actor(socket)) do
        {:ok, Jason.encode!(response, pretty: true)}
      end

    {:noreply,
     socket
     |> assign(:selected_tool, tool)
     |> assign(:arguments_json, arguments_json)
     |> assign(:tool_result, result)}
  end

  defp assign_mcp_info_async(socket) do
    assign_async(
      socket,
      :mcp_info,
      fn -> {:ok, %{mcp_info: mcp_info()}} end,
      reset: true
    )
  end

  defp assign_mcp_setting_async(socket) do
    assign_async(
      socket,
      :mcp_setting,
      fn -> {:ok, %{mcp_setting: GaoNote.get_mcp_setting()}} end,
      reset: true
    )
  end

  defp mcp_info do
    %{
      server_name: @server_name,
      version: @server_version,
      endpoint: @endpoint_path,
      tools: Enum.map(Tools.admin_tools(), &tool_info/1),
      resources: resources()
    }
  end

  defp tool_info(name) do
    annotations = Tools.annotations(name)

    %{
      name: name,
      description: Tools.description(name),
      read_only?: annotations["readOnlyHint"],
      destructive?: annotations["destructiveHint"]
    }
  end

  defp resources do
    [
      %{
        name: "gao_note.note",
        uri: "gaonote://notes/{id}",
        mime_type: "text/markdown"
      },
      %{
        name: "gao_note.note.metadata",
        uri: "gaonote://notes/{id}/metadata",
        mime_type: "application/json"
      },
      %{
        name: "gao_note.note.references",
        uri: "gaonote://notes/{id}/references",
        mime_type: "application/json"
      },
      %{
        name: "gao_note.note.assets",
        uri: "gaonote://notes/{id}/assets",
        mime_type: "application/json"
      },
      %{name: "gao_note.tag", uri: "gaonote://tags/{id}", mime_type: "application/json"},
      %{name: "gao_note.asset", uri: "gaonote://assets/{asset_id}", mime_type: "application/json"}
    ]
  end

  defp decode_arguments(arguments_json) do
    case Jason.decode(arguments_json) do
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      {:ok, _other} -> {:error, "Arguments must be a JSON object"}
      {:error, error} -> {:error, "Invalid JSON: #{Exception.message(error)}"}
    end
  end

  defp execute_tool(tool, arguments, actor) do
    frame = %{assigns: %{mode: :admin, actor: mcp_actor(actor)}}

    case Tools.execute(tool, arguments, frame) do
      {:reply, %Response{} = response, _frame} -> {:ok, Response.to_protocol(response)}
      other -> {:error, inspect(other)}
    end
  end

  defp mcp_actor(%{id: id}), do: %{id: id, source: "mcp_console"}
  defp mcp_actor(_actor), do: %{id: nil, source: "mcp_console"}

  defp default_arguments_json("gao_note.search"), do: ~s({"query": "", "limit": 10})
  defp default_arguments_json("gao_note.list_tags"), do: "{}"

  defp default_arguments_json("gao_note.create"),
    do: ~s({"title": "", "content": "", "creator": "agent-name"})

  defp default_arguments_json("gao_note.create_tag"), do: ~s({"name": "", "color": ""})
  defp default_arguments_json("gao_note.set_tags"), do: ~s({"id": "", "tags": []})
  defp default_arguments_json("gao_note.references.add"), do: ~s({"id": "", "url": ""})

  defp default_arguments_json("gao_note.references.update"),
    do: ~s({"reference_id": "", "url": ""})

  defp default_arguments_json("gao_note.references.remove"), do: ~s({"reference_id": ""})

  defp default_arguments_json("gao_note.assets.attach_existing"),
    do: ~s({"id": "", "storage_file_id": ""})

  defp default_arguments_json("gao_note.assets.upload_base64"),
    do: ~s({"id": "", "filename": "", "base64": ""})

  defp default_arguments_json("gao_note.assets.update"), do: ~s({"asset_id": ""})
  defp default_arguments_json("gao_note.assets.detach"), do: ~s({"asset_id": ""})
  defp default_arguments_json(_tool), do: ~s({"id": ""})

  defp format_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end

  defp format_error(reason), do: inspect(reason)

  defp async_value(%AsyncResult{ok?: true, result: result}, _fallback), do: result
  defp async_value(_result, fallback), do: fallback

  defp async_loading?(%AsyncResult{loading: loading}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false

  defp tool_options(info), do: Enum.map(info.tools, &{&1.name, &1.name})

  defp current_actor(socket), do: socket.assigns[:current_user]

  defp empty_mcp_info do
    %{
      server_name: @server_name,
      version: @server_version,
      endpoint: @endpoint_path,
      tools: [],
      resources: []
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <% info = async_value(@mcp_info, empty_mcp_info()) %>
      <% setting = async_value(@mcp_setting, nil) %>

      <div class="flex flex-col gap-5 p-6 w-full">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="server-network-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">GaoNote MCP</h1>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/gao_notes/notes"}>
              <.dm_btn size="sm" variant="ghost">
                <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
              </.dm_btn>
            </.link>
            <.link navigate={~p"/gao_notes/logs"}>
              <.dm_btn size="sm" variant="ghost">
                <.dm_mdi name="clipboard-text-clock-outline" class="w-4 h-4" /> Log
              </.dm_btn>
            </.link>
          </div>
        </div>

        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(320px,420px)]">
          <section class="grid gap-3 rounded-lg border border-base-300 p-4">
            <div class="grid gap-3 md:grid-cols-3">
              <div>
                <div class="font-mono text-xs text-base-content/50">Server</div>
                <div id="gao-note-mcp-server-name" class="font-mono text-sm">{info.server_name}</div>
              </div>
              <div>
                <div class="font-mono text-xs text-base-content/50">Version</div>
                <div class="font-mono text-sm">{info.version}</div>
              </div>
              <div>
                <div class="font-mono text-xs text-base-content/50">Endpoint</div>
                <div id="gao-note-mcp-endpoint" class="font-mono text-sm">{info.endpoint}</div>
              </div>
            </div>

            <div class="grid gap-2">
              <div class="font-mono text-xs text-base-content/50">Headers</div>
              <pre class="overflow-auto rounded bg-base-200 p-3 text-xs">x-gaonote-mcp-key: {if setting, do: setting.api_key_hint, else: "not set"}</pre>
            </div>
          </section>

          <section class="grid gap-3 rounded-lg border border-base-300 p-4">
            <div class="flex items-center justify-between gap-2">
              <h2 class="font-semibold text-sm">API Key</h2>
              <.dm_badge :if={setting} size="sm" variant="ghost">{setting.api_key_hint}</.dm_badge>
              <.dm_badge :if={!setting} size="sm" class="badge-error">not set</.dm_badge>
            </div>

            <form id="gao-note-mcp-api-key-form" phx-submit="save_api_key" class="grid gap-3">
              <.dm_input
                id="gao-note-mcp-api-key-input"
                name="mcp_api_key[api_key]"
                type="password"
                value=""
                label="API Key"
                autocomplete="off"
              />
              <div class="flex flex-wrap gap-2">
                <button type="submit" class="btn btn-primary btn-sm">
                  <.dm_mdi name="content-save-outline" class="w-4 h-4" /> Save
                </button>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="generate_api_key">
                  <.dm_mdi name="key-plus" class="w-4 h-4" /> Generate
                </button>
              </div>
            </form>

            <div
              :if={@generated_api_key}
              id="gao-note-mcp-generated-key"
              class="rounded border border-warning/40 bg-warning/10 p-3"
            >
              <div class="font-mono text-xs text-base-content/50">Generated</div>
              <div class="font-mono text-xs break-all">{@generated_api_key}</div>
            </div>
          </section>
        </div>

        <.dm_skeleton_table
          :if={async_loading?(@mcp_info)}
          id="gao-note-mcp-loading"
          rows={6}
          columns={3}
          animation="wave"
          loading_label="Loading GaoNote MCP"
        />
        <div :if={async_failed?(@mcp_info)} class="text-sm text-error">
          Unable to load GaoNote MCP.
        </div>

        <div :if={!async_loading?(@mcp_info)} class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_420px]">
          <section class="grid gap-3">
            <div class="flex items-center gap-2">
              <.dm_mdi name="function-variant" class="w-4 h-4 text-primary" />
              <h2 class="font-semibold text-sm">Functions</h2>
            </div>

            <.dm_table id="gao-note-mcp-tools-table" class="table-bordered" data={info.tools}>
              <:col :let={tool} label="Name">
                <span class="font-mono text-xs">{tool.name}</span>
              </:col>
              <:col :let={tool} label="Description">
                <span class="text-sm">{tool.description}</span>
              </:col>
              <:col :let={tool} label="Type">
                <div class="flex flex-wrap gap-1">
                  <.dm_badge :if={tool.read_only?} size="sm" variant="ghost">read</.dm_badge>
                  <.dm_badge :if={!tool.read_only?} size="sm" variant="ghost">write</.dm_badge>
                  <.dm_badge :if={tool.destructive?} size="sm" class="badge-error">delete</.dm_badge>
                </div>
              </:col>
            </.dm_table>

            <div class="flex items-center gap-2 pt-2">
              <.dm_mdi name="file-tree-outline" class="w-4 h-4 text-primary" />
              <h2 class="font-semibold text-sm">Resources</h2>
            </div>

            <.dm_table id="gao-note-mcp-resources-table" class="table-bordered" data={info.resources}>
              <:col :let={resource} label="Name">
                <span class="font-mono text-xs">{resource.name}</span>
              </:col>
              <:col :let={resource} label="URI">
                <span class="font-mono text-xs">{resource.uri}</span>
              </:col>
              <:col :let={resource} label="MIME">
                <span class="font-mono text-xs">{resource.mime_type}</span>
              </:col>
            </.dm_table>
          </section>

          <section class="grid content-start gap-3 rounded-lg border border-base-300 p-4">
            <div class="flex items-center gap-2">
              <.dm_mdi name="play-circle-outline" class="w-4 h-4 text-primary" />
              <h2 class="font-semibold text-sm">Test</h2>
            </div>

            <form
              id="gao-note-mcp-test-form"
              phx-change="select_tool"
              phx-submit="run_tool"
              class="grid gap-3"
            >
              <.dm_select
                id="gao-note-mcp-tool"
                name="mcp_test[tool]"
                value={@selected_tool}
                label="Function"
                options={tool_options(info)}
              />
              <.dm_textarea
                id="gao-note-mcp-arguments"
                name="mcp_test[arguments]"
                value={@arguments_json}
                label="Arguments"
                rows={8}
                resize="vertical"
                textarea_class="font-mono text-xs"
              />
              <button type="submit" class="btn btn-primary btn-sm justify-self-start">
                <.dm_mdi name="play" class="w-4 h-4" /> Run
              </button>
            </form>

            <div :if={@tool_result} id="gao-note-mcp-test-result" class="grid gap-2">
              <div class="font-mono text-xs text-base-content/50">Result</div>
              <pre
                :if={match?({:ok, _}, @tool_result)}
                class="max-h-[28rem] overflow-auto rounded bg-base-200 p-3 text-xs"
              >{elem(@tool_result, 1)}</pre>
              <div :if={match?({:error, _}, @tool_result)} class="text-sm text-error">
                {elem(@tool_result, 1)}
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
