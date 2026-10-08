defmodule GSMLG.Web.OpenApi.AgentNoteOperations do
  @moduledoc false
  alias GSMLG.Web.OpenApi.Operation

  @read [
    {"/api/notes", "listAgentNotes", :summaries},
    {"/api/notes/count", "countAgentNotes", :count},
    {"/api/notes/{id}", "getAgentNote", :note},
    {"/api/notes/{id}/raw", "getAgentNoteRaw", :raw},
    {"/notes/{id}/content", "getAgentNoteContent", :raw},
    {"/api/notes/{id}/attachments/{path}", "getAgentNoteAttachment", :attachment},
    {"/api/trash", "listAgentNoteTrash", :trash},
    {"/api/labels", "listAgentNoteLabels", :labels},
    {"/api/dashboard", "getAgentNoteDashboard", :dashboard},
    {"/api/export/capabilities", "getAgentNoteExportCapabilities", :capabilities},
    {"/api/notes/{id}/export/pdf", "exportAgentNotePDF", :pdf}
  ]
  @write [
    {"/api/notes", "post", "saveAgentNote", :create},
    {"/api/notes/{id}", "put", "replaceAgentNote", :update},
    {"/api/notes/{id}", "delete", "deleteAgentNote", :delete},
    {"/api/notes/bulk-labels", "post", "bulkAgentNoteLabels", :bulk},
    {"/api/notes/batch-labels", "post", "batchAgentNoteLabels", :batch},
    {"/api/notes/batch-delete", "post", "batchDeleteAgentNotes", :batch_delete},
    {"/api/trash/restore", "post", "restoreAgentNotes", :restore},
    {"/api/trash/{id}", "delete", "purgeAgentNote", :delete},
    {"/api/labels", "post", "defineAgentNoteLabel", :define_label},
    {"/api/labels/{key}", "put", "updateAgentNoteLabel", :update_label},
    {"/api/labels/{key}", "delete", "deleteAgentNoteLabel", :delete_label},
    {"/api/notes/search", "post", "searchAgentNotes", :search},
    {"/api/render", "post", "renderAgentNote", :render}
  ]

  def paths do
    reads = Enum.map(@read, fn {path, id, kind} -> {path, "get", id, kind} end)

    Enum.reduce(reads ++ @write, %{}, fn {path, verb, id, kind}, paths ->
      security =
        if kind in [:search, :render] or (verb == "get" and kind not in [:attachment, :pdf]),
          do: Operation.anonymous_or_bearer(),
          else: Operation.bearer()

      op =
        Operation.operation(id, "Agent Note", id, responses(kind),
          security: security,
          parameters: parameters(path, kind)
        )

      op =
        case request(kind) do
          nil ->
            op

          schema ->
            Map.put(op, "requestBody", %{
              "required" => true,
              "content" => %{"application/json" => %{"schema" => schema}}
            })
        end

      Map.update(paths, path, %{verb => op}, &Map.put(&1, verb, op))
    end)
  end

  defp parameters(path, kind) do
    path_params =
      Regex.scan(~r/\{([^}]+)\}/, path)
      |> Enum.map(fn [_, key] -> Operation.parameter(key, "path", string(), key, true) end)

    query =
      case kind do
        :delete ->
          [
            Operation.parameter(
              "expected_revision",
              "query",
              revision(),
              "Revision from the last read",
              true
            )
          ]

        :pdf ->
          [
            Operation.parameter(
              "expected_revision",
              "query",
              revision(),
              "Saved revision to export",
              true
            )
          ]

        :raw ->
          [
            Operation.parameter(
              "type",
              "query",
              Map.put(string(), "enum", ["html"]),
              "Omit for Markdown"
            )
          ]

        k when k in [:summaries, :count] ->
          [
            Operation.parameter(
              "limit",
              "query",
              %{"type" => "integer", "default" => 10},
              "Clamped to 0..1000"
            ),
            Operation.parameter(
              "offset",
              "query",
              %{"type" => "integer", "default" => 0},
              "Clamped to non-negative"
            ),
            Operation.parameter("label", "query", string(), "AND label selector")
          ]

        _ ->
          []
      end

    path_params ++ query
  end

  defp responses(kind) do
    status = if kind in [:delete, :restore], do: "204", else: "200"

    success =
      case kind do
        :raw ->
          %{
            "description" => "Markdown or HTML",
            "content" => %{
              "text/markdown" => %{"schema" => string()},
              "text/html" => %{"schema" => string()}
            }
          }

        :render ->
          Operation.response("Rendered HTML", "text/html", string())

        :attachment ->
          Operation.response("Attachment bytes", "application/octet-stream", %{
            "type" => "string",
            "format" => "binary"
          })

        :pdf ->
          Operation.response("PDF download", "application/pdf", %{
            "type" => "string",
            "format" => "binary"
          })

        k when k in [:delete, :restore, :define_label, :update_label, :delete_label] ->
          Operation.response("Success")

        _ ->
          Operation.response("Success", "application/json", response_schema(kind))
      end

    success =
      if kind == :pdf do
        Map.put(success, "headers", %{
          "Cache-Control" => %{"schema" => string()},
          "X-Content-Type-Options" => %{"schema" => string()},
          "X-Note-Revision" => %{"schema" => revision()},
          "Content-Disposition" => %{"schema" => string()}
        })
      else
        success
      end

    structured = kind in [:update, :delete, :batch, :batch_delete, :restore, :pdf]

    err =
      if structured,
        do:
          Operation.response(
            "Operation failed",
            "application/json",
            object(
              %{
                "code" => string(),
                "message" => string(),
                "details" => %{"type" => "object"},
                "retryable" => %{"type" => "boolean"}
              },
              ~w(code message details retryable)
            )
          ),
        else: Operation.response("Operation failed", "text/plain", string())

    Map.merge(%{status => success}, Map.new(~w(400 404 409 500), &{&1, err}))
    |> then(fn responses ->
      if kind == :pdf,
        do: Map.merge(responses, Map.new(~w(413 422 429 502 503 504), &{&1, err})),
        else: responses
    end)
  end

  defp response_schema(:note), do: note()
  defp response_schema(:update), do: note()
  defp response_schema(:summaries), do: array(summary())

  defp response_schema(:trash),
    do:
      array(
        object(
          Map.put(summary()["properties"], "deleted_at", integer()),
          summary()["required"] ++ ["deleted_at"]
        )
      )

  defp response_schema(:labels), do: array(label())
  defp response_schema(:create), do: object(%{"id" => string()}, ["id"])
  defp response_schema(:count), do: object(%{"total" => integer()}, ["total"])

  defp response_schema(:capabilities),
    do:
      object(
        %{"markdown" => %{"type" => "boolean"}, "pdf" => %{"type" => "boolean"}},
        ~w(markdown pdf)
      )

  defp response_schema(:search),
    do:
      array(
        object(
          Map.put(summary()["properties"], "score", %{"type" => "number"}),
          summary()["required"] ++ ["score"]
        )
      )

  defp response_schema(:bulk), do: counts(~w(matched updated unchanged))
  defp response_schema(:batch), do: counts(~w(requested updated unchanged))
  defp response_schema(:batch_delete), do: counts(~w(requested deleted))

  defp response_schema(:dashboard),
    do:
      object(
        %{
          "note_count" => integer(),
          "embedded_note_count" => integer(),
          "embedding_note" =>
            object(%{"id" => string(), "title" => string()}, ~w(id title))
            |> Map.put("nullable", true),
          "label_count" => integer(),
          "last_updated_at" => Map.put(integer(), "nullable", true),
          "labels" =>
            array(
              object(
                Map.put(label()["properties"], "count", integer()),
                label()["required"] ++ ["count"]
              )
            ),
          "categories" =>
            array(
              object(
                %{
                  "key" => string(),
                  "description" => string(),
                  "values" =>
                    array(object(%{"value" => string(), "count" => integer()}, ~w(value count)))
                },
                ~w(key description values)
              )
            ),
          "recent_updates" =>
            array(
              object(
                %{"id" => string(), "title" => string(), "updated_at" => integer()},
                ~w(id title updated_at)
              )
            )
        },
        ~w(note_count embedded_note_count embedding_note label_count last_updated_at labels categories recent_updates)
      )

  defp request(kind) when kind in [:create, :update] do
    fields = %{
      "title" => string(),
      "content" => string(),
      "labels" => pairs(),
      "attachments" => array(attachment_request())
    }

    fields =
      if kind == :update, do: Map.put(fields, "expected_revision", revision()), else: fields

    object(
      fields,
      if(kind == :update, do: ~w(title content expected_revision), else: ~w(title content))
    )
  end

  defp request(:bulk),
    do:
      object(%{"selector" => string(), "set" => pairs(), "remove" => array(string())}, [
        "selector"
      ])

  defp request(:batch),
    do:
      object(
        %{
          "notes" => targets(),
          "action" => %{
            "oneOf" =>
              Enum.map(
                [{"add", ~w(key value)}, {"update", ~w(from_key key value)}, {"remove", ~w(key)}],
                fn {kind, keys} ->
                  object(
                    Map.new(keys, &{&1, string()})
                    |> Map.put("type", %{"type" => "string", "enum" => [kind]}),
                    ["type" | keys]
                  )
                end
              )
          }
        },
        ~w(notes action)
      )

  defp request(kind) when kind in [:batch_delete, :restore],
    do: object(%{"notes" => targets()}, ["notes"])

  defp request(:define_label),
    do: object(Map.put(label()["properties"], "key", string()), ~w(key description))

  defp request(:update_label),
    do: object(Map.delete(label()["properties"], "key"), ["description"])

  defp request(:search),
    do:
      object(
        %{"query" => string(), "limit" => Map.put(integer(), "minimum", 0), "label" => string()},
        ~w(query limit)
      )

  defp request(:render),
    do: object(%{"content" => string(), "attachment_base" => string()}, ["content"])

  defp request(_), do: nil

  defp summary,
    do:
      object(
        %{
          "id" => string(),
          "title" => string(),
          "labels" => pairs(),
          "created_at" => integer(),
          "updated_at" => integer(),
          "revision" => revision()
        },
        ~w(id title labels created_at updated_at revision)
      )

  defp note,
    do:
      object(
        Map.merge(summary()["properties"], %{
          "content" => string(),
          "attachments" => array(attachment())
        }),
        summary()["required"] ++ ~w(content attachments)
      )

  defp attachment,
    do:
      object(Map.new(~w(id path mime description), &{&1, string()}), ~w(id path mime description))

  defp attachment_request,
    do:
      attachment()
      |> Map.update!(
        "properties",
        &Map.merge(&1, %{
          "content" => string(),
          "content_base64" => Map.put(string(), "format", "byte")
        })
      )
      |> Map.put("required", ~w(id path mime))
      |> Map.put("anyOf", [%{"required" => ["content"]}, %{"required" => ["content_base64"]}])

  defp label,
    do:
      object(
        %{
          "key" => string(),
          "description" => string(),
          "value_type" => %{
            "type" => "string",
            "enum" => ~w(text number date time datetime version),
            "default" => "text"
          }
        },
        ~w(key description value_type)
      )

  defp targets,
    do:
      array(
        object(%{"id" => string(), "expected_revision" => revision()}, ~w(id expected_revision))
      )
      |> Map.put("minItems", 1)

  defp counts(keys), do: object(Map.new(keys, &{&1, integer()}), keys)

  defp pairs,
    do: array(%{"type" => "array", "items" => string(), "minItems" => 2, "maxItems" => 2})

  defp revision, do: Map.put(integer(), "minimum", 1)
  defp integer, do: %{"type" => "integer", "format" => "int64"}
  defp string, do: %{"type" => "string"}
  defp array(schema), do: %{"type" => "array", "items" => schema}

  defp object(fields, required),
    do: %{"type" => "object", "properties" => fields, "required" => required}
end
