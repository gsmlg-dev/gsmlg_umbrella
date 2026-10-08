alias GSMLG.Web.GaoNoteController

for {name, body} <- [
      {"agent-note tuple labels", %{"title" => "Audit", "content" => "Body", "labels" => [["topic", "ecto"]]}},
      {"malformed labels collection", %{"title" => "Audit", "content" => "Body", "labels" => "topic=ecto"}},
      {"unexpected revision on legacy create", %{"title" => "Audit", "content" => "Body", "expected_revision" => 1}}
    ] do
  conn =
    Plug.Test.conn(:post, "/api/gao_notes", body)
    |> GSMLG.Web.Guardian.Plug.put_current_resource(%{id: "audit-only"})

  response = GaoNoteController.create(conn, body)
  IO.inspect(%{probe: name, status: response.status, body: response.resp_body})
end

IO.inspect(GSMLG.GaoNote.Note.__schema__(:fields), label: "note_schema_fields")
