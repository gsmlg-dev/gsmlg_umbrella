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
            %{id: "admin_home", icon: "home-outline", label: "Admin Home", path: "/"},
            %{
              id: "live_dashboard",
              icon: "chart-box-outline",
              label: "Live Dashboard",
              path: "/live_dashboard"
            }
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
            %{id: "user_list", icon: "account-group-outline", label: "User List", path: "/users"},
            %{
              id: "user_token_list",
              icon: "account-key-outline",
              label: "User Tokens",
              path: "/user_tokens"
            }
          ]
        },
        %{
          id: "blogs",
          title: "Blogs",
          items: [
            %{id: "blog_list", icon: "post-outline", label: "Blog List", path: "/blogs"},
            %{id: "blog_import", icon: "import", label: "Import", path: "/blogs/import"},
            %{
              id: "blog_new",
              icon: "text-box-plus-outline",
              label: "New Blog",
              path: "/blogs/new"
            },
            %{
              id: "blog_settings",
              icon: "cog-outline",
              label: "Settings",
              path: "/blogs/settings"
            }
          ]
        },
        %{
          id: "gao_notes",
          title: "GaoNote",
          items: [
            %{
              id: "gao_note_dashboard",
              icon: "notebook-outline",
              label: "Dashboard",
              path: "/gao_notes",
              exact: true
            },
            %{
              id: "gao_note_list",
              icon: "note-multiple-outline",
              label: "Note List",
              path: "/gao_notes/notes"
            },
            %{
              id: "gao_note_label_settings",
              icon: "label-outline",
              label: "Label Settings",
              path: "/gao_notes/label_settings"
            },
            %{
              id: "gao_note_recycle_bin",
              icon: "delete-outline",
              label: "Recycle Bin",
              path: "/gao_notes/recycle_bin"
            },
            %{id: "gao_note_logs", icon: "history", label: "Log", path: "/gao_notes/logs"},
            %{id: "gao_note_mcp", icon: "api", label: "MCP", path: "/gao_notes/mcp"},
            %{
              id: "gao_note_settings",
              icon: "cog-outline",
              label: "Settings",
              path: "/gao_notes/settings"
            }
          ]
        },
        %{
          id: "integrations",
          title: "Integrations",
          items: [
            %{id: "web_push_list", icon: "bell-outline", label: "Web Push", path: "/web_push"},
            %{
              id: "api_providers",
              icon: "puzzle-outline",
              label: "API Providers",
              path: "/api_providers"
            },
            %{id: "github", icon: "github", label: "Github", path: "/github"}
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
            %{
              id: "dynamo_db",
              icon: "table",
              label: "DynamoDB: Table List",
              path: "/aws/dynamo_db"
            },
            %{
              id: "lightsail_instance",
              icon: "server-outline",
              label: "Lightsail: Instance",
              path: nil,
              disabled: true
            },
            %{
              id: "route53_hosted_zone_list",
              icon: "dns-outline",
              label: "Route53: Hosted Zones",
              path: "/aws/route53/hosted_zones"
            },
            %{
              id: "s3_buckets_list",
              icon: "bucket-outline",
              label: "S3: Bucket List",
              path: "/aws/s3/buckets"
            }
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
            %{
              id: "node_management",
              icon: "sitemap-outline",
              label: "Node Management",
              path: "/node_management"
            }
          ]
        },
        %{
          id: "command_platform",
          title: "Command Platform",
          items: [
            %{
              id: "commander_list",
              icon: "console",
              label: "Commanders",
              path: "/commander/list"
            },
            %{
              id: "commander_tokens",
              icon: "key-outline",
              label: "Agent Tokens",
              path: "/commander/tokens"
            }
          ]
        },
        %{
          id: "browser_control",
          title: "Browser Control",
          items: [
            %{
              id: "browser_dashboard",
              icon: "web",
              label: "Dashboard",
              path: "/browser",
              exact: true
            },
            %{id: "browser_nodes", icon: "lan", label: "Nodes", path: "/browser/nodes"},
            %{
              id: "browser_profiles",
              icon: "account-box-outline",
              label: "Profiles",
              path: "/browser/profiles"
            },
            %{
              id: "browser_sessions",
              icon: "monitor",
              label: "Sessions",
              path: "/browser/sessions"
            },
            %{
              id: "browser_jobs",
              icon: "briefcase-outline",
              label: "Jobs",
              path: "/browser/jobs"
            },
            %{
              id: "browser_settings",
              icon: "cog-outline",
              label: "Settings",
              path: "/browser/settings"
            }
          ]
        },
        %{
          id: "scout",
          title: "Scout",
          items: [
            %{id: "scout_dashboard", icon: "radar", label: "Scout Dashboard", path: "/scout"}
          ]
        },
        %{
          id: "proxy_rules",
          title: "Proxy Rules",
          items: [
            %{
              id: "proxy_rules_dashboard",
              icon: "routes",
              label: "Dashboard",
              path: "/proxy-rules"
            }
          ]
        },
        %{
          id: "caddy",
          title: "Caddy",
          items: [
            %{
              id: "caddy_dashboard",
              icon: "view-dashboard-outline",
              label: "Dashboard",
              path: "/caddy"
            },
            %{
              id: "caddy_config",
              icon: "file-document-outline",
              label: "Configuration",
              path: "/caddy/config"
            },
            %{id: "caddy_server", icon: "server", label: "Server Control", path: "/caddy/server"},
            %{
              id: "caddy_runtime",
              icon: "cog-outline",
              label: "Runtime Config",
              path: "/caddy/runtime"
            },
            %{id: "caddy_metrics", icon: "chart-line", label: "Metrics", path: "/caddy/metrics"},
            %{id: "caddy_logs", icon: "text-box-outline", label: "Logs", path: "/caddy/logs"}
          ]
        },
        %{
          id: "storage",
          title: "Storage",
          items: [
            %{
              id: "storage_files",
              icon: "folder-outline",
              label: "File Browser",
              path: "/storage"
            },
            %{
              id: "storage_config",
              icon: "cloud-outline",
              label: "S3 Configuration",
              path: "/storage/config"
            }
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
    |> Enum.filter(&path_matches?(&1, path))
    |> Enum.sort_by(&String.length(&1.path), :desc)
    |> List.first()
  end

  defp path_matches?(%{path: nil}, _path), do: false
  defp path_matches?(%{path: "/"}, path), do: path == "/"
  defp path_matches?(%{path: item_path, exact: true}, path), do: path == item_path

  defp path_matches?(%{path: item_path}, path),
    do: path == item_path or String.starts_with?(path, item_path <> "/")
end
