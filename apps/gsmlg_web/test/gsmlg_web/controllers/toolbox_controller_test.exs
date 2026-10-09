defmodule GSMLG.Web.ToolboxControllerTest do
  use GSMLG.Web.ConnCase, async: false

  describe "index" do
    test "lists all tools", %{conn: conn} do
      conn = get(conn, ~p"/toolbox?lang=en")
      assert html_response(conn, 200) =~ "Toolbox"
    end
  end

  describe "ip_geo" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/toolbox/ip_geo?lang=en")
      document = conn |> html_response(200) |> Floki.parse_document!()

      assert document |> Floki.find("h1") |> Floki.text() |> String.trim() == "IP Geo"
      assert [_form] = Floki.find(document, "form#ip-geo-form")
      assert [_input] = Floki.find(document, "#ip-geo-form input#ip-input[name=ip]")
      assert [_submit] = Floki.find(document, "#ip-geo-form el-dm-button#ip-submit[type=submit]")
      assert [_result] = Floki.find(document, "#ip-result")
    end
  end

  describe "search ip_geo" do
    test "returns geolocation JSON when the IP is valid", %{conn: conn} do
      install_city_fixture()
      conn = get(conn, ~p"/api/toolbox/ip_geo", ip: "2.4.6.8")

      assert %{"data" => %{"country" => "France", "country_code" => "FR"}} =
               json_response(conn, 200)
    end

    test "returns an error JSON response when the IP is invalid", %{conn: conn} do
      conn = get(conn, ~p"/api/toolbox/ip_geo", ip: "not an ip")
      assert json_response(conn, 422) == %{"error" => "einval"}
    end
  end

  defp install_city_fixture do
    table = :gsmlg_ip_geo_databases
    original = :ets.lookup(table, :city)

    on_exit(fn ->
      :ets.delete(table, :city)
      :ets.insert(table, original)
    end)

    metadata = %MMDB2Decoder.Metadata{
      ip_version: 4,
      node_count: 1,
      record_size: 24,
      node_byte_size: 6
    }

    # Both branches point to data offset 0: node_count + 16 separator bytes.
    tree = <<17::24, 17::24>>

    # MMDB maps/UTF-8 strings encode country.names.en and country.iso_code.
    data =
      <<0xE1, 0x47, "country", 0xE2, 0x45, "names", 0xE1, 0x42, "en", 0x46, "France", 0x48,
        "iso_code", 0x42, "FR">>

    :ets.insert(table, {:city, metadata, tree, data})
  end
end
