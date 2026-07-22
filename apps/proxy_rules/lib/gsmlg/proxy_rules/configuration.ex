defmodule GSMLG.ProxyRules.Configuration do
  @max_remote_body_size 64 * 1024 * 1024

  @required [
    :source_url,
    :remote_refresh_interval,
    :remote_connect_timeout,
    :remote_receive_timeout,
    :remote_max_body_size,
    :retry_min_interval,
    :retry_max_interval,
    :retry_jitter,
    :local_proxy_list_path,
    :local_direct_list_path,
    :local_watch_debounce,
    :local_reconciliation_interval,
    :state_directory,
    :cache_control,
    :unsupported_rule_sample_limit
  ]

  @enforce_keys @required
  defstruct @required

  @type t :: %__MODULE__{
          source_url: String.t(),
          remote_refresh_interval: pos_integer(),
          remote_connect_timeout: pos_integer(),
          remote_receive_timeout: pos_integer(),
          remote_max_body_size: 1..67_108_864,
          retry_min_interval: pos_integer(),
          retry_max_interval: pos_integer(),
          retry_jitter: boolean(),
          local_proxy_list_path: String.t(),
          local_direct_list_path: String.t(),
          local_watch_debounce: pos_integer(),
          local_reconciliation_interval: pos_integer(),
          state_directory: String.t(),
          cache_control: String.t(),
          unsupported_rule_sample_limit: non_neg_integer()
        }

  @spec max_remote_body_size() :: pos_integer()
  def max_remote_body_size, do: @max_remote_body_size

  @spec new(map()) ::
          {:ok, t()}
          | {:error, {:missing_setting, atom()} | {:invalid_setting, :remote_max_body_size}}
  def new(settings) when is_map(settings) do
    case Enum.find(@required, &(not Map.has_key?(settings, &1))) do
      nil -> build(settings)
      key -> {:error, {:missing_setting, key}}
    end
  end

  @spec load() ::
          {:ok, t()}
          | {:error, {:missing_setting, atom()} | {:invalid_setting, :remote_max_body_size}}
  def load do
    :proxy_rules
    |> Application.get_env(:settings, %{})
    |> new()
  end

  defp build(%{remote_max_body_size: size} = settings)
       when is_integer(size) and size > 0 and size <= @max_remote_body_size,
       do: {:ok, struct!(__MODULE__, Map.take(settings, @required))}

  defp build(_settings), do: {:error, {:invalid_setting, :remote_max_body_size}}
end
