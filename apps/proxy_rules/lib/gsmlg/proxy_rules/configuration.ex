defmodule GSMLG.ProxyRules.Configuration do
  @max_remote_body_size 64 * 1024 * 1024
  @max_diagnostic_sample_limit 1_000

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
          unsupported_rule_sample_limit: 0..1_000
        }

  @spec max_remote_body_size() :: pos_integer()
  def max_remote_body_size, do: @max_remote_body_size

  @spec new(map()) ::
          {:ok, t()}
          | {:error,
             {:missing_setting, atom()}
             | {:invalid_setting,
                :remote_max_body_size
                | :unsupported_rule_sample_limit
                | :retry_interval_range}}
  def new(settings) when is_map(settings) do
    case Enum.find(@required, &(not Map.has_key?(settings, &1))) do
      nil -> build(settings)
      key -> {:error, {:missing_setting, key}}
    end
  end

  @spec load() ::
          {:ok, t()}
          | {:error,
             {:missing_setting, atom()}
             | {:invalid_setting,
                :remote_max_body_size
                | :unsupported_rule_sample_limit
                | :retry_interval_range}}
  def load do
    :proxy_rules
    |> Application.get_env(:settings, %{})
    |> new()
  end

  defp build(settings) do
    cond do
      not valid_remote_body_size?(settings.remote_max_body_size) ->
        {:error, {:invalid_setting, :remote_max_body_size}}

      not valid_sample_limit?(settings.unsupported_rule_sample_limit) ->
        {:error, {:invalid_setting, :unsupported_rule_sample_limit}}

      not valid_retry_range?(settings.retry_min_interval, settings.retry_max_interval) ->
        {:error, {:invalid_setting, :retry_interval_range}}

      true ->
        {:ok, struct!(__MODULE__, Map.take(settings, @required))}
    end
  end

  defp valid_remote_body_size?(size),
    do: is_integer(size) and size > 0 and size <= @max_remote_body_size

  defp valid_sample_limit?(limit),
    do: is_integer(limit) and limit >= 0 and limit <= @max_diagnostic_sample_limit

  defp valid_retry_range?(minimum, maximum),
    do: is_integer(minimum) and is_integer(maximum) and minimum > 0 and maximum >= minimum
end
