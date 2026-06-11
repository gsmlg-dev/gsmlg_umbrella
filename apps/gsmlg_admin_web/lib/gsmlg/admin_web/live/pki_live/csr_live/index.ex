defmodule GSMLG.AdminWeb.PKILive.CSRLive.Index do
  use GSMLG.AdminWeb, :user_live_view
  alias GSMLG.AdminWeb.PKIContext

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(csr_requests: [], cas: [], page_title: "CSR Management", active_menu: "pki_csr")
      |> load_csr_requests()
      |> load_cas()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, :active_menu, "pki_csr")

  defp apply_action(socket, :upload, _params) do
    socket
    |> assign(:active_menu, "pki_csr_upload")
    |> assign(:upload_form, %{
      "ca_id" => "",
      "csr_pem" => "",
      "template" => "server",
      "validity_days" => "365",
      "notes" => ""
    })
  end

  @impl true
  def handle_event("upload_csr", params, socket) do
    user = socket.assigns.current_user

    case PKIContext.create_csr_request(params, user.email) do
      {:ok, _csr_request} ->
        {:noreply,
         socket
         |> put_flash(:info, "CSR uploaded successfully")
         |> load_csr_requests()
         |> push_navigate(to: ~p"/pki/csr")}

      {:error, changeset} ->
        {:noreply,
         socket |> put_flash(:error, "Failed to upload CSR: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("approve_csr", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case PKIContext.approve_csr_request(String.to_integer(id), actor: user.email) do
      {:ok, cert} ->
        {:noreply,
         socket
         |> put_flash(:info, "CSR approved and certificate issued")
         |> load_csr_requests()
         |> push_navigate(to: ~p"/pki/certificates/#{cert.serial}")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Failed to approve CSR: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_csr", %{"id" => id, "notes" => notes}, socket) do
    case PKIContext.reject_csr_request(String.to_integer(id), notes) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "CSR rejected") |> load_csr_requests()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Failed to reject CSR: #{inspect(reason)}")}
    end
  end

  defp load_csr_requests(socket) do
    case PKIContext.list_csr_requests() do
      {:ok, requests} -> assign(socket, :csr_requests, requests)
      _ -> assign(socket, :csr_requests, [])
    end
  end

  defp load_cas(socket) do
    case PKIContext.list_cas() do
      {:ok, cas} -> assign(socket, :cas, cas)
      _ -> assign(socket, :cas, [])
    end
  end
end
