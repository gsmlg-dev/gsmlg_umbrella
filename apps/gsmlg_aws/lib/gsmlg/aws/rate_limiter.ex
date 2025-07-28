defmodule GSMLG.AWS.RateLimiter do
  @moduledoc """
  Rate limiting for AWS API calls to prevent hitting service limits.
  """

  use GenServer
  require Logger

  # requests per second
  @default_limit 10
  # milliseconds
  @default_window 1000

  ## Client API

  def start_link(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    window = Keyword.get(opts, :window, @default_window)
    GenServer.start_link(__MODULE__, {limit, window}, name: __MODULE__)
  end

  @doc """
  Checks if a request can be made for the given key (service name).
  Returns :ok if request is allowed, {:error, :rate_limited} if not.
  """
  def check_rate(service_name) do
    GenServer.call(__MODULE__, {:check_rate, service_name})
  end

  @doc """
  Executes the given function with rate limiting for the specified service.
  """
  def with_rate_limit(service_name, fun) do
    case check_rate(service_name) do
      :ok -> fun.()
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  ## Server Callbacks

  def init({limit, window}) do
    {:ok, %{limits: %{}, limit: limit, window: window}}
  end

  def handle_call({:check_rate, service_name}, _from, state) do
    now = System.monotonic_time(:millisecond)
    service_limits = Map.get(state.limits, service_name, [])

    # Remove old entries outside the window
    cutoff = now - state.window

    recent_requests =
      Enum.filter(service_limits, fn timestamp ->
        timestamp > cutoff
      end)

    if length(recent_requests) < state.limit do
      # Allow the request
      new_limits = Map.put(state.limits, service_name, [now | recent_requests])
      {:reply, :ok, %{state | limits: new_limits}}
    else
      # Rate limit exceeded
      {:reply, {:error, :rate_limited}, state}
    end
  end

  ## Rate limiting wrappers for AWS services

  defmodule Route53 do
    @service_name "route53"

    def with_rate_limit(fun) do
      GSMLG.AWS.RateLimiter.with_rate_limit(@service_name, fun)
    end
  end

  defmodule S3 do
    @service_name "s3"

    def with_rate_limit(fun) do
      GSMLG.AWS.RateLimiter.with_rate_limit(@service_name, fun)
    end
  end
end
