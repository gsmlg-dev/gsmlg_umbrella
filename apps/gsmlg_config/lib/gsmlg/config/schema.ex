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

  @caddy_schema [
    start: [
      type: :boolean,
      default: false,
      doc: "Start the Caddy integration service"
    ],
    mode: [
      type: {:in, ["external", "embedded"]},
      default: "external",
      doc: "Caddy management mode: external (systemd/OS managed) or embedded (binary managed by this app)"
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
      oauth: %{github: @github_oauth_schema},
      web_push: @web_push_schema,
      caddy: @caddy_schema
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
        # Convert map to keyword list for NimbleOptions.validate
        config_list = if is_map(config), do: Map.to_list(config), else: config || []

        case NimbleOptions.validate(config_list, schema) do
          {:ok, validated} -> {:ok, Map.new(validated)}
          {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
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
  defp get_section_schema(:oauth), do: %{github: @github_oauth_schema}
  defp get_section_schema(:web_push), do: @web_push_schema
  defp get_section_schema(:caddy), do: @caddy_schema
  defp get_section_schema(_), do: nil

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
              # Convert map to keyword list for NimbleOptions.validate
              value_list = if is_map(value), do: Map.to_list(value), else: value || []

              case NimbleOptions.validate(value_list, nested_schema) do
                {:ok, validated} ->
                  {:ok, Map.new(validated)}

                {:error, %NimbleOptions.ValidationError{} = error} ->
                  {:error, Exception.message(error)}
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
end
