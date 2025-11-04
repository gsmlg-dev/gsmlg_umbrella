defmodule GSMLG.AdminWeb.PKILive.CRLLive.Index do
  use GSMLG.AdminWeb, :user_live_view
  alias GSMLG.AdminWeb.PKIContext
  alias GSMLG.PKI.CRL

  @impl true
  def mount(%{"ca_id" => ca_id}, _session, socket) do
    socket =
      socket
      |> assign(ca_id: ca_id, ca: nil, crl: nil, crl_pem: nil, page_title: "CRL Management")
      |> load_ca()
      |> load_crl()

    {:ok, socket}
  end

  @impl true
  def handle_event("generate_crl", _params, socket) do
    user = socket.assigns.current_user

    case PKIContext.generate_crl(socket.assigns.ca_id, actor: user.email) do
      {:ok, _crl} ->
        {:noreply, socket |> put_flash(:info, "CRL generated successfully") |> load_crl()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Failed to generate CRL: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("download_crl", %{"format" => format}, socket) do
    crl_der = :public_key.der_encode(:CertificateList, socket.assigns.crl)

    {filename, content, mime_type} =
      case format do
        "pem" ->
          pem = :public_key.pem_encode([{:CertificateList, crl_der, :not_encrypted}])
          {"crl_#{socket.assigns.ca_id}.pem", pem, "application/x-pem-file"}

        "der" ->
          {"crl_#{socket.assigns.ca_id}.crl", crl_der, "application/pkix-crl"}
      end

    {:noreply,
     socket
     |> push_event("download", %{
       filename: filename,
       content: Base.encode64(content),
       mime_type: mime_type
     })}
  end

  defp load_ca(socket) do
    case PKIContext.get_ca(socket.assigns.ca_id) do
      {:ok, ca} -> assign(socket, :ca, ca)
      _ -> assign(socket, :ca, nil)
    end
  end

  defp load_crl(socket) do
    case PKIContext.get_latest_crl(socket.assigns.ca_id) do
      {:ok, crl} ->
        pem = :public_key.pem_encode([{:CertificateList, :public_key.der_encode(:CertificateList, crl), :not_encrypted}])
        assign(socket, crl: crl, crl_pem: pem)

      _ ->
        assign(socket, crl: nil, crl_pem: nil)
    end
  end
end
