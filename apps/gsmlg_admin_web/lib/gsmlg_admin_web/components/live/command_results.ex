defmodule GSMLGAdminWeb.ComponentsLive.CommandResults do
  use GSMLGAdminWeb, :live_component

  def mount(socket) do
    case Process.whereis(:CommandResultsView) do
      nil -> nil
      _ -> Process.unregister(:CommandResultsView)
    end

    Process.register(self(), :CommandResultsView)

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket = socket |> fetch_command_results()

    {:ok, socket}
  end

  def handle_info(:update_command_results, socket) do
    socket = socket |> fetch_command_results()
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div>
      <.dm_table class="table table-zebra" data={@command_results}>
        <:col :let={t} label="Commander">
          <%= t.commander %>
        </:col>
        <:col :let={t} label="Command">
          <%= t.command %>
        </:col>
        <:col :let={t} label="Code">
          <%= t.code %>
        </:col>
        <:col :let={t} label="Output">
          <pre class="bg-black text-white overflow-auto">
            <%= t.output %>
            </pre>
        </:col>
      </.dm_table>
    </div>
    """
  end

  defp fetch_command_results(socket) do
    {:ok, command_results} = GSMLG.CommandPlatform.list_command_results()

    socket
    |> assign(:command_results, command_results)
  end
end
