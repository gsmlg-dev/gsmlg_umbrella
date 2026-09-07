defmodule GSMLG.BrowserAgent.ManagerMonitor do
  @moduledoc "Polls the local browser Manager and retains only its redacted health snapshot."

  use GenServer

  alias GSMLG.BrowserAgent.Backends.CloakBrowser

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @impl true
  def init(opts) do
    state = %{
      backend: Keyword.get(opts, :backend, CloakBrowser),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      settings: Keyword.fetch!(opts, :settings),
      interval_ms: Keyword.fetch!(opts, :interval_ms),
      snapshot: %{"status" => "unknown"},
      timer: nil
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    {:noreply, poll(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:refresh, _from, state) do
    state = poll(state)
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(%{state | timer: nil})}

  defp poll(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    snapshot =
      case state.backend.manager_status(state.settings, state.backend_opts) do
        {:ok, safe_status} when is_map(safe_status) ->
          safe_status
          |> Map.put("backend", state.settings.backend)
          |> Map.put("agent_version", application_version())

        {:error, %{code: code}} when is_binary(code) ->
          %{
            "status" => "degraded",
            "backend" => state.settings.backend,
            "agent_version" => application_version(),
            "error_code" => code
          }

        _invalid ->
          %{
            "status" => "degraded",
            "backend" => state.settings.backend,
            "agent_version" => application_version(),
            "error_code" => "manager_invalid_response"
          }
      end

    timer = Process.send_after(self(), :poll, state.interval_ms)
    %{state | snapshot: snapshot, timer: timer}
  end

  defp application_version do
    case Application.spec(:gsmlg_browser_agent, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
