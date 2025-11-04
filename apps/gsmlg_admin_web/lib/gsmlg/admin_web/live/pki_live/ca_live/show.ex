defmodule GSMLG.AdminWeb.PKILive.CALive.Show do
  @moduledoc """
  LiveView for displaying Certificate Authority details.
  """
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.AdminWeb.PKIContext

  @impl true
  def mount(%{"ca_id" => ca_id}, _session, socket) do
    socket =
      socket
      |> assign(ca_id: ca_id, ca: nil, certificates: [], stats: nil)
      |> load_ca_details()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, "CA Details")
  end

  defp apply_action(socket, :stats, _params) do
    socket
    |> assign(:page_title, "CA Statistics")
    |> load_expiring_certificates()
  end

  @impl true
  def handle_event("generate_crl", _params, socket) do
    user = socket.assigns.current_user

    case PKIContext.generate_crl(socket.assigns.ca_id, actor: user.email) do
      {:ok, _crl} ->
        {:noreply,
         socket
         |> put_flash(:info, "CRL generated successfully")
         |> push_navigate(to: ~p"/pki/crl/#{socket.assigns.ca_id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to generate CRL: #{inspect(reason)}")}
    end
  end

  defp load_ca_details(socket) do
    ca_id = socket.assigns.ca_id

    with {:ok, ca} <- PKIContext.get_ca(ca_id),
         {:ok, stats} <- PKIContext.get_ca_stats(ca_id),
         {:ok, certificates} <-
           PKIContext.list_certificates(ca_id: ca_id, limit: 10) do
      socket
      |> assign(ca: ca, stats: stats, certificates: certificates)
    else
      {:error, :not_found} ->
        socket
        |> put_flash(:error, "CA not found")
        |> push_navigate(to: ~p"/pki/ca")

      _ ->
        socket
        |> assign(ca: nil, stats: nil, certificates: [])
    end
  end

  defp load_expiring_certificates(socket) do
    case PKIContext.get_expiring_certificates(socket.assigns.ca_id, 90) do
      {:ok, expiring} ->
        assign(socket, :expiring_certificates, expiring)

      _ ->
        assign(socket, :expiring_certificates, [])
    end
  end
end
