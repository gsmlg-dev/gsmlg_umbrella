defmodule GSMLG.ProxyRules.Supervisor do
  use Supervisor

  alias GSMLG.ProxyRules.{Configuration, Coordinator, Store}
  alias GSMLG.ProxyRules.Source.{Local, Remote}

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    config = load_configuration!(options)

    initial_fetch =
      Keyword.get(
        options,
        :initial_fetch,
        Application.get_env(:proxy_rules, :initial_fetch, true)
      )

    children = [
      {Task.Supervisor, name: GSMLG.ProxyRules.TaskSupervisor},
      %{
        id: Finch,
        start:
          {Finch, :start_link,
           [
             [
               name: GSMLG.ProxyRules.Finch,
               pools: %{
                 default: [
                   conn_opts: [transport_opts: [timeout: config.remote_connect_timeout]]
                 ]
               }
             ]
           ]},
        type: :supervisor
      },
      {Store, state_directory: config.state_directory},
      {Remote,
       name: Remote,
       config: config,
       notify: Coordinator,
       task_supervisor: GSMLG.ProxyRules.TaskSupervisor,
       transport_options: [finch_name: GSMLG.ProxyRules.Finch],
       initial_fetch: initial_fetch},
      {Local, name: Local, config: config, notify: Coordinator},
      {Coordinator,
       name: Coordinator,
       configuration: config,
       store: {Store, Store},
       remote: {Remote, Remote},
       local: {Local, Local},
       task_supervisor: GSMLG.ProxyRules.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp load_configuration!(options) do
    case Keyword.fetch(options, :configuration) do
      {:ok, %Configuration{} = config} ->
        config

      {:ok, invalid} ->
        raise ArgumentError, "invalid proxy-rules configuration: #{inspect(invalid)}"

      :error ->
        case Configuration.load() do
          {:ok, config} ->
            config

          {:error, reason} ->
            raise ArgumentError, "invalid proxy-rules configuration: #{inspect(reason)}"
        end
    end
  end
end
