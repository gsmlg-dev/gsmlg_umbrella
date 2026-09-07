defmodule GSMLG.Config.Schema do
  @moduledoc """
  Configuration schema validation for GSMLG applications.

  Uses NimbleOptions to validate configuration structure and types.
  """

  @gsmlg_schema [
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
    client_certificate_auth: [
      type: :boolean,
      default: false,
      doc: "Trust reverse-proxy-verified client certificate headers for admin browser login"
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

  @commander_tls_schema [
    enabled: [
      type: :boolean,
      default: false,
      doc: "Enable Commander mutual TLS client authentication"
    ],
    client_cert_file: [
      type: :string,
      doc: "Runtime-secret client certificate chain PEM path"
    ],
    client_key_file: [
      type: :string,
      doc: "Runtime-secret client private key PEM path"
    ],
    ca_cert_file: [
      type: :string,
      doc: "Optional server CA bundle PEM path"
    ],
    reload_interval_ms: [
      type: :pos_integer,
      default: 60_000,
      doc: "Client certificate rotation check interval"
    ]
  ]

  @commander_schema [
    start: [
      type: :boolean,
      default: false,
      doc: "Start the commander service"
    ],
    server: [
      type: :boolean,
      default: false,
      doc: "Start Commander in server mode"
    ],
    name: [
      type: :string,
      default: "commander",
      doc: "Commander instance name"
    ],
    credential_id: [
      type: :string,
      doc: "Per-node Commander application credential identifier"
    ],
    umbrella_server_url: [
      type: :string,
      doc: "Umbrella admin server URL used to derive the Commander WebSocket URL"
    ],
    platform_url: [
      type: :string,
      doc: "Platform WebSocket URL"
    ],
    platform_key: [
      type: :string,
      doc: "Platform authentication key"
    ],
    platform_key_env: [
      type: :string,
      default: "GSMLG_COMMANDER_PLATFORM_KEY",
      doc: "Runtime environment variable containing the platform authentication key"
    ],
    platform_credentials: [
      type: :map,
      default: %{},
      doc: "Runtime-injected per-node Commander credential map"
    ],
    platform_credentials_env: [
      type: :string,
      default: "GSMLG_COMMANDER_PLATFORM_CREDENTIALS_JSON",
      doc: "Runtime environment variable containing the per-node credential JSON map"
    ],
    auth_timestamp_window_seconds: [
      type: :pos_integer,
      default: 60,
      doc: "Maximum Commander signature clock skew"
    ],
    auth_nonce_ttl_ms: [
      type: :pos_integer,
      default: 120_000,
      doc: "Commander authentication nonce replay window"
    ],
    max_in_flight_rpcs: [
      type: :pos_integer,
      default: 2,
      doc: "Maximum simultaneously executing Commander capability RPCs"
    ],
    features: [
      type: {:list, :string},
      default: ["pty"],
      doc: "Commander features enabled on this agent"
    ],
    tls: [
      type: :map,
      default: %{},
      doc: "Commander client TLS settings"
    ]
  ]

  @browser_agent_security_schema [
    allow_css_locator: [
      type: :boolean,
      default: false,
      doc: "Permit the fixed internal CSS locator fallback"
    ],
    allowed_origins: [
      type: {:list, :string},
      default: [],
      doc: "Origins the Browser Agent may authorize for remote sessions"
    ],
    allowed_upload_origins: [
      type: {:list, :string},
      default: [],
      doc: "Origins the Browser Agent may use for signed artifact uploads"
    ]
  ]

  @browser_jobs_schema [
    dispatch_timeout_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Maximum time to wait for the remote workflow acceptance"
    ],
    reconcile_interval_ms: [
      type: :pos_integer,
      default: 30_000,
      doc: "Interval for reconciling non-terminal Browser jobs"
    ],
    default_deadline_ms: [
      type: :pos_integer,
      default: 7_200_000,
      doc: "Central authority for new Browser workflow deadlines"
    ],
    max_attempts: [
      type: :pos_integer,
      default: 3,
      doc: "Maximum explicit Browser job attempts"
    ]
  ]

  @browser_security_schema [
    allowed_schemes: [
      type: {:list, :string},
      default: ["https"],
      doc: "URL schemes exposed by Browser control"
    ],
    allow_css_locator: [
      type: :boolean,
      default: false,
      doc: "Permit the fixed internal CSS locator fallback"
    ],
    allow_downloads: [
      type: :boolean,
      default: true,
      doc: "Permit bounded downloads as verified artifacts"
    ],
    max_observation_bytes: [
      type: :pos_integer,
      default: 1_048_576,
      doc: "Maximum semantic observation size"
    ],
    max_artifact_bytes: [
      type: :pos_integer,
      default: 104_857_600,
      doc: "Maximum verified Browser artifact size"
    ]
  ]

  @browser_schema [
    enabled: [
      type: :boolean,
      default: false,
      doc: "Start the central Browser control service"
    ],
    default_node: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Optional default Commander Browser node"
    ],
    inline_artifact_max_bytes: [
      type: :pos_integer,
      default: 131_072,
      doc: "Whole encoded inline artifact response ceiling"
    ],
    event_retention_days: [
      type: :pos_integer,
      default: 30,
      doc: "Browser event and artifact retention period"
    ],
    upload_base_url: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Public HTTPS base URL for dedicated artifact uploads"
    ],
    upload_ttl_seconds: [
      type: :pos_integer,
      default: 300,
      doc: "Lifetime of an artifact upload capability"
    ],
    jobs: [
      type: :map,
      default: %{},
      doc: "Browser job scheduling settings"
    ],
    security: [
      type: :map,
      default: %{},
      doc: "Central Browser security limits"
    ]
  ]

  @browser_agent_schema [
    enabled: [
      type: :boolean,
      default: false,
      doc: "Start the remote Browser Agent"
    ],
    backend: [
      type: {:in, ["cloakbrowser"]},
      default: "cloakbrowser",
      doc: "Remote browser Manager backend"
    ],
    manager_url: [
      type: :string,
      default: "http://127.0.0.1:8080",
      doc: "Loopback CloakBrowser Manager URL"
    ],
    manager_token_env: [
      type: :string,
      default: "CLOAKBROWSER_MANAGER_TOKEN",
      doc: "Environment variable containing the Manager Bearer token"
    ],
    state_dir: [
      type: :string,
      default: "/var/lib/gsmlg/browser-agent",
      doc: "Browser Agent local durable-state directory"
    ],
    default_profile_id: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "Optional default Manager profile ID"
    ],
    max_concurrent_sessions: [
      type: :pos_integer,
      default: 1,
      doc: "Maximum concurrent Browser sessions"
    ],
    max_concurrent_workflows: [
      type: :pos_integer,
      default: 1,
      doc: "Maximum concurrent Browser workflows"
    ],
    keep_profile_running: [
      type: :boolean,
      default: true,
      doc: "Keep the default Manager profile running between tasks"
    ],
    manager_connect_timeout_ms: [
      type: :pos_integer,
      default: 2_000,
      doc: "Manager connection-pool timeout"
    ],
    request_timeout_ms: [
      type: :pos_integer,
      default: 5_000,
      doc: "Manager response timeout"
    ],
    max_response_bytes: [
      type: :pos_integer,
      default: 1_048_576,
      doc: "Maximum buffered Manager response body"
    ],
    max_observation_bytes: [
      type: :pos_integer,
      default: 1_048_576,
      doc: "Maximum semantic observation size"
    ],
    max_artifact_bytes: [
      type: :pos_integer,
      default: 104_857_600,
      doc: "Maximum artifact size retained by the remote outbox"
    ],
    inline_artifact_max_bytes: [
      type: :pos_integer,
      default: 131_072,
      doc: "Whole encoded inline artifact response ceiling"
    ],
    monitor_interval_ms: [
      type: :pos_integer,
      default: 15_000,
      doc: "Manager health poll interval"
    ],
    lease_ttl_ms: [
      type: :pos_integer,
      default: 7_200_000,
      doc: "Default remote profile lease lifetime"
    ],
    journal_terminal_max_records: [
      type: :pos_integer,
      default: 10_000,
      doc: "Maximum retained terminal records per Browser Agent journal namespace"
    ],
    journal_terminal_max_age_ms: [
      type: :pos_integer,
      default: 2_592_000_000,
      doc: "Maximum age of retained terminal Browser Agent journal records"
    ],
    journal_terminal_max_bytes: [
      type: :pos_integer,
      default: 67_108_864,
      doc: "Maximum encoded bytes retained per terminal Browser Agent journal namespace"
    ],
    journal_recovery_scan_max_records: [
      type: :pos_integer,
      default: 10_000,
      doc: "Maximum unresolved records considered by one Browser Agent recovery scan"
    ],
    security: [
      type: :map,
      default: %{},
      doc: "Browser Agent security settings"
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

  @proxy_rules_schema [
    source_url: [
      type: :string,
      default: "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
      doc: "Remote GFWList source URL"
    ],
    remote_refresh_interval: [
      type: :pos_integer,
      default: 86_400_000,
      doc: "Remote refresh interval in milliseconds"
    ],
    remote_connect_timeout: [
      type: :pos_integer,
      default: 5_000,
      doc: "Remote connection timeout in milliseconds"
    ],
    remote_receive_timeout: [
      type: :pos_integer,
      default: 30_000,
      doc: "Remote response timeout in milliseconds"
    ],
    remote_max_body_size: [
      type: :pos_integer,
      default: 10_000_000,
      doc: "Maximum remote response body size in bytes"
    ],
    retry_min_interval: [
      type: :pos_integer,
      default: 5_000,
      doc: "Minimum retry interval in milliseconds"
    ],
    retry_max_interval: [
      type: :pos_integer,
      default: 300_000,
      doc: "Maximum retry interval in milliseconds"
    ],
    retry_jitter: [
      type: :boolean,
      default: true,
      doc: "Apply jitter to retry intervals"
    ],
    local_proxy_list_path: [
      type: :string,
      default: "/etc/gsmlg/proxy-rules/proxy-list.txt",
      doc: "Local proxy-list source path"
    ],
    local_direct_list_path: [
      type: :string,
      default: "/etc/gsmlg/proxy-rules/direct-list.txt",
      doc: "Local direct-list source path"
    ],
    local_watch_debounce: [
      type: :pos_integer,
      default: 500,
      doc: "Local file watcher debounce in milliseconds"
    ],
    local_reconciliation_interval: [
      type: :pos_integer,
      default: 60_000,
      doc: "Local source reconciliation interval in milliseconds"
    ],
    state_directory: [
      type: :string,
      default: "/var/lib/gsmlg/proxy-rules",
      doc: "Last-known-good state directory"
    ],
    cache_control: [
      type: :string,
      default: "public, max-age=3600",
      doc: "Cache-Control value for generated artifacts"
    ],
    unsupported_rule_sample_limit: [
      type: :non_neg_integer,
      default: 20,
      doc: "Maximum unsupported-rule diagnostic samples"
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
      browser: @browser_schema,
      browser_agent: @browser_agent_schema,
      cluster: @cluster_schema,
      oauth: %{github: @github_oauth_schema},
      web_push: @web_push_schema,
      proxy_rules: @proxy_rules_schema,
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
              section
              |> validate_section_contract(Map.new(validated))

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
  defp get_section_schema(:browser), do: @browser_schema
  defp get_section_schema(:browser_agent), do: @browser_agent_schema
  defp get_section_schema(:cluster), do: @cluster_schema
  defp get_section_schema(:oauth), do: %{github: @github_oauth_schema}
  defp get_section_schema(:web_push), do: @web_push_schema
  defp get_section_schema(:proxy_rules), do: @proxy_rules_schema

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

  defp validate_section_contract(:commander, settings) do
    with {:ok, validated_tls} <-
           NimbleOptions.validate(Map.to_list(settings.tls), @commander_tls_schema),
         tls = Map.new(validated_tls),
         :ok <- validate_commander_tls(settings, tls),
         :ok <- validate_commander_agent(settings),
         :ok <- validate_commander_server(settings),
         :ok <- validate_commander_auth_windows(settings) do
      {:ok, %{settings | tls: tls}}
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_section_contract(:browser_agent, settings) do
    with {:ok, validated_security} <-
           NimbleOptions.validate(Map.to_list(settings.security), @browser_agent_security_schema),
         security = Map.new(validated_security),
         normalized = %{settings | security: security},
         :ok <- validate_browser_agent(normalized) do
      {:ok, normalized}
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_section_contract(:browser, settings) do
    with {:ok, validated_jobs} <-
           NimbleOptions.validate(Map.to_list(settings.jobs), @browser_jobs_schema),
         {:ok, validated_security} <-
           NimbleOptions.validate(Map.to_list(settings.security), @browser_security_schema),
         jobs = Map.new(validated_jobs),
         security = Map.new(validated_security),
         normalized = %{settings | jobs: jobs, security: security},
         :ok <- validate_browser(normalized) do
      {:ok, normalized}
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_section_contract(:proxy_rules, settings) do
    cond do
      settings.unsupported_rule_sample_limit > 1_000 ->
        {:error, "invalid unsupported_rule_sample_limit: expected an integer from 0 to 1000"}

      settings.retry_max_interval < settings.retry_min_interval ->
        {:error,
         "invalid retry interval range: retry_max_interval must be greater than or equal to retry_min_interval"}

      true ->
        {:ok, settings}
    end
  end

  defp validate_section_contract(_section, settings), do: {:ok, settings}

  defp validate_commander_tls(_settings, %{enabled: false}), do: :ok

  defp validate_commander_tls(settings, %{enabled: true} = tls) do
    missing =
      [:client_cert_file, :client_key_file]
      |> Enum.reject(fn key -> is_binary(tls[key]) and tls[key] != "" end)

    cond do
      missing != [] ->
        {:error, "Commander mTLS requires #{Enum.join(missing, " and ")}"}

      not secure_commander_url?(settings) ->
        {:error, "Commander mTLS platform_url must use wss://"}

      true ->
        :ok
    end
  end

  defp secure_commander_url?(%{platform_url: url}) when is_binary(url) and url != "" do
    String.starts_with?(url, "wss://")
  end

  defp secure_commander_url?(%{umbrella_server_url: url}) when is_binary(url) do
    String.starts_with?(url, "https://")
  end

  defp secure_commander_url?(_settings), do: false

  defp validate_commander_agent(%{start: false} = settings) do
    validate_optional_commander_url(settings)
  end

  defp validate_commander_agent(%{start: true} = settings) do
    required = [:name, :credential_id]

    case Enum.find(required, fn key -> not nonempty?(Map.get(settings, key)) end) do
      nil ->
        cond do
          Map.has_key?(settings, :platform_key) and
              not nonempty?(Map.get(settings, :platform_key)) ->
            {:error, "Commander agent requires nonempty platform_key"}

          nonempty?(Map.get(settings, :platform_key)) or
              nonempty?(Map.get(settings, :platform_key_env)) ->
            validate_required_commander_url(settings)

          true ->
            {:error, "Commander agent requires nonempty platform_key or platform_key_env"}
        end

      key ->
        {:error, "Commander agent requires nonempty #{key}"}
    end
  end

  defp validate_commander_server(%{server: true, platform_credentials: credentials})
       when map_size(credentials) > 0 do
    Enum.reduce_while(credentials, :ok, fn {credential_id, entry}, :ok ->
      case valid_credential_entry?(credential_id, entry) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, "Commander platform_credentials entries must be nonempty"}}
      end
    end)
  end

  defp validate_commander_server(%{server: true} = settings) do
    if nonempty?(Map.get(settings, :platform_credentials_env)),
      do: :ok,
      else:
        {:error,
         "Commander server requires nonempty platform_credentials or platform_credentials_env"}
  end

  defp validate_commander_server(settings) do
    credentials = Map.get(settings, :platform_credentials, %{})

    if Enum.all?(credentials, fn {credential_id, entry} ->
         valid_credential_entry?(credential_id, entry)
       end),
       do: :ok,
       else: {:error, "Commander platform_credentials entries must be nonempty"}
  end

  defp validate_commander_auth_windows(settings) do
    minimum = settings.auth_timestamp_window_seconds * 2_000

    if settings.auth_nonce_ttl_ms >= minimum,
      do: :ok,
      else: {:error, "Commander auth_nonce_ttl_ms must cover twice the timestamp window"}
  end

  defp validate_required_commander_url(settings) do
    cond do
      nonempty?(Map.get(settings, :platform_url)) ->
        validate_websocket_url(settings.platform_url)

      nonempty?(Map.get(settings, :umbrella_server_url)) ->
        validate_umbrella_url(settings.umbrella_server_url)

      true ->
        {:error, "Commander agent requires nonempty platform_url"}
    end
  end

  defp validate_optional_commander_url(settings) do
    cond do
      nonempty?(Map.get(settings, :platform_url)) ->
        validate_websocket_url(settings.platform_url)

      nonempty?(Map.get(settings, :umbrella_server_url)) ->
        validate_umbrella_url(settings.umbrella_server_url)

      true ->
        :ok
    end
  end

  defp validate_websocket_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        :ok

      _invalid ->
        {:error, "Commander platform_url must be a valid ws:// or wss:// URL"}
    end
  end

  defp validate_umbrella_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _invalid ->
        {:error, "Commander umbrella_server_url must be a valid http:// or https:// URL"}
    end
  end

  defp valid_credential_entry?(credential_id, entry) do
    id = if is_atom(credential_id), do: Atom.to_string(credential_id), else: credential_id

    key =
      if is_map(entry),
        do: Map.get(entry, :key, Map.get(entry, "key")),
        else: nil

    name =
      if is_map(entry),
        do: Map.get(entry, :commander_name, Map.get(entry, "commander_name")),
        else: nil

    nonempty?(id) and nonempty?(key) and nonempty?(name)
  end

  defp validate_browser_agent(%{enabled: false}), do: :ok

  defp validate_browser_agent(%{enabled: true} = settings) do
    cond do
      not browser_manager_loopback?(settings.manager_url) ->
        {:error, "Browser Agent manager_url must use an HTTP loopback address"}

      not nonempty?(settings.manager_token_env) ->
        {:error, "Browser Agent requires nonempty manager_token_env"}

      not nonempty?(settings.state_dir) ->
        {:error, "Browser Agent requires nonempty state_dir"}

      Path.type(settings.state_dir) != :absolute ->
        {:error, "Browser Agent state_dir must be an absolute path"}

      settings.inline_artifact_max_bytes > 131_072 ->
        {:error, "Browser Agent inline_artifact_max_bytes must not exceed 131072"}

      settings.max_observation_bytes > 1_048_576 ->
        {:error, "Browser Agent max_observation_bytes must not exceed 1048576"}

      settings.max_artifact_bytes > 104_857_600 ->
        {:error, "Browser Agent max_artifact_bytes must not exceed 104857600"}

      settings.inline_artifact_max_bytes > settings.max_artifact_bytes ->
        {:error, "Browser Agent inline_artifact_max_bytes must not exceed max_artifact_bytes"}

      not valid_allowed_origins?(settings.security.allowed_origins) ->
        {:error, "Browser Agent allowed_origins must contain unique canonical HTTPS origins"}

      not valid_allowed_origins?(settings.security.allowed_upload_origins) ->
        {:error,
         "Browser Agent allowed_upload_origins must contain unique canonical HTTPS origins"}

      true ->
        :ok
    end
  end

  defp validate_browser(settings) do
    cond do
      settings.inline_artifact_max_bytes > 131_072 ->
        {:error, "Browser inline_artifact_max_bytes must not exceed 131072"}

      settings.upload_ttl_seconds > 900 ->
        {:error, "Browser upload_ttl_seconds must not exceed 900"}

      settings.jobs.max_attempts > 10 ->
        {:error, "Browser max_attempts must not exceed 10"}

      settings.security.allowed_schemes != ["https"] ->
        {:error, "Browser allowed_schemes must be exactly https"}

      settings.security.max_observation_bytes > 1_048_576 ->
        {:error, "Browser max_observation_bytes must not exceed 1048576"}

      settings.security.max_artifact_bytes > 104_857_600 ->
        {:error, "Browser max_artifact_bytes must not exceed 104857600"}

      settings.inline_artifact_max_bytes > settings.security.max_artifact_bytes ->
        {:error, "Browser inline_artifact_max_bytes must not exceed max_artifact_bytes"}

      settings.enabled and not valid_upload_base_url?(settings.upload_base_url) ->
        {:error, "Browser upload_base_url must be a valid HTTPS URL without credentials or query"}

      true ->
        :ok
    end
  end

  defp valid_upload_base_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and host != "" and
             path in [nil, "", "/", "/browser-artifact-uploads"] ->
        true

      _invalid ->
        false
    end
  end

  defp valid_upload_base_url?(_url), do: false

  defp valid_allowed_origins?(origins) when is_list(origins) and origins != [] do
    Enum.uniq(origins) == origins and Enum.all?(origins, &canonical_https_origin?/1)
  end

  defp valid_allowed_origins?(_origins), do: false

  defp canonical_https_origin?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and path in [nil, ""] ->
        true

      _invalid ->
        false
    end
  end

  defp canonical_https_origin?(_origin), do: false

  defp browser_manager_loopback?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil}
      when host in ["127.0.0.1", "localhost", "::1"] ->
        true

      _invalid ->
        false
    end
  end

  defp browser_manager_loopback?(_url), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

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
