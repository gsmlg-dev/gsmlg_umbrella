defmodule GSMLG.AdminWeb.CommanderSocket do
  use Phoenix.Socket

  require Logger

  channel("command_platform", GSMLG.AdminWeb.CommandPlatformChannel)
  channel("commander:*", GSMLG.AdminWeb.CommanderChannel)

  @impl true
  def connect(
        %{"name" => name, "sign_at" => sign_at, "signature" => signature} = _params,
        socket,
        connect_info
      ) do
    priv_key =
      Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
      |> Keyword.get(:platform_key)

    if :crypto.mac(:hmac, :sha256, priv_key, "#{name}/#{sign_at}")
       |> Base.encode16()
       |> Kernel.==(signature) do
      Logger.info("socket connected: " <> inspect(connect_info))

      socket =
        socket
        |> assign(:peer_data, Map.get(connect_info, :peer_data))
        |> assign(:name, name)
        |> assign(:sign_at, sign_at)

      Logger.debug("socket info: " <> inspect(socket))

      on_connect(self(), socket.assigns)

      {:ok, socket}
    else
      Logger.error(
        "socket signature error: (name: #{name}, sign_at: #{sign_at}, signature: #{signature}) " <>
          inspect(connect_info)
      )

      {:error, :invalid_signature}
    end
  end

  @impl true
  def id(socket), do: "commander:#{socket.assigns.name}"

  def on_connect(pid, commander_info) do
    monitor(pid, commander_info)

    GSMLG.CommandPlatform.commander_joined(commander_info)

    Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)
  end

  def on_disconnect(commander_info) do
    GSMLG.CommandPlatform.commander_leave(commander_info)

    Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)
  end

  defp monitor(pid, commander_info) do
    Task.Supervisor.start_child(GSMLG.TaskSupervisor, fn ->
      Process.flag(:trap_exit, true)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} ->
          on_disconnect(commander_info)
      end
    end)
  end
end
