defmodule GSMLG.Web.AgentNoteControllerTest do
  use GSMLG.Web.ConnCase, async: false

  import GSMLG.AccountsFixtures
  alias GSMLG.GaoNote

  setup do
    user = user_fixture()
    {:ok, token, _} = GSMLG.Web.Guardian.encode_and_sign(user, %{}, token_type: "access")
    %{user: user, token: token}
  end

  test "create and detail accept tuple labels and Unix revision DTO", %{token: token} do
    created =
      request(token)
      |> post(
        "/api/notes",
        Jason.encode!(%{title: "Compatible", content: "Body", labels: [["topic", "ecto"]]})
      )

    assert %{"id" => id} = json_response(created, 200)

    assert %{
             "id" => ^id,
             "revision" => 1,
             "labels" => [["topic", "ecto"]],
             "content" => "Body",
             "created_at" => timestamp
           } =
             request(token) |> get("/api/notes/#{id}") |> json_response(200)

    assert is_integer(timestamp)
  end

  test "list summaries omit content and attachments and zero limit is empty", %{
    user: user,
    token: token
  } do
    assert {:ok, _} = GaoNote.create_note(%{title: "Listed", content: "Secret body"}, user)

    assert [%{"title" => "Listed", "revision" => 1} = summary] =
             request(token) |> get("/api/notes") |> json_response(200)

    refute Map.has_key?(summary, "content")
    refute Map.has_key?(summary, "attachments")
    assert [] = request(token) |> get("/api/notes?limit=0") |> json_response(200)
    assert %{"total" => 1} = request(token) |> get("/api/notes/count") |> json_response(200)
  end

  test "PUT rejects stale revisions and DELETE soft-deletes", %{user: user, token: token} do
    assert {:ok, note} = GaoNote.create_note(%{title: "Old", content: "Body"}, user)
    attrs = %{expected_revision: 1, title: "New", content: "Body", labels: [], attachments: []}

    assert %{"revision" => 2, "title" => "New"} =
             request(token)
             |> put("/api/notes/#{note.id}", Jason.encode!(attrs))
             |> json_response(200)

    assert %{"code" => "revision_conflict", "retryable" => false} =
             request(token)
             |> put("/api/notes/#{note.id}", Jason.encode!(attrs))
             |> json_response(409)

    assert response(request(token) |> delete("/api/notes/#{note.id}?expected_revision=2"), 204) ==
             ""

    assert response(request(token) |> get("/api/notes/#{note.id}"), 404) =~ "not found"

    assert [%{"id" => id, "revision" => 3, "deleted_at" => deleted}] =
             request(token) |> get("/api/trash") |> json_response(200)

    assert id == note.id
    assert is_integer(deleted)
  end

  test "malformed selector and labels are client errors", %{token: token} do
    assert response(request(token) |> get("/api/notes?label=~bad"), 400) =~ "selector"

    assert response(
             request(token)
             |> post(
               "/api/notes",
               Jason.encode!(%{title: "Bad", content: "Body", labels: "not an array"})
             ),
             400
           ) != ""
  end

  test "canonical writes preserve existing authentication" do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    assert response(
             post(conn, "/api/notes", Jason.encode!(%{title: "Unsafe", content: "Body"})),
             401
           ) != ""
  end

  test "PUT validates required string content, tuple labels and revision", %{
    user: user,
    token: token
  } do
    {:ok, note} = GaoNote.create_note(%{title: "Validation", content: "body"}, user)

    assert %{"code" => "expected_revision_required"} =
             request(token)
             |> put("/api/notes/#{note.id}", Jason.encode!(%{title: "Changed", content: "body"}))
             |> json_response(400)

    assert %{"code" => "invalid_input"} =
             request(token)
             |> put(
               "/api/notes/#{note.id}",
               Jason.encode!(%{
                 title: "Changed",
                 content: %{apply_patch: "@@"},
                 expected_revision: 1
               })
             )
             |> json_response(400)

    assert response(request(token) |> get("/api/notes/count?limit=bad"), 400) != ""

    assert %{"code" => "invalid_input"} =
             request(token)
             |> post("/api/trash/restore", Jason.encode!(%{notes: []}))
             |> json_response(400)

    assert GaoNote.get_note(note.id).revision == 1
  end

  test "malformed JSON uses operation error shape and malformed target is a client error", %{
    token: token
  } do
    assert %{"code" => "invalid_input", "retryable" => false} =
             request(token)
             |> put("/api/notes/#{Ecto.UUID.generate()}", "{")
             |> json_response(400)

    assert response(request(token) |> post("/api/notes", "{"), 400) != ""

    assert %{"code" => "invalid_input"} =
             request(token)
             |> post("/api/notes/batch-delete", Jason.encode!(%{notes: ["bad"]}))
             |> json_response(400)
  end

  test "catalog bulk selected batch and Trash endpoints retain wire statuses", %{token: token} do
    assert response(
             request(token)
             |> post(
               "/api/labels",
               Jason.encode!(%{key: "Topic", description: "Upper", value_type: "text"})
             ),
             200
           ) == ""

    assert response(
             request(token) |> put("/api/labels/Topic", Jason.encode!(%{description: "Changed"})),
             200
           ) == ""

    assert [%{"key" => "Topic", "description" => "Changed", "value_type" => "text"}] =
             request(token) |> get("/api/labels") |> json_response(200)

    %{"id" => id} =
      request(token)
      |> post(
        "/api/notes",
        Jason.encode!(%{title: "Batch", content: "Body", labels: [["Topic", "x"]]})
      )
      |> json_response(200)

    assert %{"matched" => 1, "updated" => 1, "unchanged" => 0} =
             request(token)
             |> post(
               "/api/notes/bulk-labels",
               Jason.encode!(%{selector: "Topic=x", set: [["team", "core"]]})
             )
             |> json_response(200)

    assert %{"requested" => 1, "updated" => 1} =
             request(token)
             |> post(
               "/api/notes/batch-labels",
               Jason.encode!(%{
                 notes: [%{id: id, expected_revision: 2}],
                 action: %{type: "remove", key: "team"}
               })
             )
             |> json_response(200)

    assert %{"requested" => 1, "deleted" => 1} =
             request(token)
             |> post(
               "/api/notes/batch-delete",
               Jason.encode!(%{notes: [%{id: id, expected_revision: 3}]})
             )
             |> json_response(200)

    assert response(
             request(token)
             |> post(
               "/api/trash/restore",
               Jason.encode!(%{
                 notes: [%{id: id, expected_revision: 4}, %{id: id, expected_revision: 4}]
               })
             ),
             204
           ) == ""

    assert response(request(token) |> delete("/api/notes/#{id}?expected_revision=5"), 204) == ""
    assert response(request(token) |> delete("/api/trash/#{id}?expected_revision=6"), 204) == ""
    assert [] = request(token) |> get("/api/trash") |> json_response(200)
    assert response(request(token) |> delete("/api/labels/Topic"), 200) == ""
  end

  defp request(token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end
end
