defmodule GSMLG.Web.GaoNoteLabelControllerTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.Accounts.User
  alias GSMLG.GaoNote
  alias GSMLG.Repo

  test "public index accepts labels and filters by label", %{conn: conn} do
    matching = note_fixture("Public matching label", ["topic=ecto"])
    _other = note_fixture("Public other label", ["topic=phoenix"])

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/gao_notes", %{"label" => "topic=ecto"})

    assert %{"data" => [presented]} = json_response(conn, 200)
    assert presented["id"] == matching.id
    assert [%{"key" => "topic", "value" => "ecto"}] = presented["labels"]
    refute Map.has_key?(presented, "creator")
  end

  defp note_fixture(title, labels) do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: title, content: "Public label content", labels: labels},
               actor()
             )

    note
  end

  defp actor do
    Repo.get(User, "public-label-filter") ||
      Repo.insert!(%User{
        id: "public-label-filter",
        username: "public-label-filter",
        email: "public-label-filter@example.test",
        password: "test"
      })
  end
end
