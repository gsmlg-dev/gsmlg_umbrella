defmodule GSMLG.GaoNote.MCP.AgentNoteTools do
  @moduledoc false
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Response
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.{NoteLines, Presenter, Search}
  alias GSMLG.GaoNote.MCP.Authorization

  @names ~w(save_note get_note list_notes semantic_search read_note_lines replace_note patch_note delete_note bulk_update_note_labels put_note_attachment get_note_attachment_content delete_note_attachment)
  @reads ~w(get_note list_notes semantic_search read_note_lines get_note_attachment_content)
  @i64_max 9_223_372_036_854_775_807

  def tool_names, do: @names

  def input_schema(name) do
    string = %{"type" => "string"}

    revision = %{
      "type" => "integer",
      "minimum" => -9_223_372_036_854_775_808,
      "maximum" => @i64_max
    }

    labels =
      array(%{
        "type" => "array",
        "prefixItems" => [string, string],
        "minItems" => 2,
        "maxItems" => 2
      })

    attachments = array(attachment_input())
    note_fields = %{"id" => string, "expected_revision" => Map.put(revision, "minimum", 1)}

    writable = %{
      "title" => string,
      "content" => string,
      "labels" => labels,
      "attachments" => attachments
    }

    case name do
      "save_note" ->
        object(
          %{"title" => string, "content" => string, "labels" => default(labels, [])},
          ~w(title content)
        )

      "get_note" ->
        object(%{"id" => string}, ["id"], false)

      "read_note_lines" ->
        object(%{"id" => string}, ["id"], false)

      "list_notes" ->
        uint = %{"type" => "integer", "minimum" => 0, "maximum" => 4_294_967_295}

        object(
          %{
            "limit" => default(nullable(uint), nil),
            "offset" => default(nullable(uint), nil),
            "label" => default(nullable(string), nil)
          },
          [],
          false
        )

      "semantic_search" ->
        object(
          %{
            "query" => string,
            "limit" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => 18_446_744_073_709_551_615
            },
            "label" => default(nullable(string), nil)
          },
          ~w(query limit),
          false
        )

      "replace_note" ->
        object(
          Map.merge(note_fields, writable),
          ~w(id expected_revision title content attachments labels)
        )

      "patch_note" ->
        content = %{"anyOf" => [string, object(%{"apply_patch" => string}, ["apply_patch"])]}

        object(
          Map.merge(note_fields, Map.put(writable, "content", content)),
          ~w(id expected_revision)
        )

      "delete_note" ->
        object(
          %{"id" => string, "expected_revision" => revision},
          ~w(id expected_revision),
          false
        )

      "bulk_update_note_labels" ->
        object(
          %{
            "selector" => string,
            "set" => default(labels, []),
            "remove" => default(array(string), [])
          },
          ["selector"]
        )

      "put_note_attachment" ->
        fields = %{
          "note_id" => string,
          "attachment_id" => string,
          "expected_revision" => revision,
          "path" => string,
          "mime" => string,
          "description" => default(string, ""),
          "content" => default(nullable(string), nil),
          "content_base64" => default(nullable(string), nil)
        }

        object(fields, ~w(note_id attachment_id expected_revision path mime))
        |> Map.put("anyOf", [%{"required" => ["content"]}, %{"required" => ["content_base64"]}])

      "get_note_attachment_content" ->
        object(%{"note_id" => string, "attachment_id" => string}, ~w(note_id attachment_id))

      "delete_note_attachment" ->
        object(
          %{"note_id" => string, "attachment_id" => string, "expected_revision" => revision},
          ~w(note_id attachment_id expected_revision)
        )
    end
  end

  def output_schema(name) do
    string = %{"type" => "string"}
    integer = %{"type" => "integer"}
    boolean = %{"type" => "boolean"}

    labels =
      array(
        object(
          Map.new(~w(key value description value_type), &{&1, string}),
          ~w(key value description value_type)
        )
      )

    summary =
      object(
        %{
          "id" => string,
          "title" => string,
          "labels" => labels,
          "revision" => integer,
          "created_at" => integer,
          "updated_at" => integer
        },
        ~w(id title labels revision created_at updated_at)
      )

    metadata = attachment_metadata()

    case name do
      "save_note" ->
        object(%{"id" => string, "revision" => integer}, ~w(id revision))

      "get_note" ->
        object(
          Map.merge(summary["properties"], %{
            "content" => string,
            "attachments" => array(metadata)
          }),
          summary["required"] ++ ~w(content attachments)
        )

      "list_notes" ->
        object(%{"notes" => array(summary)}, ["notes"])

      "semantic_search" ->
        hit =
          object(
            Map.put(summary["properties"], "score", %{"type" => "number"}),
            summary["required"] ++ ["score"]
          )

        object(%{"results" => array(hit)}, ["results"])

      "read_note_lines" ->
        object(
          %{
            "id" => string,
            "revision" => integer,
            "tag" => string,
            "lines" => array(object(%{"n" => integer, "text" => string}, ~w(n text)))
          },
          ~w(id revision tag lines)
        )

      name when name in ~w(replace_note patch_note) ->
        object(
          %{"id" => string, "revision" => integer, "changed" => boolean},
          ~w(id revision changed)
        )

      "delete_note" ->
        object(%{"deleted" => boolean}, ["deleted"])

      "bulk_update_note_labels" ->
        object(
          Map.new(~w(matched updated unchanged), &{&1, integer}),
          ~w(matched updated unchanged)
        )

      "put_note_attachment" ->
        object(
          %{"created" => boolean, "revision" => integer, "attachment" => metadata},
          ~w(created revision attachment)
        )

      "get_note_attachment_content" ->
        object(%{"attachment" => metadata, "content" => string, "content_base64" => string}, [
          "attachment"
        ])
        |> Map.put("oneOf", content_xor())

      "delete_note_attachment" ->
        object(%{"deleted" => boolean, "revision" => nullable(integer)}, ~w(deleted revision))
    end
  end

  def validate(name, params) when is_map(params) do
    params = stringify(params)
    schema = runtime_schema(name)

    with :ok <- validate_schema(params, schema),
         {:ok, params} <- defaults(params, schema),
         :ok <- validate_content(name, params) do
      {:ok, params}
    end
  end

  def validate(_name, _params), do: {:error, "arguments must be an object"}

  # Schemars advertises a positive revision, while serde accepts any i64.
  # Request semantics are checked by the mutation, which returns structured errors.
  defp runtime_schema(name) when name in ~w(patch_note replace_note) do
    schema = input_schema(name)
    put_in(schema, ["properties", "expected_revision", "minimum"], -9_223_372_036_854_775_808)
  end

  defp runtime_schema(name), do: input_schema(name)

  def validate_peri(name, params) do
    case validate(name, params) do
      {:ok, params} -> {:ok, params}
      {:error, message} -> {:error, message, []}
    end
  end

  def validate_output(name, params) do
    case validate_schema(stringify(params), output_schema(name)) do
      :ok -> {:ok, params}
      {:error, message} -> {:error, message, []}
    end
  end

  def execute(name, params, frame) do
    with {:ok, args} <- validate(name, params),
         {:ok, actor} <- actor(name, frame) do
      case dispatch(name, args, actor) do
        {:ok, data} -> {:reply, Response.structured(Response.tool(), data), frame}
        {:error, reason} -> operation_error(name, reason, args, frame)
      end
    else
      {:error, reason} -> {:error, rpc_error(:invalid_params, error_message(reason)), frame}
    end
  end

  def description("save_note"),
    do: "Save a note with a title, Markdown content, and optional labels."

  def description("get_note"),
    do: "Fetch note content, labels, timestamps, and attachment metadata by note id."

  def description("list_notes"),
    do: "List note summaries with optional limit, offset, and label selector filters."

  def description("semantic_search"),
    do: "Search note summaries semantically with an optional label selector."

  def description("read_note_lines"),
    do: "Read Markdown as numbered lines with informational revision and content tag."

  def description("replace_note"),
    do:
      "Fully replace a note using expected_revision. All writable fields are required; [] clears a collection. Each attachment requires exactly one content representation. Semantic no-ops keep the revision."

  def description("patch_note"),
    do:
      "Partially update a note using expected_revision. Omitted fields are preserved; [] clears a collection. Content accepts a replacement string or strict contextual {apply_patch} diff. Each attachment requires exactly one content representation. Semantic no-ops keep the revision."

  def description("delete_note"), do: "Delete a note by id."

  def description("bulk_update_note_labels"),
    do: "Atomically set, replace, or remove labels on active notes matching a selector."

  def description("put_note_attachment"),
    do: "Add or replace one note attachment by attachment id."

  def description("get_note_attachment_content"),
    do: "Fetch one note attachment's content by attachment id."

  def description("delete_note_attachment"), do: "Delete one note attachment by attachment id."

  def annotations(name),
    do: %{
      "readOnlyHint" => name in @reads,
      "destructiveHint" => name in ~w(delete_note delete_note_attachment replace_note patch_note),
      "idempotentHint" => name in @reads,
      "openWorldHint" => false
    }

  defp dispatch("save_note", args, actor) do
    with {:ok, note} <- Compat.save_note(args, actor),
         do: {:ok, %{id: note.id, revision: note.revision}}
  end

  defp dispatch("get_note", args, _actor) do
    case Compat.get_note(args["id"]) do
      nil -> {:error, :not_found}
      note -> {:ok, Presenter.mcp_note(note)}
    end
  end

  defp dispatch("read_note_lines", args, _actor) do
    case Compat.get_note(args["id"]) do
      nil -> {:error, :not_found}
      note -> {:ok, NoteLines.from_note(note)}
    end
  end

  defp dispatch("list_notes", args, _actor) do
    opts = %{
      "limit" => args["limit"] || 10,
      "offset" => args["offset"] || 0,
      "label" => args["label"] || ""
    }

    with {:ok, notes} <- Compat.list_notes(opts),
         do: {:ok, %{notes: Enum.map(notes, &Presenter.mcp_summary/1)}}
  end

  defp dispatch("semantic_search", args, _actor) do
    with {:ok, hits} <- Search.search_notes(args) do
      {:ok,
       %{
         results:
           Enum.map(hits, fn %{note: note, score: score} ->
             Map.put(Presenter.mcp_summary(note), :score, score)
           end)
       }}
    end
  end

  defp dispatch(name, args, actor) when name in ~w(replace_note patch_note) do
    attrs = Map.drop(args, ~w(id expected_revision))

    result =
      case name do
        "replace_note" -> Compat.replace_note(args["id"], args["expected_revision"], attrs, actor)
        "patch_note" -> Compat.patch_note(args["id"], args["expected_revision"], attrs, actor)
      end

    with {:ok, %{note: note, changed: changed}} <- result,
         do: {:ok, %{id: note.id, revision: note.revision, changed: changed}}
  end

  defp dispatch("delete_note", args, actor) do
    with {:ok, _} <- Compat.delete_note(args["id"], args["expected_revision"], actor),
         do: {:ok, %{deleted: true}}
  end

  defp dispatch("bulk_update_note_labels", args, actor),
    do: Compat.bulk_update_note_labels(args, actor)

  defp dispatch("put_note_attachment", args, actor) do
    attrs = Map.drop(args, ~w(note_id attachment_id expected_revision))
    # Standalone put permits matching dual representations; aggregate attachments use XOR.
    attrs =
      if is_binary(attrs["content"]),
        do: Map.delete(attrs, "content_base64"),
        else: Map.delete(attrs, "content")

    attrs = Enum.reject(attrs, fn {_key, value} -> is_nil(value) end) |> Map.new()

    with {:ok, output} <-
           Compat.put_note_attachment(
             args["note_id"],
             args["attachment_id"],
             args["expected_revision"],
             attrs,
             actor
           ) do
      {:ok,
       %{
         attachment: Presenter.attachment(output.attachment),
         created: output.created,
         revision: output.revision
       }}
    end
  end

  defp dispatch("get_note_attachment_content", args, _actor) do
    with {:ok, attachment, bytes} <-
           Compat.get_note_attachment_content(args["note_id"], args["attachment_id"]) do
      data = %{attachment: Presenter.attachment(attachment)}

      {:ok,
       if(String.valid?(bytes),
         do: Map.put(data, :content, bytes),
         else: Map.put(data, :content_base64, Base.encode64(bytes))
       )}
    end
  end

  defp dispatch("delete_note_attachment", args, actor) do
    with {:ok, %{revision: revision, changed: changed}} <-
           Compat.delete_note_attachment(
             args["note_id"],
             args["attachment_id"],
             args["expected_revision"],
             actor
           ) do
      {:ok, %{deleted: changed, revision: if(changed, do: revision, else: nil)}}
    end
  end

  defp operation_error(name, reason, args, frame) do
    {code, message, details} = error_details(reason, args)

    message =
      case {name, code} do
        {name, "internal_error"} when name in ~w(replace_note patch_note) ->
          "note mutation failed"

        {name, "not_found"} when name in ~w(get_note read_note_lines) ->
          "note not found: #{args["id"]}"

        {"get_note_attachment_content", "not_found"} ->
          "note attachment not found: note #{args["note_id"]}, attachment #{args["attachment_id"]}"

        _ ->
          message
      end

    data = %{code: code, message: message, details: details, retryable: false}

    if name in ~w(replace_note patch_note) do
      response = Response.tool() |> Response.structured(data) |> Map.put(:isError, true)
      {:reply, response, frame}
    else
      rpc_reason =
        case code do
          "not_found" -> :resource_not_found
          "revision_conflict" -> :invalid_request
          code when code in ~w(invalid_request validation_error patch_failed) -> :invalid_params
          _ -> :internal_error
        end

      {:error,
       rpc_error(rpc_reason, message, if(code == "revision_conflict", do: data, else: %{})),
       frame}
    end
  end

  defp error_details(:not_found, args),
    do: {"not_found", "note not found", %{note_id: args["id"] || args["note_id"]}}

  defp error_details({:revision_conflict, details}, _args),
    do: {"revision_conflict", "the note changed after it was read", details}

  defp error_details({:patch_failed, message}, _args), do: {"patch_failed", message, %{}}
  defp error_details({:invalid_input, message}, _args), do: {"invalid_request", message, %{}}
  defp error_details({:validation_error, message}, _args), do: {"validation_error", message, %{}}

  defp error_details(%Ecto.Changeset{} = changeset, _args),
    do: {"validation_error", changeset_message(changeset), %{}}

  defp error_details({:attachment_input, %{changeset: changeset}}, _args),
    do: {"validation_error", changeset_message(changeset), %{}}

  defp error_details({:attachment_path_change, id}, _args),
    do: {"validation_error", "attachment path cannot change for existing id: #{id}", %{}}

  defp error_details({:attachments, %{code: :duplicate_path, path: path}}, _args),
    do: {"validation_error", "duplicate attachment path: #{path}", %{}}

  defp error_details(_reason, _args), do: {"internal_error", "note operation failed", %{}}

  defp changeset_message(%Ecto.Changeset{errors: errors}) do
    cond do
      Keyword.has_key?(errors, :title) -> "title must not be empty"
      Keyword.has_key?(errors, :content) -> "content must not be empty"
      Keyword.has_key?(errors, :path) -> "attachment path must be relative"
      Keyword.has_key?(errors, :mime) -> "attachment mime must not be empty"
      true -> "note validation failed"
    end
  end

  defp error_message(message) when is_binary(message), do: message
  defp error_message({:invalid_input, message}), do: message
  defp error_message(_reason), do: "invalid tool arguments"

  defp rpc_error(reason, message, data \\ %{}) do
    error =
      if reason == :resource_not_found,
        do: Error.resource(:not_found, data),
        else: Error.protocol(reason, data)

    %{error | message: message}
  end

  defp actor(name, _frame) when name in @reads, do: {:ok, nil}
  defp actor(_name, frame), do: Authorization.actor(frame)

  defp validate_content(name, params) when name in ~w(patch_note replace_note) do
    Enum.reduce_while(Map.get(params, "attachments", []), :ok, fn attachment, :ok ->
      case attachment_content(attachment) do
        {:ok, _bytes} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_content("put_note_attachment", params) do
    case attachment_content(params) do
      {:ok, _bytes} -> :ok
      error -> error
    end
  end

  defp validate_content(_name, _params), do: :ok

  defp attachment_content(params) do
    content = params["content"]
    encoded = params["content_base64"]

    cond do
      is_nil(content) and is_nil(encoded) ->
        {:error, "attachment content or content_base64 is required"}

      is_nil(encoded) ->
        {:ok, content}

      true ->
        case Base.decode64(encoded) do
          {:ok, bytes} ->
            cond do
              Base.encode64(bytes) != encoded ->
                {:error, "invalid attachment content_base64"}

              is_binary(content) and content != bytes ->
                {:error, "attachment content and content_base64 do not match"}

              true ->
                {:ok, bytes}
            end

          :error ->
            {:error, "invalid attachment content_base64"}
        end
    end
  end

  defp attachment_input do
    fields =
      Map.new(~w(id path mime content content_base64), &{&1, %{"type" => "string"}})
      |> Map.put("description", default(%{"type" => "string"}, ""))

    object(fields, ~w(id path mime)) |> Map.put("oneOf", content_xor())
  end

  defp attachment_metadata,
    do:
      object(
        Map.new(~w(id path mime description), &{&1, %{"type" => "string"}}),
        ~w(id path mime description)
      )

  defp content_xor,
    do: [
      %{"required" => ["content"], "not" => %{"required" => ["content_base64"]}},
      %{"required" => ["content_base64"], "not" => %{"required" => ["content"]}}
    ]

  defp object(properties, required, closed \\ true) do
    schema = %{"type" => "object", "properties" => properties, "required" => required}
    if closed, do: Map.put(schema, "additionalProperties", false), else: schema
  end

  defp array(items), do: %{"type" => "array", "items" => items}
  defp nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}
  defp default(schema, value), do: Map.put(schema, "default", value)

  defp validate_schema(value, schema) do
    cond do
      Map.has_key?(schema, "not") and validate_schema(value, schema["not"]) == :ok ->
        {:error, "incompatible content fields"}

      Map.has_key?(schema, "oneOf") and
          Enum.count(schema["oneOf"], &(validate_schema(value, &1) == :ok)) != 1 ->
        {:error, "exactly one of content or content_base64 is required"}

      Map.has_key?(schema, "anyOf") and
          not Enum.any?(schema["anyOf"], &(validate_schema(value, &1) == :ok)) ->
        {:error, "value does not match the required type"}

      Map.has_key?(schema, "required") and
          (not is_map(value) or not Enum.all?(schema["required"], &Map.has_key?(value, &1))) ->
        {:error, "required field is missing"}

      true ->
        validate_type(value, schema)
    end
  end

  defp validate_type(value, %{"type" => "object"} = schema) when is_map(value) do
    properties = schema["properties"] || %{}

    if schema["additionalProperties"] == false and
         Enum.any?(Map.keys(value), &(not Map.has_key?(properties, &1))) do
      {:error, "unsupported field"}
    else
      value
      |> Enum.filter(fn {key, _} -> Map.has_key?(properties, key) end)
      |> validate_each(fn {key, item} -> validate_schema(item, properties[key]) end)
    end
  end

  defp validate_type(value, %{"type" => "array"} = schema) when is_list(value) do
    cond do
      Map.has_key?(schema, "minItems") and length(value) < schema["minItems"] ->
        {:error, "array has too few items"}

      Map.has_key?(schema, "maxItems") and length(value) > schema["maxItems"] ->
        {:error, "array has too many items"}

      Map.has_key?(schema, "prefixItems") ->
        value
        |> Enum.zip(schema["prefixItems"])
        |> validate_each(fn {item, item_schema} -> validate_schema(item, item_schema) end)

      true ->
        validate_each(value, &validate_schema(&1, schema["items"] || %{}))
    end
  end

  defp validate_type(value, %{"type" => "integer"} = schema) when is_integer(value) do
    if value < Map.get(schema, "minimum", value) or value > Map.get(schema, "maximum", value),
      do: {:error, "integer is out of range"},
      else: :ok
  end

  defp validate_type(value, %{"type" => "string"}) when is_binary(value), do: :ok
  defp validate_type(value, %{"type" => "number"}) when is_number(value), do: :ok
  defp validate_type(value, %{"type" => "boolean"}) when is_boolean(value), do: :ok
  defp validate_type(nil, %{"type" => "null"}), do: :ok

  defp validate_type(_value, %{"type" => _type}),
    do: {:error, "value does not match the required type"}

  defp validate_type(_value, _schema), do: :ok

  defp validate_each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp defaults(params, %{"properties" => properties}) do
    params = Map.take(params, Map.keys(properties))

    {:ok,
     Enum.reduce(properties, params, fn {key, schema}, args ->
       if Map.has_key?(schema, "default"),
         do: Map.put_new(args, key, schema["default"]),
         else: args
     end)}
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end

