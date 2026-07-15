defmodule GSMLG.AdminWeb.AdminMenu do
  @moduledoc """
  Central menu tree for the authenticated admin shell.

  The rendered navigation is intentionally three levels deep:
  section, group, and item.
  """

  @sections [
    %{
      id: "dashboard",
      title: "Dashboard",
      groups: [
        %{
          id: "dashboard_overview",
          title: "Overview",
          items: [
            %{id: "admin_home", label: "Admin Home", path: "/"},
            %{id: "live_dashboard", label: "Live Dashboard", path: "/live_dashboard"}
          ]
        }
      ]
    },
    %{
      id: "content",
      title: "Content",
      groups: [
        %{
          id: "users",
          title: "Users",
          items: [
            %{id: "user_list", label: "User List", path: "/users"},
            %{id: "user_token_list", label: "User Tokens", path: "/user_tokens"}
          ]
        },
        %{
          id: "blogs",
          title: "Blogs",
          items: [
            %{id: "blog_list", label: "Blog List", path: "/blogs"},
            %{id: "blog_import", label: "Import", path: "/blogs/import"},
            %{id: "blog_new", label: "New Blog", path: "/blogs/new"},
            %{id: "blog_settings", label: "Settings", path: "/blogs/settings"}
          ]
        },
        %{
          id: "gao_notes",
          title: "GaoNote",
          items: [
            %{id: "gao_note_list", label: "Note List", path: "/gao_notes/notes"},
            %{
              id: "gao_note_label_settings",
              label: "Label Settings",
              path: "/gao_notes/label_settings"
            },
            %{
              id: "gao_note_attachments",
              label: "Note Attachments",
              path: "/gao_notes/attachments"
            },
            %{id: "gao_note_recycle_bin", label: "Recycle Bin", path: "/gao_notes/recycle_bin"},
            %{id: "gao_note_logs", label: "Log", path: "/gao_notes/logs"},
            %{id: "gao_note_mcp", label: "MCP", path: "/gao_notes/mcp"}
          ]
        },
        %{
          id: "integrations",
          title: "Integrations",
          items: [
            %{id: "web_push_list", label: "Web Push", path: "/web_push"},
            %{id: "api_providers", label: "API Providers", path: "/api_providers"},
            %{id: "github", label: "Github", path: "/github"}
          ]
        }
      ]
    },
    %{
      id: "cloud",
      title: "Cloud",
      groups: [
        %{
          id: "aws",
          title: "AWS",
          items: [
            %{id: "dynamo_db", label: "DynamoDB: Table List", path: "/aws/dynamo_db"},
            %{
              id: "lightsail_instance",
              label: "Lightsail: Instance",
              path: nil,
              disabled: true
            },
            %{
              id: "route53_hosted_zone_list",
              label: "Route53: Hosted Zones",
              path: "/aws/route53/hosted_zones"
            },
            %{id: "s3_buckets_list", label: "S3: Bucket List", path: "/aws/s3/buckets"}
          ]
        }
      ]
    },
    %{
      id: "service",
      title: "Service",
      groups: [
        %{
          id: "cluster",
          title: "Cluster",
          items: [
            %{id: "node_management", label: "Node Management", path: "/node_management"}
          ]
        },
        %{
          id: "command_platform",
          title: "Command Platform",
          items: [
            %{id: "commander_list", label: "Commanders", path: "/commander/list"},
            %{id: "commander_tokens", label: "Agent Tokens", path: "/commander/tokens"}
          ]
        },
        %{
          id: "scout",
          title: "Scout",
          items: [
            %{id: "scout_dashboard", label: "Scout Dashboard", path: "/scout"}
          ]
        },
        %{
          id: "caddy",
          title: "Caddy",
          items: [
            %{id: "caddy_dashboard", label: "Dashboard", path: "/caddy"},
            %{id: "caddy_config", label: "Configuration", path: "/caddy/config"},
            %{id: "caddy_server", label: "Server Control", path: "/caddy/server"},
            %{id: "caddy_runtime", label: "Runtime Config", path: "/caddy/runtime"},
            %{id: "caddy_metrics", label: "Metrics", path: "/caddy/metrics"},
            %{id: "caddy_logs", label: "Logs", path: "/caddy/logs"}
          ]
        },
        %{
          id: "storage",
          title: "Storage",
          items: [
            %{id: "storage_files", label: "File Browser", path: "/storage"},
            %{id: "storage_config", label: "S3 Configuration", path: "/storage/config"}
          ]
        }
      ]
    }
  ]

  def sections, do: @sections

  def enabled_items do
    Enum.reject(flat_items(), &Map.get(&1, :disabled, false))
  end

  def find_item!(id) do
    Enum.find(flat_items(), &(&1.id == id)) ||
      raise ArgumentError, "unknown admin menu item: #{inspect(id)}"
  end

  def find_group!(id) do
    Enum.find(flat_groups(), &(&1.id == id)) ||
      raise ArgumentError, "unknown admin menu group: #{inspect(id)}"
  end

  def active?(item, active_menu) do
    is_binary(active_menu) and active_menu != "" and item.id == active_menu
  end

  def active_id(active_menu, _path) when is_binary(active_menu) and active_menu != "" do
    active_menu
  end

  def active_id(_active_menu, path) when is_binary(path) and path != "" do
    case item_for_path(path) do
      nil -> nil
      item -> item.id
    end
  end

  def active_id(_active_menu, _path), do: nil

  def group_open?(group, active_menu) do
    Enum.any?(group.items, &active?(&1, active_menu))
  end

  defp flat_groups do
    @sections
    |> Enum.flat_map(& &1.groups)
  end

  defp flat_items do
    @sections
    |> Enum.flat_map(& &1.groups)
    |> Enum.flat_map(& &1.items)
  end

  defp item_for_path(path) do
    enabled_items()
    |> Enum.filter(&path_matches?(&1.path, path))
    |> Enum.sort_by(&String.length(&1.path), :desc)
    |> List.first()
  end

  defp path_matches?(nil, _path), do: false
  defp path_matches?("/", path), do: path == "/"

  defp path_matches?(item_path, path),
    do: path == item_path or String.starts_with?(path, item_path <> "/")
end
