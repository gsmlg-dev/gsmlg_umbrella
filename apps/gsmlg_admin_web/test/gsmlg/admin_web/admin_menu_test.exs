defmodule GSMLG.AdminWeb.AdminMenuTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.AdminMenu

  describe "sections/0" do
    test "returns the approved top-level sections" do
      assert ["Dashboard", "Content", "Cloud", "Service"] =
               AdminMenu.sections() |> Enum.map(& &1.title)
    end
  end

  describe "disabled placeholders" do
    test "keeps Lightsail visible but disabled" do
      assert %{id: "lightsail_instance", disabled: true, path: nil} =
               AdminMenu.find_item!("lightsail_instance")
    end
  end

  describe "active branch matching" do
    test "opens only the group containing the active item" do
      assert AdminMenu.group_open?(AdminMenu.find_group!("pki"), "pki_ca_list")
      refute AdminMenu.group_open?(AdminMenu.find_group!("aws"), "pki_ca_list")
    end

    test "prefers explicit active menu and falls back to path matching" do
      assert AdminMenu.active_id(nil, "/aws/dynamo_db") == "dynamo_db"
      assert AdminMenu.active_id("pki_ca_list", "/aws/dynamo_db") == "pki_ca_list"
    end
  end
end
