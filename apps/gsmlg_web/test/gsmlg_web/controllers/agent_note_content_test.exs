defmodule GSMLG.Web.AgentNoteContentTest do
  use GSMLG.Web.ConnCase, async: false
  import GSMLG.AccountsFixtures
  alias GSMLG.GaoNote

  test "Markdown, HTML and render sanitize active markup and preserve attachment URLs" do
    {:ok, note} =
      GaoNote.create_note(
        %{
          title: "Render",
          content: "![image](./image.png)\n<script>alert(1)</script>"
        },
        nil
      )

    raw = get(build_conn(), "/api/notes/#{note.id}/raw")
    assert response(raw, 200) == note.content
    assert get_resp_header(raw, "content-type") == ["text/markdown; charset=utf-8"]
    html = get(build_conn(), "/notes/#{note.id}/content?type=html")
    body = response(html, 200)
    assert body =~ "<!DOCTYPE html>"
    assert body =~ "/api/notes/#{note.id}/attachments/image.png"
    refute body =~ "<script>"
    assert get_resp_header(html, "content-security-policy") != []

    assert response(get(build_conn(), "/api/notes/#{note.id}/raw?type=markdown"), 400) =~
             "unsupported"
  end

  test "dashboard validates conditional ETag and export availability is honest" do
    {:ok, _} = GaoNote.create_note(%{title: "Dashboard", content: "body"}, nil)
    conn = get(build_conn(), "/api/dashboard")

    assert %{
             "note_count" => 1,
             "embedded_note_count" => 0,
             "recent_updates" => [%{"title" => "Dashboard"}]
           } = json_response(conn, 200)

    [etag] = get_resp_header(conn, "etag")

    assert response(
             build_conn() |> put_req_header("if-none-match", etag) |> get("/api/dashboard"),
             304
           ) == ""

    assert %{"markdown" => true, "pdf" => false} =
             build_conn() |> get("/api/export/capabilities") |> json_response(200)

    assert %{"code" => "pdf_export_disabled"} =
             authenticated_conn()
             |> get("/api/notes/missing/export/pdf?expected_revision=1")
             |> json_response(503)
  end

  defp authenticated_conn do
    user = user_fixture()
    {:ok, token, _} = GSMLG.Web.Guardian.encode_and_sign(user, %{}, token_type: "access")
    build_conn() |> put_req_header("authorization", "Bearer #{token}")
  end
end
