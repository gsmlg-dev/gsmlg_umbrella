defmodule GSMLG.GaoNote.MCP.Tools do
  @moduledoc false

  alias Backplane.McpProtocol.Server.Response
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.MCP.Authorization
  alias GSMLG.GaoNote.Presenter

  @readonly_tools ~w(
    gao_note.search
    gao_note.get
    gao_note.list_label_settings
    gao_note.list_references
    gao_note.list_assets
  )

  @admin_tools @readonly_tools ++
                 ~w(
                   gao_note.create
                   gao_note.create_label_setting
                   gao_note.update
                   gao_note.delete
                   gao_note.set_labels
                   gao_note.references.add
                   gao_note.references.update
                   gao_note.references.remove
                   gao_note.assets.attach_existing
                   gao_note.assets.upload_base64
                   gao_note.assets.update
                   gao_note.assets.detach
                 )

  @max_base64_bytes 5 * 1024 * 1024

  @input_fields %{
    "gao_note.search" => [
      {:query, :string,
       [description: "Search text matched against note title, description, and markdown content."]},
      {:label, :string, [description: "Optional label key or key=value filter."]},
      {:limit, :integer, [description: "Maximum notes to return."]},
      {:offset, :integer, [description: "Number of notes to skip."]}
    ],
    "gao_note.get" => [
      {:id, :string, [required: true, description: "GaoNote id."]}
    ],
    "gao_note.list_label_settings" => [],
    "gao_note.list_references" => [
      {:id, :string, [required: true, description: "GaoNote id."]}
    ],
    "gao_note.list_assets" => [
      {:id, :string, [required: true, description: "GaoNote id."]}
    ],
    "gao_note.create" => [
      {:title, :string, [required: true, description: "Note title."]},
      {:description, :string, [description: "Optional short note description."]},
      {:content, :string, [required: true, description: "Markdown note content."]},
      {:labels, {:list, :string},
       [description: "Optional labels as key=value strings. Missing label keys are created."]},
    ],
    "gao_note.create_label_setting" => [
      {:name, :string, [required: true, description: "Label key."]},
      {:color, :string, [description: "Optional label color, for example #1f6feb."]},
      {:description, :string, [description: "Optional label key description."]},
      {:value_type, :string,
       [
         description:
           "Label value type: text, number, version, date, date-time, time, year, year-month, or year-season."
       ]}
    ],
    "gao_note.update" => [
      {:id, :string, [required: true, description: "GaoNote id."]},
      {:title, :string, [description: "Updated note title."]},
      {:description, :string, [description: "Updated short note description."]},
      {:content, :string, [description: "Updated markdown note content."]},
      {:labels, {:list, :string},
       [description: "Replacement labels as key=value strings. Missing label keys are created."]},
    ],
    "gao_note.delete" => [
      {:id, :string, [required: true, description: "GaoNote id."]}
    ],
    "gao_note.set_labels" => [
      {:id, :string, [required: true, description: "GaoNote id."]},
      {:labels, {:list, :string},
       [required: true, description: "Replacement labels as key=value strings."]}
    ],
    "gao_note.references.add" => [
      {:id, :string, [required: true, description: "GaoNote id."]},
      {:url, :string, [required: true, description: "HTTP or HTTPS reference URL."]},
      {:title, :string, [description: "Optional reference title."]},
      {:description, :string, [description: "Optional reference description."]},
      {:canonical_url, :string, [description: "Optional canonical URL override."]},
      {:site_name, :string, [description: "Optional source site name."]},
      {:favicon_url, :string, [description: "Optional favicon URL."]},
      {:position, :integer, [description: "Optional sort position."]}
    ],
    "gao_note.references.update" => [
      {:reference_id, :string, [required: true, description: "GaoNote reference id."]},
      {:url, :string, [description: "Updated HTTP or HTTPS reference URL."]},
      {:title, :string, [description: "Updated reference title."]},
      {:description, :string, [description: "Updated reference description."]},
      {:canonical_url, :string, [description: "Updated canonical URL override."]},
      {:site_name, :string, [description: "Updated source site name."]},
      {:favicon_url, :string, [description: "Updated favicon URL."]},
      {:position, :integer, [description: "Updated sort position."]}
    ],
    "gao_note.references.remove" => [
      {:reference_id, :string, [required: true, description: "GaoNote reference id."]}
    ],
    "gao_note.assets.attach_existing" => [
      {:id, :string, [required: true, description: "GaoNote id."]},
      {:storage_file_id, :string, [required: true, description: "Existing storage file id."]},
      {:role, :string, [description: "Asset role: attachment, cover, inline, or source."]},
      {:path, :string,
       [
         description:
           "Note-relative attachment path. Use the same path in markdown, for example ./data.txt."
       ]},
      {:description, :string, [description: "Optional attachment description."]},
      {:caption, :string, [description: "Optional asset caption."]},
      {:alt_text, :string, [description: "Optional asset alt text."]},
      {:position, :integer, [description: "Optional sort position."]}
    ],
    "gao_note.assets.upload_base64" => [
      {:id, :string, [required: true, description: "GaoNote id."]},
      {:base64, :string,
       [required: true, description: "Standard Base64 file content, up to 5 MB."]},
      {:filename, :string, [description: "Optional uploaded filename."]},
      {:role, :string, [description: "Asset role: attachment, cover, inline, or source."]},
      {:path, :string,
       [
         description:
           "Note-relative attachment path. Use the same path in markdown, for example ./data.txt."
       ]},
      {:description, :string, [description: "Optional attachment description."]},
      {:caption, :string, [description: "Optional asset caption."]},
      {:alt_text, :string, [description: "Optional asset alt text."]},
      {:position, :integer, [description: "Optional sort position."]}
    ],
    "gao_note.assets.update" => [
      {:asset_id, :string, [required: true, description: "GaoNote asset id."]},
      {:role, :string,
       [description: "Updated asset role: attachment, cover, inline, or source."]},
      {:path, :string,
       [
         description:
           "Updated note-relative attachment path. Use the same path in markdown, for example ./data.txt."
       ]},
      {:description, :string, [description: "Updated attachment description."]},
      {:caption, :string, [description: "Updated asset caption."]},
      {:alt_text, :string, [description: "Updated asset alt text."]},
      {:position, :integer, [description: "Updated sort position."]}
    ],
    "gao_note.assets.detach" => [
      {:asset_id, :string, [required: true, description: "GaoNote asset id."]}
    ]
  }

  def readonly_tools, do: @readonly_tools
  def admin_tools, do: @admin_tools

  def input_fields(name), do: Map.fetch!(@input_fields, name)

  def execute(name, params, frame) do
    response =
      try do
        name
        |> dispatch(stringify_keys(params || %{}), frame, mode(frame))
        |> ensure_response()
      rescue
        exception ->
          log_tool_failure(name, :error, exception, __STACKTRACE__)
          error("#{name} failed unexpectedly. Check GaoNote MCP server logs.")
      catch
        kind, reason ->
          log_tool_failure(name, kind, reason, __STACKTRACE__)
          error("#{name} failed unexpectedly. Check GaoNote MCP server logs.")
      end

    {:reply, response, frame}
  end

  def description("gao_note.search"), do: "Search GaoNote notes."
  def description("gao_note.get"), do: "Get a GaoNote by id."
  def description("gao_note.list_label_settings"), do: "List GaoNote label settings."
  def description("gao_note.list_references"), do: "List web references for a GaoNote."
  def description("gao_note.list_assets"), do: "List active storage-backed assets for a GaoNote."

  def description("gao_note.create"), do: "Create a GaoNote."

  def description("gao_note.create_label_setting"),
    do:
      "Create a GaoNote label setting by key. Label keys are also created automatically when notes use new labels."

  def description("gao_note.update"),
    do: "Update a GaoNote. labels, when provided, must be an array of key=value strings."

  def description("gao_note.delete"), do: "Delete a GaoNote."

  def description("gao_note.set_labels"),
    do: "Replace GaoNote labels with an array of key=value strings."

  def description("gao_note.references.add"), do: "Add a web reference to a GaoNote."
  def description("gao_note.references.update"), do: "Update a GaoNote web reference."
  def description("gao_note.references.remove"), do: "Remove a GaoNote web reference."
  def description("gao_note.assets.attach_existing"), do: "Attach an existing storage file."
  def description("gao_note.assets.upload_base64"), do: "Upload a small base64 asset."
  def description("gao_note.assets.update"), do: "Update GaoNote asset metadata."
  def description("gao_note.assets.detach"), do: "Detach a GaoNote asset."

  def annotations(name) do
    cond do
      name in @readonly_tools ->
        %{
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true,
          "openWorldHint" => false
        }

      name in ~w(gao_note.delete gao_note.references.remove gao_note.assets.detach) ->
        %{
          "readOnlyHint" => false,
          "destructiveHint" => true,
          "idempotentHint" => false,
          "openWorldHint" => false
        }

      true ->
        %{
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false,
          "openWorldHint" => false
        }
    end
  end

  defp dispatch("gao_note.search", args, _frame, mode) do
    query = Map.get(args, "query", Map.get(args, "search", ""))
    opts = list_opts(args, mode)
    notes = GaoNote.search_notes(query, opts)

    ok("Found #{length(notes)} GaoNote notes", %{
      "notes" => Enum.map(notes, &Presenter.note_summary/1)
    })
  end

  defp dispatch("gao_note.get", args, _frame, mode) do
    case fetch_note(args, mode) do
      nil -> error("GaoNote not found")
      note -> ok("GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
    end
  end

  defp dispatch("gao_note.list_label_settings", _args, _frame, _mode) do
    label_settings = GaoNote.list_label_settings()

    ok("Found #{length(label_settings)} GaoNote label settings", %{
      "label_settings" => Enum.map(label_settings, &Presenter.label_setting/1)
    })
  end

  defp dispatch("gao_note.list_references", args, _frame, mode) do
    with %{} = note <- fetch_note(args, mode) do
      references = GaoNote.list_references(note)

      ok("Found #{length(references)} GaoNote references", %{
        "references" => Enum.map(references, &Presenter.reference/1)
      })
    else
      _ -> error("GaoNote not found")
    end
  end

  defp dispatch("gao_note.list_assets", args, _frame, mode) do
    with %{} = note <- fetch_note(args, mode) do
      assets = GaoNote.list_assets(note)

      ok("Found #{length(assets)} GaoNote assets", %{
        "assets" => Enum.map(assets, &Presenter.asset_json(&1, note))
      })
    else
      _ -> error("GaoNote not found")
    end
  end

  defp dispatch("gao_note.create", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         {:ok, note} <- GaoNote.create_note(args, mcp_actor(actor)) do
      audit("gao_note.create", actor, note.id)
      ok("Created GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.create_label_setting", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         {:ok, label_setting} <- GaoNote.create_label_setting(label_setting_attrs(args), mcp_actor(actor)) do
      audit("gao_note.create_label_setting", actor, nil)
      ok("Created GaoNote label setting: #{label_setting.name}", %{
        "label_setting" => Presenter.label_setting(label_setting)
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.update", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         attrs <- Map.drop(args, ["id"]),
         {:ok, note} <- GaoNote.update_note(note, attrs, mcp_actor(actor)) do
      audit("gao_note.update", actor, note.id)
      ok("Updated GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.delete", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         {:ok, deleted} <- GaoNote.delete_note(note, mcp_actor(actor)) do
      audit("gao_note.delete", actor, deleted.id)
      ok("Deleted GaoNote: #{deleted.title}", %{"note" => Presenter.note(deleted)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.set_labels", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         attrs <- %{"labels" => Map.get(args, "labels", [])},
         {:ok, note} <- GaoNote.update_note(note, attrs, mcp_actor(actor)) do
      audit("gao_note.set_labels", actor, note.id)
      ok("Updated GaoNote labels: #{note.title}", %{"note" => Presenter.note(note)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.references.add", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         attrs <- Map.drop(args, ["id"]),
         {:ok, reference} <- GaoNote.add_reference(note, attrs, mcp_actor(actor)) do
      audit("gao_note.references.add", actor, note.id)
      ok("Added GaoNote reference", %{"reference" => Presenter.reference(reference)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.references.update", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = reference <- GaoNote.get_reference(Map.get(args, "reference_id")),
         attrs <- Map.drop(args, ["reference_id"]),
         {:ok, reference} <- GaoNote.update_reference(reference, attrs, mcp_actor(actor)) do
      audit("gao_note.references.update", actor, reference.note_id)
      ok("Updated GaoNote reference", %{"reference" => Presenter.reference(reference)})
    else
      nil -> error("GaoNote reference not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.references.remove", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = reference <- GaoNote.get_reference(Map.get(args, "reference_id")),
         {:ok, reference} <- GaoNote.remove_reference(reference, mcp_actor(actor)) do
      audit("gao_note.references.remove", actor, reference.note_id)
      ok("Removed GaoNote reference", %{"reference" => Presenter.reference(reference)})
    else
      nil -> error("GaoNote reference not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.assets.attach_existing", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         storage_file_id when is_binary(storage_file_id) <- Map.get(args, "storage_file_id"),
         attrs <- Map.drop(args, ["id", "storage_file_id"]),
         {:ok, asset} <- GaoNote.attach_asset(note, storage_file_id, attrs, mcp_actor(actor)) do
      audit("gao_note.assets.attach_existing", actor, note.id)
      ok("Attached GaoNote asset", %{"asset" => Presenter.asset_json(asset, note)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
      _ -> error("storage_file_id is required")
    end
  end

  defp dispatch("gao_note.assets.upload_base64", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         {:ok, binary} <- decode_base64(Map.get(args, "base64")),
         filename <- Map.get(args, "filename", "gao-note-asset.bin"),
         attrs <- Map.drop(args, ["id", "base64", "filename"]),
         {:ok, asset} <- GaoNote.upload_asset(note, {filename, binary}, attrs, mcp_actor(actor)) do
      audit("gao_note.assets.upload_base64", actor, note.id)
      ok("Uploaded GaoNote asset", %{"asset" => Presenter.asset_json(asset, note)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.assets.update", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = asset <- GaoNote.get_asset(Map.get(args, "asset_id")),
         %{} = note <- GaoNote.get_note(asset.note_id),
         attrs <- Map.drop(args, ["asset_id"]),
         {:ok, asset} <- GaoNote.update_asset(asset, attrs, mcp_actor(actor)) do
      audit("gao_note.assets.update", actor, asset.note_id)
      ok("Updated GaoNote asset", %{"asset" => Presenter.asset_json(asset, note)})
    else
      nil -> error("GaoNote asset not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.assets.detach", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = asset <- GaoNote.get_asset(Map.get(args, "asset_id")),
         %{} = note <- GaoNote.get_note(asset.note_id),
         {:ok, asset} <- GaoNote.detach_asset(asset, mcp_actor(actor)) do
      audit("gao_note.assets.detach", actor, asset.note_id)
      ok("Detached GaoNote asset", %{"asset" => Presenter.asset_json(asset, note)})
    else
      nil -> error("GaoNote asset not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(name, _args, _frame, mode), do: error("Tool unavailable in #{mode} mode: #{name}")

  defp fetch_note(args, :readonly) do
    cond do
      id = Map.get(args, "id") -> GaoNote.get_public_note(id)
      true -> nil
    end
  end

  defp fetch_note(args, :admin) do
    cond do
      id = Map.get(args, "id") -> GaoNote.get_note(id)
      true -> nil
    end
  end

  defp list_opts(args, :readonly) do
    [
      label_setting: Map.get(args, "label_setting"),
      limit: Map.get(args, "limit"),
      offset: Map.get(args, "offset")
    ]
  end

  defp list_opts(args, :admin) do
    [
      label_setting: Map.get(args, "label_setting"),
      limit: Map.get(args, "limit"),
      offset: Map.get(args, "offset")
    ]
  end

  defp decode_base64(value) when is_binary(value) do
    with {:ok, binary} <- Base.decode64(value),
         true <- byte_size(binary) <= @max_base64_bytes do
      {:ok, binary}
    else
      :error -> {:error, "base64 must be valid standard Base64"}
      false -> {:error, "base64 payload exceeds 5 MB limit"}
    end
  end

  defp decode_base64(_value), do: {:error, "base64 is required"}

  defp label_setting_attrs(args) do
    %{
      "name" => Map.get(args, "name", Map.get(args, "label_setting")),
      "color" => Map.get(args, "color"),
      "description" => Map.get(args, "description"),
      "value_type" => Map.get(args, "value_type")
    }
  end

  defp ok(text, structured_content) do
    Response.tool()
    |> Response.text(text)
    |> Response.structured(structured_content)
  end

  defp error(reason) do
    text =
      case reason do
        binary when is_binary(binary) -> binary
        other -> Presenter.error_text(other)
      end

    Response.tool()
    |> Response.error(text)
  end

  defp ensure_response(%Response{} = response), do: response
  defp ensure_response(other), do: error(other)

  defp mode(%{assigns: %{mode: :admin}}), do: :admin
  defp mode(%{assigns: %{"mode" => "admin"}}), do: :admin
  defp mode(_frame), do: :readonly

  defp mcp_actor(%{id: id}) when not is_nil(id), do: %{id: id, source: "mcp"}
  defp mcp_actor(%{"id" => id}) when not is_nil(id), do: %{id: id, source: "mcp"}
  defp mcp_actor(actor), do: actor

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp audit(tool_name, actor, note_id) do
    GSMLG.Telemetry.info("GaoNote MCP tool call",
      metadata: %{
        tool: tool_name,
        actor_id: Map.get(actor, :id),
        note_id: note_id
      }
    )
  end

  defp log_tool_failure(tool_name, kind, reason, stacktrace) do
    GSMLG.Telemetry.error("GaoNote MCP tool failed",
      metadata: %{
        tool: tool_name,
        kind: kind,
        error: failure_message(reason),
        stacktrace: Exception.format(kind, reason, stacktrace)
      }
    )
  end

  defp failure_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp failure_message(reason), do: inspect(reason)
end

defmodule GSMLG.GaoNote.MCP.ToolComponent do
  @moduledoc false

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = GSMLG.GaoNote.MCP.Tools.description(name)
    schema_block = schema_block(name)

    quote do
      @moduledoc unquote(description)

      use Backplane.McpProtocol.Server.Component, type: :tool

      unquote(schema_block)

      @impl true
      def annotations, do: GSMLG.GaoNote.MCP.Tools.annotations(unquote(name))

      @impl true
      def execute(params, frame),
        do: GSMLG.GaoNote.MCP.Tools.execute(unquote(name), params, frame)
    end
  end

  defp schema_block(name) do
    case GSMLG.GaoNote.MCP.Tools.input_fields(name) do
      [] ->
        quote do
          schema do
            %{}
          end
        end

      fields ->
        field_asts =
          Enum.map(fields, fn {field_name, type, opts} ->
            quote do
              field(unquote(field_name), unquote(Macro.escape(type)), unquote(Macro.escape(opts)))
            end
          end)

        quote do
          schema do
            (unquote_splicing(field_asts))
          end
        end
    end
  end
end

defmodule GSMLG.GaoNote.MCP.Tools.Search do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.search"
end

defmodule GSMLG.GaoNote.MCP.Tools.Get do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.get"
end

defmodule GSMLG.GaoNote.MCP.Tools.ListLabelSettings do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.list_label_settings"
end

defmodule GSMLG.GaoNote.MCP.Tools.ListReferences do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.list_references"
end

defmodule GSMLG.GaoNote.MCP.Tools.ListAssets do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.list_assets"
end

defmodule GSMLG.GaoNote.MCP.Tools.Create do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.create"
end

defmodule GSMLG.GaoNote.MCP.Tools.CreateLabelSetting do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.create_label_setting"
end

defmodule GSMLG.GaoNote.MCP.Tools.Update do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.update"
end

defmodule GSMLG.GaoNote.MCP.Tools.Delete do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.delete"
end

defmodule GSMLG.GaoNote.MCP.Tools.SetLabels do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.set_labels"
end

defmodule GSMLG.GaoNote.MCP.Tools.AddReference do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.references.add"
end

defmodule GSMLG.GaoNote.MCP.Tools.UpdateReference do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.references.update"
end

defmodule GSMLG.GaoNote.MCP.Tools.RemoveReference do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.references.remove"
end

defmodule GSMLG.GaoNote.MCP.Tools.AttachExistingAsset do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.assets.attach_existing"
end

defmodule GSMLG.GaoNote.MCP.Tools.UploadBase64Asset do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.assets.upload_base64"
end

defmodule GSMLG.GaoNote.MCP.Tools.UpdateAsset do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.assets.update"
end

defmodule GSMLG.GaoNote.MCP.Tools.DetachAsset do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.assets.detach"
end