defmodule GSMLG.GaoNote.MCP.AgentNoteToolComponent do
  @moduledoc false
  defmacro __using__(name: name) do
    quote do
      @moduledoc GSMLG.GaoNote.MCP.AgentNoteTools.description(unquote(name))
      use Backplane.McpProtocol.Server.Component, type: :tool
      defoverridable input_schema: 0
      @impl true
      def input_schema, do: GSMLG.GaoNote.MCP.AgentNoteTools.input_schema(unquote(name))
      @impl true
      def output_schema, do: GSMLG.GaoNote.MCP.AgentNoteTools.output_schema(unquote(name))
      @doc false
      def __mcp_raw_schema__, do: {:custom, {__MODULE__, :validate_input}}
      @doc false
      def __mcp_output_schema__, do: {:custom, {__MODULE__, :validate_output}}
      @doc false
      def validate_input(params),
        do: GSMLG.GaoNote.MCP.AgentNoteTools.validate_peri(unquote(name), params)

      @doc false
      def validate_output(params),
        do: GSMLG.GaoNote.MCP.AgentNoteTools.validate_output(unquote(name), params)

      # TODO(upstream): gsmlg-opt/backplane#58
      def mcp_schema(params), do: Peri.validate(__mcp_raw_schema__(), params)
      def mcp_output_schema(params), do: Peri.validate(__mcp_output_schema__(), params)
      @impl true
      def annotations, do: GSMLG.GaoNote.MCP.AgentNoteTools.annotations(unquote(name))
      @impl true
      def execute(params, frame),
        do: GSMLG.GaoNote.MCP.AgentNoteTools.execute(unquote(name), params, frame)
    end
  end
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.SaveNote do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "save_note"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.GetNote do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "get_note"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.ListNotes do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "list_notes"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.SemanticSearch do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "semantic_search"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.ReadNoteLines do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "read_note_lines"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.ReplaceNote do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "replace_note"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.PatchNote do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "patch_note"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.DeleteNote do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "delete_note"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.BulkUpdateNoteLabels do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "bulk_update_note_labels"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.PutNoteAttachment do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "put_note_attachment"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.GetNoteAttachmentContent do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "get_note_attachment_content"
end

defmodule GSMLG.GaoNote.MCP.AgentNoteTools.DeleteNoteAttachment do
  use GSMLG.GaoNote.MCP.AgentNoteToolComponent, name: "delete_note_attachment"
end
