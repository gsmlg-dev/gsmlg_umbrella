defmodule GSMLG.SessionProcess.StorageBrowserTest do
  use ExUnit.Case, async: false

  alias GSMLG.SessionProcess.StorageBrowser
  alias Phoenix.SessionProcess
  alias Phoenix.SessionProcess.Action

  defmodule Inventory do
    def current_backend_id, do: config().id

    def backend do
      case config() do
        %{error: error} -> {:error, error}
        %{id: id} -> {:ok, %{id: id, bucket: "bucket-#{id}", client: :private_client}}
      end
    end

    def load(backend) do
      send(config().owner, {:inventory_load, self(), backend.id})

      receive do
        {:complete, result} -> result
        :raise -> raise "private client failure"
      end
    end

    defp config, do: Application.fetch_env!(:gsmlg, :storage_browser_test_inventory)
  end

  setup do
    previous = Application.fetch_env(:gsmlg, :storage_browser_test_inventory)
    configure(:first)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gsmlg, :storage_browser_test_inventory, value)
        :error -> Application.delete_env(:gsmlg, :storage_browser_test_inventory)
      end
    end)

    %{session: session()}
  end

  test "refresh is asynchronous, publishes loading, and shares one snapshot between tabs", %{
    session: session
  } do
    assert {:ok, _ref} = StorageBrowser.subscribe(session, Inventory)
    assert_receive {:storage_snapshot, %{loading: false, objects: []}}
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert %{loading: true, request_token: token} = StorageBrowser.snapshot(session, Inventory)
    assert is_reference(token)
    assert_receive {:storage_snapshot, %{loading: true}}
    assert_receive {:inventory_load, task, :first}

    parent = self()

    spawn(fn ->
      {:ok, _ref} = StorageBrowser.subscribe(session, Inventory)
      send(parent, :second_tab_subscribed)

      receive do
        {:storage_snapshot, %{loading: false, objects: [_]} = snapshot} ->
          send(parent, {:second_tab_snapshot, snapshot})
      end
    end)

    assert_receive :second_tab_subscribed
    expected = result(:first, "fresh.txt")
    send(task, {:complete, expected})

    assert_receive {:storage_snapshot,
                    %{loading: false, objects: [%{key: "fresh.txt"}]} = snapshot}

    assert_receive {:second_tab_snapshot, ^snapshot}
    assert StorageBrowser.snapshot(session, Inventory) == snapshot
    refute Map.has_key?(snapshot, :client)
    refute Map.has_key?(snapshot, :inventory)
  end

  test "different sessions do not share inventory", %{session: first} do
    second = session()
    assert :ok = StorageBrowser.refresh(first, Inventory)
    assert_receive {:inventory_load, task, :first}
    {:ok, _} = StorageBrowser.subscribe(first, Inventory)
    send(task, {:complete, result(:first, "private.txt")})
    assert_receive {:storage_snapshot, %{objects: [%{key: "private.txt"}], loading: false}}
    assert %{objects: [], loading: false} = StorageBrowser.snapshot(second, Inventory)
    refute_receive {:inventory_load, _, _}
  end

  test "superseded results cannot overwrite a newer request", %{session: session} do
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:inventory_load, first_task, :first}
    %{request_token: first_token} = StorageBrowser.snapshot(session, Inventory)
    monitor = Process.monitor(first_task)
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:DOWN, ^monitor, :process, ^first_task, _reason}
    assert_receive {:inventory_load, second_task, :first}
    %{request_token: second_token} = StorageBrowser.snapshot(session, Inventory)

    assert {:ok, _state} =
             SessionProcess.call(
               session,
               {:dispatch_action,
                Action.new(
                  "refresh_finished",
                  %{
                    token: first_token,
                    backend_id: :first,
                    inventory: Inventory,
                    result: result(:first, "stale.txt")
                  },
                  %{reducers: [:storage]}
                )}
             )

    assert %{objects: [], loading: true, request_token: ^second_token} =
             StorageBrowser.snapshot(session, Inventory)

    {:ok, _} = StorageBrowser.subscribe(session, Inventory)
    send(second_task, {:complete, result(:first, "current.txt")})
    assert_receive {:storage_snapshot, %{objects: [%{key: "current.txt"}], loading: false}}
  end

  test "configuration changes discard pending results and cached objects", %{session: session} do
    {:ok, _} = StorageBrowser.subscribe(session, Inventory)
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:inventory_load, task, :first}
    configure(:second)
    send(task, {:complete, result(:first, "old-bucket.txt")})

    assert_receive {:storage_snapshot,
                    %{backend_id: :second, loading: false, error: :backend_changed}}

    assert %{backend_id: :second, objects: [], bucket: nil} =
             StorageBrowser.snapshot(session, Inventory)

    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:inventory_load, second_task, :second}
    send(second_task, {:complete, result(:second, "new-bucket.txt")})
    assert_receive {:storage_snapshot, %{objects: [%{key: "new-bucket.txt"}], loading: false}}
    configure(:invalid, error: :missing_bucket)

    assert %{backend_id: :invalid, objects: [], loading: false} =
             StorageBrowser.snapshot(session, Inventory)

    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:storage_snapshot, %{error: :missing_bucket, loading: false}}
  end

  test "failed refresh retains only the same backend's last snapshot and survives task exceptions",
       %{
         session: session
       } do
    {:ok, _} = StorageBrowser.subscribe(session, Inventory)
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:inventory_load, task, :first}
    send(task, {:complete, result(:first, "last-good.txt")})
    assert_receive {:storage_snapshot, %{objects: [%{key: "last-good.txt"}], loading: false}}
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:inventory_load, next_task, :first}
    send(next_task, :raise)

    assert_receive {:storage_snapshot,
                    %{
                      objects: [%{key: "last-good.txt"}],
                      loading: false,
                      error: :storage_refresh_failed
                    }}

    assert SessionProcess.started?(session)
  end

  test "session termination cancels its outstanding supervised load", %{session: session} do
    assert :ok = StorageBrowser.refresh(session, Inventory)
    assert_receive {:inventory_load, task, :first}
    monitor = Process.monitor(task)
    assert :ok = SessionProcess.terminate(session)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}
    refute SessionProcess.started?(session)
  end

  test "disconnected tabs release their subscribed snapshot", %{session: session} do
    parent = self()

    tab =
      spawn(fn ->
        {:ok, _ref} = StorageBrowser.subscribe(session, Inventory)
        send(parent, :subscribed)
        receive do: (:disconnect -> :ok)
      end)

    assert_receive :subscribed
    {:ok, session_pid} = SessionProcess.find_session(session)
    [subscription] = :sys.get_state(session_pid)._redux_subscriptions
    assert subscription.pid == tab
    monitor = Process.monitor(tab)
    send(tab, :disconnect)
    assert_receive {:DOWN, ^monitor, :process, ^tab, :normal}

    # Deliver a barrier behind the exact monitor event; no timing-based polling.
    send(session_pid, {:DOWN, subscription.monitor_ref, :process, tab, :normal})
    assert %{loading: false} = StorageBrowser.snapshot(session, Inventory)
    assert :sys.get_state(session_pid)._redux_subscriptions == []
  end

  defp session do
    id = Phoenix.SessionProcess.SessionId.generate_unique_session_id()
    {:ok, _pid} = SessionProcess.start_session(id, module: GSMLG.SessionProcess)
    on_exit(fn -> SessionProcess.terminate(id) end)
    id
  end

  defp configure(id, opts \\ []) do
    Application.put_env(
      :gsmlg,
      :storage_browser_test_inventory,
      Map.merge(%{id: id, owner: self()}, Map.new(opts))
    )
  end

  defp result(id, key) do
    {:ok,
     %{
       backend_id: id,
       bucket: "bucket-#{id}",
       objects: [%{key: key, size: 10, folder?: false}],
       refreshed_at: DateTime.utc_now()
     }}
  end
end
