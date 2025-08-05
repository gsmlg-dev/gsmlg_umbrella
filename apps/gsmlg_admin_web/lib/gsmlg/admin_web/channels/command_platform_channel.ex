defmodule GSMLG.AdminWeb.CommandPlatformChannel do
  @moduledoc """
  Command Platform Channel

  commander socket struct:

  ```
  %Phoenix.Socket{
    assigns: %{
      commander_name: "gsmlg_commander",
      peer_data: %{
        address: {127, 0, 0, 1},
        port: 46006,
        ssl_cert: nil
      },
      sign_at: "1682474846"
    },
    channel: GSMLG.AdminWeb.CommandPlatformChannel,
    channel_pid: #PID<0.2542.0>,
    endpoint: GSMLG.AdminWeb.Endpoint,
    handler: GSMLG.AdminWeb.UserSocket,
    id: "user_socket:$__nobody__",
    joined: true,
    join_ref: "1",
    private: %{
      connect_info: %{
        peer_data: %{
          address: {127, 0, 0, 1},
          port: 46006,
          ssl_cert: nil
      },
      session: nil,
      trace_context_headers: [],
      uri: %URI{
        scheme: "http",
        authority: "localhost",
        userinfo: nil,
        host: "localhost",
        port: 80,
        path: "/socket/websocket",
        query: "name=gsmlg_commander&sign_at=1682474846&signature=EBF34D45AFB054A16757C78318B2685379A9C325CD3FDC8517ECB73D8DA7B7E9&vsn=2.0.0",
        fragment: nil
      }, x_headers: []
    },
    log_handle_in: :debug, log_join: :info},
    pubsub_server: GSMLG.PubSub, ref: nil,
    serializer: Phoenix.Socket.V2.JSONSerializer,
    topic: "command_platform:commanders",
    transport: :websocket,
    transport_pid: #PID<0.2284.0>
  }
  ```

  """
  require Logger
  use Phoenix.Channel
  alias Phoenix.Socket.Broadcast
  alias GSMLG.CommandPlatform

  @impl true
  def join("command_platform", _msg, socket) do
    {:ok, socket}
  end

  def join("command_platform:commanders", msg, socket) do
    Logger.debug("Commander joined in msg: #{inspect(msg)}")
    Logger.debug("Commander joined in socket: #{inspect(socket)}")
    send(self(), {:commander_joined, msg})
    {:ok, socket}
  end

  @impl true
  def terminate(reason, socket) do
    Logger.info("#{inspect(socket)} > leave #{inspect(reason)}")

    case socket do
      %Phoenix.Socket{assigns: %{commander_name: commander_name}} = socket ->
        commander = %{
          name: commander_name,
          socket: socket
        }

        CommandPlatform.commander_leave(commander, reason)

        case reason do
          {:shutdown, :closed} ->
            broadcast_from(socket, "commander_leave", %{"reason" => "shutdown, closed"})

          _ ->
            broadcast_from(socket, "commander_leave", reason)
        end

      _ ->
        nil
    end

    :ok
  end

  @impl true
  def handle_info({:commander_joined, msg}, socket) do
    case socket do
      %Phoenix.Socket{assigns: %{commander_name: commander_name}} = socket ->
        commander = %{
          name: commander_name,
          socket: socket,
          join_msg: msg
        }

        CommandPlatform.commander_joined(commander, msg)
        broadcast_from(socket, "commander_joined", msg)

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_info(%Broadcast{topic: _, event: event, payload: payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", %{"message" => "pong", "time" => time}, socket) do
    Logger.debug("Get ping pong at #{time}")
    # {:noreply, socket}
    {:reply, {:ok, %{"message" => "Good Job"}}, socket}
  end

  def handle_in(
        "command:result",
        %{"output" => output, "code" => code, "commander" => commander, "command" => command},
        socket
      ) do
    Logger.info("Run command `#{command}` on `#{commander}`, code: #{code} output:\n#{output}")

    GSMLG.CommandPlatform.add_run_result(%{
      :output => output,
      :code => code,
      :commander => commander,
      :command => command
    })

    case Process.whereis(:CommandResultsView) do
      nil ->
        nil

      pid ->
        Process.send_after(pid, :update_command_results, 500)
    end

    {:noreply, socket}
  end

  def handle_in("job:start", _payload, socket) do
    {:noreply, socket}
  end

  def handle_in("job:stream", _payload, socket) do
    {:noreply, socket}
  end

  def handle_in("job:end", _payload, socket) do
    {:noreply, socket}
  end

  def handle_in(any, payload, socket) do
    Logger.warning("Unmatched topic: #{any} with #{inspect(payload)}")
    {:noreply, socket}
  end
end
