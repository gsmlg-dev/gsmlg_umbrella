defmodule GSMLG.SessionProcess.StorageReducer do
  @moduledoc "Owns the temporary S3 inventory for one authenticated session."
  use Phoenix.SessionProcess, :reducer

  alias Phoenix.SessionProcess.Action

  @name :storage

  @impl true
  def init_state do
    %{
      backend_id: nil,
      bucket: nil,
      objects: [],
      refreshed_at: nil,
      loading: false,
      error: nil,
      request_token: nil
    }
  end

  @impl true
  def handle_action(%Action{type: "refresh_started", payload: payload}, state) do
    cancel_previous(state)
    state = if state.backend_id == payload.backend_id, do: state, else: init_state()

    %{
      state
      | backend_id: payload.backend_id,
        request_token: payload.token,
        loading: true,
        error: nil
    }
  end

  def handle_action(%Action{type: "invalidate", payload: %{backend_id: id}}, state) do
    cancel_previous(state)
    %{init_state() | backend_id: id}
  end

  def handle_action(%Action{type: "refresh_finished", payload: payload}, state) do
    finished(payload.token)
    current_id = payload.inventory.current_backend_id()

    cond do
      state.request_token != payload.token ->
        state

      payload.backend_id != state.backend_id or payload.backend_id != current_id ->
        %{init_state() | backend_id: current_id, error: :backend_changed}

      true ->
        apply_result(payload.result, payload.backend_id, state)
    end
  end

  @impl true
  def handle_async(%Action{type: "load", payload: payload}, dispatch, state) do
    if state.request_token == payload.token do
      case Task.Supervisor.start_child(GSMLG.TaskSupervisor, fn ->
             result = load(payload.inventory, payload.backend_id)

             dispatch.("refresh_finished", Map.put(payload, :result, result),
               reducers: [:storage]
             )
           end) do
        {:ok, pid} ->
          fn -> cancel_task(pid) end

        {:error, _reason} ->
          dispatch.("refresh_finished", Map.put(payload, :result, {:error, :task_unavailable}),
            reducers: [:storage]
          )

          fn -> :ok end
      end
    else
      finished(payload.token)
      fn -> :ok end
    end
  end

  defp apply_result({:ok, %{backend_id: id} = snapshot}, id, state) do
    state
    |> Map.merge(Map.take(snapshot, [:backend_id, :bucket, :objects, :refreshed_at]))
    |> Map.merge(%{loading: false, error: nil, request_token: nil})
  end

  defp apply_result({:ok, _snapshot}, id, _state),
    do: %{init_state() | backend_id: id, error: :backend_changed}

  defp apply_result({:error, reason}, _id, state),
    do: %{state | loading: false, error: reason, request_token: nil}

  defp load(inventory, id) do
    case inventory.backend() do
      {:ok, %{id: ^id} = backend} -> inventory.load(backend)
      {:ok, _backend} -> {:error, :backend_changed}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :storage_refresh_failed}
  catch
    _kind, _reason -> {:error, :storage_refresh_failed}
  end

  defp cancel_task(pid) do
    Task.Supervisor.terminate_child(GSMLG.TaskSupervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  defp cancel_previous(%{request_token: nil}), do: :ok

  defp cancel_previous(%{request_token: token}) do
    GenServer.cast(self(), {:cancel_action, {:storage, token}})
    finished(token)
  end

  defp finished(token), do: GenServer.cast(self(), {:storage_load_finished, token})
end
