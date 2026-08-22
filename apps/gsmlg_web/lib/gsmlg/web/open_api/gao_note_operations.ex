defmodule GSMLG.Web.OpenApi.GaoNoteOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/gao_notes" => %{
        "get" => list_notes(),
        "post" => create_note()
      },
      "/api/gao_notes/label_settings" => %{"get" => list_label_settings()},
      "/api/gao_notes/{id}" => %{
        "get" => get_note(),
        "put" => replace_note(),
        "patch" => patch_note()
      },
      "/api/gao_notes/{note_id}/attachments/{path}" => %{
        "get" => get_attachment()
      }
    }
  end

  defp list_notes do
    Operation.operation(
      "listGaoNotes",
      "GaoNote",
      "List public GaoNotes",
      %{"200" => Operation.json_response("GaoNotes", "NoteList")},
      parameters: [
        Operation.parameter("search", "query", %{"type" => "string"}, "Search text"),
        Operation.parameter("query", "query", %{"type" => "string"}, "Search text alias"),
        Operation.parameter(
          "label",
          "query",
          %{"type" => "string"},
          "Filter by label key or key=value"
        ),
        Operation.parameter("limit", "query", %{"type" => "integer"}, "Maximum results"),
        Operation.parameter("offset", "query", %{"type" => "integer"}, "Results offset")
      ],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp list_label_settings do
    Operation.operation(
      "listGaoNoteLabelSettings",
      "GaoNote",
      "List GaoNote label settings",
      %{"200" => Operation.json_response("Label settings", "LabelSettingList")},
      parameters: [
        Operation.parameter("limit", "query", %{"type" => "integer"}, "Maximum results")
      ],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp get_note do
    Operation.operation(
      "getGaoNote",
      "GaoNote",
      "Get a public GaoNote",
      %{
        "200" => Operation.json_response("GaoNote", "NoteEnvelope"),
        "404" => Operation.json_response("GaoNote not found", "ApiError")
      },
      parameters: [
        Operation.parameter("id", "path", %{"type" => "string", "format" => "uuid"}, "GaoNote ID")
      ],
      security: Operation.anonymous_or_bearer()
    )
  end

  defp create_note do
    Operation.operation(
      "createGaoNote",
      "GaoNote",
      "Create a GaoNote",
      write_responses(%{"201" => Operation.json_response("Created GaoNote", "NoteEnvelope")}),
      request_body: Operation.request_body("NoteCreateInput", "GaoNote to create"),
      security: Operation.bearer()
    )
  end

  defp replace_note do
    write_note("replaceGaoNote", "Replace a GaoNote")
  end

  defp patch_note do
    write_note("patchGaoNote", "Update a GaoNote")
  end

  defp write_note(operation_id, summary) do
    Operation.operation(
      operation_id,
      "GaoNote",
      summary,
      update_responses(%{"200" => Operation.json_response("Updated GaoNote", "NoteEnvelope")}),
      parameters: [
        Operation.parameter("id", "path", %{"type" => "string", "format" => "uuid"}, "GaoNote ID")
      ],
      request_body: Operation.request_body("NoteUpdateInput", "GaoNote updates"),
      security: Operation.bearer()
    )
  end

  defp get_attachment do
    Operation.operation(
      "getGaoNoteAttachment",
      "GaoNote",
      "Download a GaoNote attachment",
      %{
        "200" => binary_response("Attachment content"),
        "206" => binary_response("Partial attachment content"),
        "401" => Operation.json_response("Authentication required", "AuthError"),
        "404" => Operation.json_response("Attachment not found", "ApiError"),
        "416" => Operation.response("Requested byte range not satisfiable"),
        "503" => Operation.json_response("Attachment storage unavailable", "ApiError")
      },
      parameters: [
        Operation.parameter(
          "note_id",
          "path",
          %{"type" => "string", "format" => "uuid"},
          "GaoNote ID"
        ),
        Operation.parameter(
          "path",
          "path",
          %{"type" => "string"},
          "Greedily captures the remaining slash-delimited attachment path; clients must encode path segments appropriately"
        )
        |> Map.put("x-gsmlg-greedy-path", true),
        Operation.parameter("Range", "header", %{"type" => "string"}, "Requested byte range")
      ],
      security: Operation.bearer()
    )
  end

  defp write_responses(success) do
    Map.merge(success, %{
      "400" => Operation.json_response("Invalid request", "ApiError"),
      "401" => Operation.json_response("Authentication required", "AuthError"),
      "409" => Operation.json_response("Conflicting GaoNote state", "ApiError"),
      "422" => Operation.json_response("Invalid GaoNote data", "ApiError"),
      "500" => Operation.json_response("GaoNote write failed", "ApiError")
    })
  end

  defp update_responses(success) do
    write_responses(success)
    |> Map.put("404", Operation.json_response("GaoNote not found", "ApiError"))
  end

  defp binary_response(description),
    do:
      Operation.response(description, "*/*", %{
        "type" => "string",
        "format" => "binary"
      })
end
