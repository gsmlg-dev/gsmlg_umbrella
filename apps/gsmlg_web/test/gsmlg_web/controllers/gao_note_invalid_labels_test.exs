defmodule GSMLG.Web.GaoNoteInvalidLabelsTest do
  use ExUnit.Case, async: true

  test "legacy malformed labels do not become internal server errors" do
    attrs = %{"title" => "Audit", "content" => "Body", "labels" => "not an array"}

    conn =
      Plug.Test.conn(:post, "/api/gao_notes", attrs)
      |> GSMLG.Web.Guardian.Plug.put_current_resource(%{id: "audit-only"})

    result = GSMLG.Web.GaoNoteController.create(conn, attrs)
    assert result.status == 400
    assert Jason.decode!(result.resp_body)["errors"]["labels"]
  end
end
