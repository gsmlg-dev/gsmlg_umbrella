defmodule GSMLG.AdminWeb.CommanderSocket do
  use Phoenix.Socket

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
      GSMLG.Telemetry.info("Commander socket connected",
        metadata: %{
          socket_type: "commander",
          commander_name: name,
          sign_at: sign_at,
          peer_data: Map.get(connect_info, :peer_data),
          user_agent: get_connect_info_header(connect_info, "user-agent"),
          x_forwarded_for: get_connect_info_header(connect_info, "x-forwarded-for")
        }
      )

      socket =
        socket
        |> assign(:peer_data, Map.get(connect_info, :peer_data))
        |> assign(:name, name)
        |> assign(:sign_at, sign_at)

      GSMLG.Telemetry.debug("Commander socket info",
        metadata: %{
          socket_type: "commander",
          commander_name: name,
          socket_assigns: socket.assigns
        }
      )

      on_connect(self(), socket.assigns)

      {:ok, socket}
    else
      GSMLG.Telemetry.error("Commander socket signature verification failed",
        metadata: %{
          socket_type: "commander",
          commander_name: name,
          sign_at: sign_at,
          signature: signature,
          peer_data: Map.get(connect_info, :peer_data),
          user_agent: get_connect_info_header(connect_info, "user-agent"),
          security_event: "signature_verification_failed"
        }
      )

      {:error, :invalid_signature}
    end
  end

  @impl true
  def id(socket), do: "commander:#{socket.assigns.name}"

  def on_connect(pid, commander_info) do
    GSMLG.Telemetry.info("Commander connected to platform",
      metadata: %{
        event: "commander_connected",
        commander_name: commander_info[:name],
        sign_at: commander_info[:sign_at],
        peer_data: commander_info[:peer_data]
      }
    )

    monitor(pid, commander_info)

    GSMLG.CommandPlatform.commander_joined(commander_info)

    Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)
  end

  def on_disconnect(commander_info) do
    GSMLG.Telemetry.info("Commander disconnected from platform",
      metadata: %{
        event: "commander_disconnected",
        commander_name: commander_info[:name],
        sign_at: commander_info[:sign_at]
      }
    )

    GSMLG.CommandPlatform.commander_leave(commander_info)

    Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)
  end

  defp monitor(pid, commander_info) do
    Task.Supervisor.start_child(GSMLG.TaskSupervisor, fn ->
      Process.flag(:trap_exit, true)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, reason} ->
          GSMLG.Telemetry.debug("Commander process down detected",
            metadata: %{
              event: "commander_process_down",
              commander_name: commander_info[:name],
              reason: reason
            }
          )

          on_disconnect(commander_info)
      end
    end)
  end

  defp get_connect_info_header(connect_info, header) do
    case get_in(connect_info, [:req_headers]) do
      headers when is_list(headers) ->
        headers
        |> Enum.find(fn {key, _} -> String.downcase(key) == String.downcase(header) end)
        |> case do
          {_, value} -> value
          nil -> nil
        end

      _ ->
        nil
    end
  end
end
