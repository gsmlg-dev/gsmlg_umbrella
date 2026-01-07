defmodule GSMLG.AdminWeb.PKILive.CertificateLive.Show do
  @moduledoc """
  LiveView for displaying certificate details.
  """

  # Suppress undefined module warnings for PKI modules not yet implemented
  @compile {:no_warn_undefined, [GSMLG.PKI.Certificate]}

  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.AdminWeb.PKIContext
  alias GSMLG.PKI.Certificate

  @impl true
  def mount(%{"serial" => serial}, _session, socket) do
    serial_int = String.to_integer(serial)

    socket =
      socket
      |> assign(
        serial: serial_int,
        certificate: nil,
        certificate_pem: nil,
        active_menu: "pki_certificates"
      )
      |> load_certificate()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, "Certificate Details")
  end

  defp apply_action(socket, :revoke, _params) do
    socket
    |> assign(:page_title, "Revoke Certificate")
    |> assign(:revoke_form, %{
      "reason" => "unspecified",
      "notes" => ""
    })
  end

  @impl true
  def handle_event("revoke", params, socket) do
    user = socket.assigns.current_user
    cert = socket.assigns.certificate

    opts = [
      reason: String.to_existing_atom(params["reason"]),
      actor: user.email
    ]

    case PKIContext.revoke_certificate(cert.issuer_ca_id, socket.assigns.serial, opts) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Certificate revoked successfully")
         |> load_certificate()
         |> push_patch(to: ~p"/pki/certificates/#{socket.assigns.serial}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to revoke certificate: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("download", %{"format" => format}, socket) do
    cert = socket.assigns.certificate

    {filename, content, mime_type} =
      case format do
        "pem" ->
          {"certificate_#{cert.serial}.pem", socket.assigns.certificate_pem,
           "application/x-pem-file"}

        "der" ->
          {"certificate_#{cert.serial}.der", cert.certificate_der, "application/x-x509-ca-cert"}
      end

    {:noreply,
     socket
     |> push_event("download", %{
       filename: filename,
       content: Base.encode64(content),
       mime_type: mime_type
     })}
  end

  defp load_certificate(socket) do
    case PKIContext.get_certificate(socket.assigns.serial) do
      {:ok, cert} ->
        # Convert DER to PEM for display
        {:ok, cert_struct} = Certificate.from_der(cert.certificate_der)
        pem = Certificate.to_pem(cert_struct)

        socket
        |> assign(:certificate, cert)
        |> assign(:certificate_pem, pem)

      {:error, _} ->
        socket
        |> put_flash(:error, "Certificate not found")
        |> push_navigate(to: ~p"/pki/certificates")
    end
  end
end
