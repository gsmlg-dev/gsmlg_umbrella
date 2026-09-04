defmodule GSMLG.AdminWeb.StorageLive.ShowTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @secret_key_base String.duplicate("s", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
    end)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{conn: conn}
  end

  test "renders non-empty metadata with the JSON custom element", %{conn: conn} do
    file =
      Repo.insert!(%StorageFile{
        tenant: "test",
        type: "document",
        filename: "metadata.json",
        s3_key: "test/document/metadata.json",
        content_type: "application/json",
        size: 2,
        metadata: %{"count" => 2, "nested" => %{"enabled" => true}}
      })

    html =
      conn
      |> get(~p"/storage/#{file.id}")
      |> html_response(200)

    document = Floki.parse_document!(html)

    assert [_code_block] =
             Floki.find(document, "el-dm-code-block[language='json'][copyable]")

    assert [json_element] = Floki.find(document, "el-gsmlg-json")
    assert json_element |> Floki.text() |> String.trim() == JSON.encode!(file.metadata)
  end

  defp with_secret_key_base(conn), do: %{conn | secret_key_base: @secret_key_base}
end
