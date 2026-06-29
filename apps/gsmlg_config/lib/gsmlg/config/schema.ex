defmodule GSMLG.Config.Schema do
  @moduledoc """
  Configuration schema validation for GSMLG applications.

  Uses NimbleOptions to validate configuration structure and types.
  """

  @gsmlg_schema [
    mnesia_dir: [
      type: :string,
      default: "",
      doc: "Directory for Mnesia database files"
    ],
    tailwind_path: [
      type: :string,
      doc: "Path to tailwindcss executable"
    ],
    bun_path: [
      type: :string,
      doc: "Path to bun executable"
    ]
  ]

  @logger_schema [
    log_level: [
      type: {:in, ["debug", "info", "warning", "error"]},
      default: "info",
      doc: "Log level for the application"
    ]
  ]

  @database_schema [
    username: [
      type: :string,
      required: true,
      doc: "Database username"
    ],
    password: [
      type: :string,
      required: true,
      doc: "Database password"
    ],
    hostname: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Database hostname (use this OR socket_dir, not both)"
    ],
    socket_dir: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Unix socket directory for local connections (use this OR hostname, not both)"
    ],
    database: [
      type: :string,
      required: true,
      doc: "Database name"
    ],
    port: [
      type: :pos_integer,
      default: 5432,
      doc: "Database port (only used with hostname, not socket_dir)"
    ],
    pool_size: [
      type: :pos_integer,
      default: 10,
      doc: "Database connection pool size"
    ],
    show_sensitive_data_on_connection_error: [
      type: :boolean,
      default: false,
      doc: "Show sensitive data on connection errors"
    ]
  ]

  @web_schema [
    url: [
      type: :string,
      required: true,
      doc: "Web application URL"
    ],
    secret_key_base: [
      type: :string,
      doc: "Phoenix secret key base (required for prod)"
    ],
    port: [
      type: :pos_integer,
      default: 4110,
      doc: "Web server port"
    ],
    server: [
      type: :boolean,
      default: true,
      doc: "Start the Phoenix server"
    ],
    user_register: [
      type: :boolean,
      default: false,
      doc: "Enable user registration"
    ],
    enable_adsense: [
      type: :boolean,
      default: false,
      doc: "Enable Google AdSense"
    ],
    show_icp: [
      type: :boolean,
      default: false,
      doc: "Show ICP information"
    ],
    check_origin: [
      type: {:or, [:boolean, {:list, :string}]},
      doc: "Check origin for WebSocket connections (boolean or list of allowed origins)"
    ]
  ]

  @admin_web_schema [
    url: [
      type: :string,
      required: true,
      doc: "Admin web application URL"
    ],
    secret_key_base: [
      type: :string,
      doc: "Phoenix secret key base (required for prod)"
    ],
    port: [
      type: :pos_integer,
      default: 4111,
      doc: "Admin web server port"
    ],
    server: [
      type: :boolean,
      default: true,
      doc: "Start the Phoenix server"
    ],
    user_register: [
      type: :boolean,
      default: false,
      doc: "Enable user registration"
    ],
    check_origin: [
      type: {:or, [:boolean, {:list, :string}]},
      doc: "Check origin for WebSocket connections (boolean or list of allowed origins)"
    ]
  ]

  @couchdb_schema [
    host: [
      type: :string,
      default: "localhost",
      doc: "CouchDB hostname"
    ],
    port: [
      type: :pos_integer,
      default: 5984,
      doc: "CouchDB port"
    ],
    username: [
      type: :string,
      doc: "CouchDB username"
    ],
    password: [
      type: :string,
      doc: "CouchDB password"
    ]
  ]

  @commander_schema [
    start: [
      type: :boolean,
      default: false,
      doc: "Start the commander service"
    ],
    name: [
      type: :string,
      default: "commander",
      doc: "Commander instance name"
    ],
    platform_url: [
      type: :string,
      doc: "Platform WebSocket URL"
    ],
    platform_key: [
      type: :string,
      doc: "Platform authentication key"
    ]
  ]

  @cluster_schema [
    enabled: [
      type: :boolean,
      default: false,
      doc: "Enable libcluster supervision"
    ],
    strategy: [
      type: {:in, ["epmd", "gossip", "local_epmd", "erlang_hosts"]},
      default: "epmd",
      doc: "libcluster strategy"
    ],
    topology_name: [
      type: :string,
      default: "gsmlg",
      doc: "Topology name used by libcluster"
    ],
    hosts: [
      type: {:list, :string},
      default: [],
      doc: "Static EPMD node names"
    ],
    connect_interval: [
      type: :pos_integer,
      default: 30_000,
      doc: "Reconnect interval in milliseconds for polling strategies"
    ],
    gossip_port: [
      type: :pos_integer,
      default: 45_892,
      doc: "Gossip UDP port"
    ],
    gossip_if_addr: [
      type: :string,
      default: "0.0.0.0",
      doc: "Gossip bind interface address"
    ],
    gossip_multicast_addr: [
      type: :string,
      default: "233.252.1.32",
      doc: "Gossip multicast or broadcast address"
    ],
    gossip_multicast_ttl: [
      type: :pos_integer,
      default: 1,
      doc: "Gossip multicast TTL"
    ],
    gossip_secret: [
      type: :string,
      default: "",
      doc: "Optional gossip encryption secret"
    ],
    gossip_broadcast_only: [
      type: :boolean,
      default: false,
      doc: "Use broadcast instead of multicast for gossip"
    ]
  ]

  @github_oauth_schema [
    client_id: [
      type: :string,
      default: "",
      doc: "GitHub OAuth client ID"
    ],
    client_secret: [
      type: :string,
      default: "",
      doc: "GitHub OAuth client secret"
    ]
  ]

  @web_push_schema [
    subject: [
      type: :string,
      required: true,
      doc: "Web Push subject (mailto: URL)"
    ],
    public_key: [
      type: :string,
      default: "",
      doc: "VAPID public key"
    ],
    private_key: [
      type: :string,
      default: "",
      doc: "VAPID private key"
    ]
  ]

  @scout_blocked_cidrs [
    "0.0.0.0/8",
    "127.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.31.196.0/24",
    "192.52.193.0/24",
    "192.88.99.0/24",
    "192.175.48.0/24",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "255.255.255.255/32",
    "::/128",
    "::/96",
    "::1/128",
    "::ffff:0:0/96",
    "64:ff9b::/96",
    "64:ff9b:1::/48",
    "100::/64",
    "100:0:0:1::/64",
    "fe80::/10",
    "fc00::/7",
    "ff00::/8",
    "2001::/23",
    "2001::/32",
    "2001:1::1/128",
    "2001:1::2/128",
    "2001:1::3/128",
    "2001:2::/48",
    "2001:3::/32",
    "2001:4:112::/48",
    "2001:10::/28",
    "2001:20::/28",
    "2001:30::/28",
    "2001:db8::/32",
    "2002::/16",
    "2620:4f:8000::/48",
    "3fff::/20",
    "5f00::/16"
  ]

  @scout_general_schema [
    instance_name: [
      type: :string,
      default: "GSMLG Scout",
      doc: "Scout instance display name"
    ],
    default_region: [
      type: :string,
      default: "local",
      doc: "Default Scout region"
    ],
    request_timeout_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Default request timeout in milliseconds"
    ]
  ]

  @scout_rabbitmq_schema [
    enabled: [
      type: :boolean,
      default: false,
      doc: "Enable Scout RabbitMQ integration"
    ],
    url: [
      type: :string,
      default: "amqp://guest:guest@localhost:5672",
      doc: "RabbitMQ connection URL"
    ],
    queues: [
      type: :map,
      default: %{},
      doc: "Scout RabbitMQ queue names"
    ],
    regional_queues: [
      type: :map,
      default: %{},
      doc: "Scout regional RabbitMQ queue names"
    ]
  ]

  @scout_fetch_schema [
    default_timeout_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Default fetch timeout in milliseconds"
    ],
    max_timeout_ms: [
      type: :pos_integer,
      default: 60_000,
      doc: "Maximum fetch timeout in milliseconds"
    ],
    max_page_size_bytes: [
      type: :pos_integer,
      default: 5_000_000,
      doc: "Maximum fetched page size in bytes"
    ],
    browser: [
      type: :map,
      default: %{},
      doc: "Scout browser fetch settings"
    ],
    retry: [
      type: :map,
      default: %{},
      doc: "Scout fetch retry settings"
    ]
  ]

  @scout_agent_schema [
    enabled: [
      type: :boolean,
      default: false,
      doc: "Enable Scout agent"
    ],
    id: [
      type: {:or, [:string, nil]},
      default: "",
      doc: "Scout agent ID"
    ],
    region: [
      type: :string,
      default: "local",
      doc: "Scout agent region"
    ],
    heartbeat_interval_ms: [
      type: :pos_integer,
      default: 10_000,
      doc: "Scout agent heartbeat interval in milliseconds"
    ],
    capacity: [
      type: :pos_integer,
      default: 16,
      doc: "Scout agent job capacity"
    ],
    browser_instances: [
      type: :pos_integer,
      default: 2,
      doc: "Scout agent browser instance count"
    ],
    page_concurrency: [
      type: :pos_integer,
      default: 16,
      doc: "Scout agent page concurrency"
    ],
    lightpanda_path: [
      type: :string,
      default: "lightpanda",
      doc: "Path to the Lightpanda executable"
    ]
  ]

  @scout_security_schema [
    allowed_schemes: [
      type: {:list, :string},
      default: ["http", "https"],
      doc: "URL schemes Scout may fetch"
    ],
    redirect_limit: [
      type: :non_neg_integer,
      default: 5,
      doc: "Maximum redirect count for Scout fetches"
    ],
    blocked_cidrs: [
      type: {:list, :string},
      default: @scout_blocked_cidrs,
      doc: "CIDR ranges blocked by Scout"
    ]
  ]

  @i18n_schema [
    default_locale: [
      type: :string,
      default: "zh-Hans",
      doc: "Fallback locale when none can be resolved"
    ]
  ]

  @storage_schema [
    s3_bucket: [
      type: :string,
      default: "gsmlg-storage",
      doc: "S3 bucket name for file storage"
    ],
    s3_endpoint: [
      type: :string,
      default: "",
      doc: "S3-compatible endpoint URL (empty for AWS S3, set for Minio/LocalStack)"
    ],
    s3_region: [
      type: :string,
      default: "us-east-1",
      doc: "S3 region"
    ],
    max_file_size: [
      type: :non_neg_integer,
      default: 5_368_709_120,
      doc: "Maximum file size in bytes (default 5GB)"
    ],
    cleanup_interval: [
      type: :pos_integer,
      default: 3_600_000,
      doc: "Cleanup worker interval in milliseconds (default 1 hour)"
    ],
    retention_window: [
      type: :pos_integer,
      default: 2_592_000,
      doc: "Soft-delete retention window in seconds (default 30 days)"
    ]
  ]

  @caddy_schema [
    start: [
      type: :boolean,
      default: false,
      doc: "Start the Caddy integration service"
    ],
    mode: [
      type: {:in, ["external", "embedded"]},
      default: "external",
      doc:
        "Caddy management mode: external (systemd/OS managed) or embedded (binary managed by this app)"
    ],
    admin_url: [
      type: :string,
      default: "http://localhost:2019",
      doc: "Caddy Admin API URL (TCP: http://host:port, Unix: unix:///path/to/caddy.sock)"
    ],
    health_interval: [
      type: :pos_integer,
      default: 15_000,
      doc: "Health check interval in milliseconds"
    ]
  ]

  @doc """
  Returns the complete configuration schema.
  """
  def schema do
    %{
      gsmlg: @gsmlg_schema,
      logger: @logger_schema,
      database: @database_schema,
      web: @web_schema,
      admin_web: @admin_web_schema,
      couchdb: @couchdb_schema,
      commander: @commander_schema,
      cluster: @cluster_schema,
      oauth: %{github: @github_oauth_schema},
      web_push: @web_push_schema,
      scout: %{
        general: @scout_general_schema,
        rabbitmq: @scout_rabbitmq_schema,
        fetch: @scout_fetch_schema,
        agent: @scout_agent_schema,
        security: @scout_security_schema
      },
      caddy: @caddy_schema,
      storage: @storage_schema,
      i18n: @i18n_schema
    }
  end

  @doc """
  Validates a configuration section against its schema.

  Returns `{:ok, validated_config}` on success or `{:error, reason}` on failure.
  """
  def validate_section(section, config) when is_atom(section) do
    schema = get_section_schema(section)

    case schema do
      nil ->
        {:ok, config}

      schema when is_list(schema) ->
        with {:ok, config_list} <- to_options(config) do
          case NimbleOptions.validate(config_list, schema) do
            {:ok, validated} ->
              {:ok, Map.new(validated)}

            {:error, %NimbleOptions.ValidationError{} = error} ->
              {:error, Exception.message(error)}
          end
        end

      schema when is_map(schema) ->
        # Nested schema (like oauth)
        validate_nested(config, schema)
    end
  end

  @doc """
  Validates the entire configuration map.

  Returns `{:ok, validated_config}` on success or `{:error, reasons}` on failure.
  """
  def validate(config) when is_map(config) do
    results =
      config
      |> Enum.map(fn {section, section_config} ->
        {section, validate_section(section, section_config)}
      end)

    errors =
      results
      |> Enum.filter(fn {_section, result} -> match?({:error, _}, result) end)
      |> Enum.map(fn {section, {:error, reason}} -> "#{section}: #{reason}" end)

    if Enum.empty?(errors) do
      validated =
        results
        |> Enum.map(fn
          {section, {:ok, validated}} -> {section, validated}
          {section, _} -> {section, %{}}
        end)
        |> Map.new()

      {:ok, validated}
    else
      {:error, Enum.join(errors, "; ")}
    end
  end

  @doc """
  Same as `validate/1` but raises on error.
  """
  def validate!(config) do
    case validate(config) do
      {:ok, validated} -> validated
      {:error, reason} -> raise ArgumentError, "Configuration validation failed: #{reason}"
    end
  end

  # Private functions

  defp get_section_schema(:gsmlg), do: @gsmlg_schema
  defp get_section_schema(:logger), do: @logger_schema
  defp get_section_schema(:database), do: @database_schema
  defp get_section_schema(:web), do: @web_schema
  defp get_section_schema(:admin_web), do: @admin_web_schema
  defp get_section_schema(:couchdb), do: @couchdb_schema
  defp get_section_schema(:commander), do: @commander_schema
  defp get_section_schema(:cluster), do: @cluster_schema
  defp get_section_schema(:oauth), do: %{github: @github_oauth_schema}
  defp get_section_schema(:web_push), do: @web_push_schema

  defp get_section_schema(:scout),
    do: %{
      general: @scout_general_schema,
      rabbitmq: @scout_rabbitmq_schema,
      fetch: @scout_fetch_schema,
      agent: @scout_agent_schema,
      security: @scout_security_schema
    }

  defp get_section_schema(:caddy), do: @caddy_schema
  defp get_section_schema(:storage), do: @storage_schema
  defp get_section_schema(:i18n), do: @i18n_schema
  defp get_section_schema(_), do: nil

  defp validate_nested(config, _schema) when not is_map(config) do
    {:error, "expected a map, got: #{inspect(config)}"}
  end

  defp validate_nested(config, schema) when is_map(schema) do
    results =
      config
      |> Enum.map(fn {key, value} ->
        nested_schema = Map.get(schema, key)

        result =
          case nested_schema do
            nil ->
              {:ok, value}

            nested_schema when is_list(nested_schema) ->
              with {:ok, value_list} <- to_options(value) do
                case NimbleOptions.validate(value_list, nested_schema) do
                  {:ok, validated} ->
                    {:ok, Map.new(validated)}

                  {:error, %NimbleOptions.ValidationError{} = error} ->
                    {:error, Exception.message(error)}
                end
              end

            _ ->
              {:ok, value}
          end

        {key, result}
      end)

    errors =
      results
      |> Enum.filter(fn {_key, result} -> match?({:error, _}, result) end)
      |> Enum.map(fn {key, {:error, reason}} -> "#{key}: #{reason}" end)

    if Enum.empty?(errors) do
      validated =
        results
        |> Enum.map(fn
          {key, {:ok, validated}} -> {key, validated}
          {key, _} -> {key, %{}}
        end)
        |> Map.new()

      {:ok, validated}
    else
      {:error, Enum.join(errors, "; ")}
    end
  end

  defp to_options(nil), do: {:ok, []}
  defp to_options(config) when is_map(config), do: {:ok, Map.to_list(config)}

  defp to_options(config) when is_list(config) do
    if Keyword.keyword?(config) do
      {:ok, config}
    else
      {:error, "expected a map or keyword list, got: #{inspect(config)}"}
    end
  end

  defp to_options(config), do: {:error, "expected a map or keyword list, got: #{inspect(config)}"}
end
