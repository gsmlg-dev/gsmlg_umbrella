defmodule GSMLG.AdminWeb.PKILive.AnalyticsLive.Index do
  use GSMLG.AdminWeb, :user_live_view
  alias GSMLG.AdminWeb.PKIContext

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        analytics: nil,
        expiry_stats: nil,
        page_title: "PKI Analytics",
        active_menu: "pki_analytics"
      )
      |> load_analytics()
      |> load_expiry_stats()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_analytics() |> load_expiry_stats()}
  end

  defp load_analytics(socket) do
    case PKIContext.get_analytics() do
      {:ok, analytics} -> assign(socket, :analytics, analytics)
      _ -> assign(socket, :analytics, nil)
    end
  end

  defp load_expiry_stats(socket) do
    case PKIContext.get_expiry_stats() do
      {:ok, stats} -> assign(socket, :expiry_stats, stats)
      _ -> assign(socket, :expiry_stats, nil)
    end
  end
end
