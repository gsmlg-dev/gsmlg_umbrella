defmodule GSMLG.AdminWeb.AdminMenuTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.AdminMenu

  describe "sections/0" do
    test "returns the approved top-level sections" do
      assert ["Dashboard", "Content", "Cloud", "Service"] =
               AdminMenu.sections() |> Enum.map(& &1.title)
    end

    test "does not expose the removed PKI module" do
      refute Enum.any?(AdminMenu.sections(), fn section ->
               Enum.any?(section.groups, &(&1.id == "pki"))
             end)

      assert_raise ArgumentError, fn -> AdminMenu.find_group!("pki") end
      assert AdminMenu.active_id(nil, "/pki/ca") == nil
    end

    test "does not expose removed legacy platform and mnesia modules" do
      refute Enum.any?(AdminMenu.enabled_items(), &(&1.id == "command_platform_legacy"))
      refute Enum.any?(AdminMenu.enabled_items(), &(&1.id == "mnesia"))

      assert_raise ArgumentError, fn -> AdminMenu.find_item!("command_platform_legacy") end
      assert_raise ArgumentError, fn -> AdminMenu.find_item!("mnesia") end

      assert AdminMenu.active_id(nil, "/command_platform") == nil
      assert AdminMenu.active_id(nil, "/mnesia") == nil
    end

    test "includes GaoNote under the content section" do
      content = Enum.find(AdminMenu.sections(), &(&1.id == "content"))

      assert %{id: "gao_notes", title: "GaoNote"} =
               gao_notes =
               Enum.find(content.groups, &(&1.id == "gao_notes"))

      assert [
               %{id: "gao_note_list", label: "Note List", path: "/gao_notes/notes"},
               %{id: "gao_note_tags", label: "Tags", path: "/gao_notes/tags"},
               %{
                 id: "gao_note_references",
                 label: "Note References",
                 path: "/gao_notes/references"
               },
               %{id: "gao_note_assets", label: "Note Assets", path: "/gao_notes/assets"},
               %{id: "gao_note_logs", label: "Log", path: "/gao_notes/logs"},
               %{id: "gao_note_mcp", label: "MCP", path: "/gao_notes/mcp"}
             ] = gao_notes.items
    end

    test "includes Scout under the service section" do
      service = Enum.find(AdminMenu.sections(), &(&1.id == "service"))

      assert %{id: "scout", title: "Scout"} =
               scout =
               Enum.find(service.groups, &(&1.id == "scout"))

      assert [
               %{id: "scout_dashboard", label: "Scout Dashboard", path: "/scout"}
             ] = scout.items
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
      assert AdminMenu.group_open?(AdminMenu.find_group!("caddy"), "caddy_dashboard")
      refute AdminMenu.group_open?(AdminMenu.find_group!("aws"), "caddy_dashboard")
    end

    test "prefers explicit active menu and falls back to path matching" do
      assert AdminMenu.active_id(nil, "/aws/dynamo_db") == "dynamo_db"
      assert AdminMenu.active_id("caddy_dashboard", "/aws/dynamo_db") == "caddy_dashboard"
    end

    test "matches GaoNote routes to their content menu items" do
      assert AdminMenu.active_id(nil, "/gao_notes/notes") == "gao_note_list"
      assert AdminMenu.active_id(nil, "/gao_notes/notes/new") == "gao_note_list"
      assert AdminMenu.active_id(nil, "/gao_notes/tags") == "gao_note_tags"
      assert AdminMenu.active_id(nil, "/gao_notes/references") == "gao_note_references"
      assert AdminMenu.active_id(nil, "/gao_notes/assets") == "gao_note_assets"
      assert AdminMenu.active_id(nil, "/gao_notes/logs") == "gao_note_logs"
      assert AdminMenu.active_id(nil, "/gao_notes/mcp") == "gao_note_mcp"
      assert AdminMenu.group_open?(AdminMenu.find_group!("gao_notes"), "gao_note_list")
    end

    test "matches Scout routes to the service menu item" do
      assert AdminMenu.active_id(nil, "/scout") == "scout_dashboard"
      assert AdminMenu.active_id(nil, "/scout/jobs") == "scout_dashboard"
      assert AdminMenu.group_open?(AdminMenu.find_group!("scout"), "scout_dashboard")
    end
  end

  describe "router" do
    test "does not expose PKI routes" do
      paths = GSMLG.AdminWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)

      refute Enum.any?(paths, &String.starts_with?(&1, "/pki"))
    end

    test "does not expose legacy platform or mnesia routes" do
      paths = GSMLG.AdminWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)

      refute "/command_platform" in paths
      refute "/pty_terminal/:agent_id" in paths
      refute "/mnesia" in paths
    end
  end
end
