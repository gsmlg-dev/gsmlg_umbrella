defmodule GSMLG.AdminWeb.PKILive.CALive.Index do
  @moduledoc """
  LiveView for Certificate Authority management.

  Displays a list of all CAs with their statistics and provides
  functionality to initialize new CAs.
  """
  use GSMLG.AdminWeb, :user_live_view

  alias Phoenix.SessionProcess
  alias GSMLG.AdminWeb.PKIContext

  @impl true
  def mount(_params, session, socket) do
    Process.flag(:trap_exit, true)

    session_id = Map.get(session, "session_id")

    socket =
      socket
      |> assign(
        cas: [],
        active_menu: "pki_management",
        session_id: session_id,
        page_title: "Certificate Authorities"
      )
      |> load_cas()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Certificate Authorities")
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Initialize New CA")
    |> assign(:form_data, %{
      "subject" => "",
      "key_type" => "rsa",
      "key_size" => "4096",
      "validity" => "7300"
    })
  end

  @impl true
  def handle_event("initialize_ca", params, socket) do
    user = socket.assigns.current_user

    opts = [
      key_type: String.to_existing_atom(params["key_type"]),
      key_size: String.to_integer(params["key_size"]),
      validity: String.to_integer(params["validity"]),
      actor: user.email
    ]

    case PKIContext.initialize_ca(params["subject"], opts) do
      {:ok, _ca} ->
        {:noreply,
         socket
         |> put_flash(:info, "CA initialized successfully")
         |> load_cas()
         |> push_navigate(to: ~p"/pki/ca")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to initialize CA: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_ca", %{"ca_id" => ca_id}, socket) do
    # Note: CA deletion should be carefully controlled
    # For now, we just show a confirmation
    {:noreply,
     socket
     |> put_flash(
       :warning,
       "CA deletion is not yet implemented. This operation requires careful consideration."
     )}
  end

  defp load_cas(socket) do
    case PKIContext.list_cas() do
      {:ok, cas} ->
        assign(socket, :cas, cas)

      {:error, _} ->
        assign(socket, :cas, [])
    end
  end
end
