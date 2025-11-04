defmodule GSMLG.AdminWeb.PKILive.CertificateLive.Index do
  @moduledoc """
  LiveView for Certificate listing and management.
  """
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.AdminWeb.PKIContext

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        certificates: [],
        cas: [],
        filter: %{status: :all, ca_id: nil},
        active_menu: "pki_management",
        page_title: "Certificates"
      )
      |> load_cas()
      |> load_certificates()

    {:ok, socket, temporary_assigns: [certificates: []]}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filter = build_filter(params)

    socket
    |> assign(:page_title, "Certificates")
    |> assign(:filter, filter)
    |> load_certificates()
  end

  defp apply_action(socket, :issue, params) do
    ca_id = Map.get(params, "ca_id")

    socket
    |> assign(:page_title, "Issue Certificate")
    |> assign(:issue_form, %{
      "ca_id" => ca_id,
      "csr_pem" => "",
      "template" => "server",
      "validity" => "365"
    })
  end

  @impl true
  def handle_event("issue_certificate", params, socket) do
    user = socket.assigns.current_user

    opts = [
      template: String.to_existing_atom(params["template"]),
      validity: String.to_integer(params["validity"]),
      actor: user.email
    ]

    case PKIContext.issue_certificate(params["ca_id"], params["csr_pem"], opts) do
      {:ok, cert} ->
        {:noreply,
         socket
         |> put_flash(:info, "Certificate issued successfully")
         |> push_navigate(to: ~p"/pki/certificates/#{cert.serial}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to issue certificate: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> push_patch(
       to:
         ~p"/pki/certificates?status=#{params["status"]}&ca_id=#{params["ca_id"] || ""}"
     )}
  end

  defp build_filter(params) do
    %{
      status:
        case Map.get(params, "status", "all") do
          "all" -> :all
          status -> String.to_atom(status)
        end,
      ca_id: Map.get(params, "ca_id")
    }
  end

  defp load_certificates(socket) do
    filter = socket.assigns.filter

    case PKIContext.list_certificates(
           status: filter.status,
           ca_id: filter.ca_id,
           limit: 100
         ) do
      {:ok, certificates} ->
        assign(socket, :certificates, certificates)

      _ ->
        assign(socket, :certificates, [])
    end
  end

  defp load_cas(socket) do
    case PKIContext.list_cas() do
      {:ok, cas} ->
        assign(socket, :cas, cas)

      _ ->
        assign(socket, :cas, [])
    end
  end
end
