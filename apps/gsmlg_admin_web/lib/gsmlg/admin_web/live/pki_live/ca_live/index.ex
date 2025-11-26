defmodule GSMLG.AdminWeb.PKILive.CALive.Index do
  @moduledoc """
  LiveView for Certificate Authority management.

  Displays a list of all CAs with their statistics and provides
  functionality to initialize new CAs with enhanced form including
  individual subject fields, multiple key types, and optional encryption.
  """
  use GSMLG.AdminWeb, :user_live_view

  alias Phoenix.SessionProcess
  alias GSMLG.AdminWeb.PKIContext
  alias GSMLG.AdminWeb.PKILive.CALive.FormData
  alias GSMLG.PKI.KeyGenerator

  require Logger

  @impl true
  def mount(_params, session, socket) do
    Process.flag(:trap_exit, true)

    session_id = Map.get(session, "session_id")

    socket =
      socket
      |> assign(
        cas: [],
        active_menu: "pki_ca_list",
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
    # Initialize form with default values
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    default_end = DateTime.add(now, 10 * 365 * 24 * 3600, :second)

    form_data = %FormData{
      key_type: "rsa",
      key_size: 4096,
      validity_start: now,
      validity_end: default_end,
      encrypt_key: false
    }

    changeset = FormData.changeset(form_data, %{})

    socket
    |> assign(:page_title, "Initialize New CA")
    |> assign(:form, to_form(changeset))
    |> assign(:changeset, changeset)
    |> assign(:key_type, "rsa")
    |> assign(:available_key_sizes, KeyGenerator.get_key_size_options(:rsa))
  end

  @impl true
  def handle_event("validate_form", params, socket) do
    changeset =
      %FormData{}
      |> FormData.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("key_type_changed", %{"key_type" => key_type}, socket) do
    key_type_atom = String.to_existing_atom(key_type)
    available_sizes = KeyGenerator.get_key_size_options(key_type_atom)
    default_size = List.first(available_sizes) || 256

    # Update changeset with new key type and default size
    changeset =
      socket.assigns.changeset
      |> Ecto.Changeset.put_change(:key_type, key_type)
      |> Ecto.Changeset.put_change(:key_size, default_size)

    {:noreply,
     socket
     |> assign(:key_type, key_type)
     |> assign(:available_key_sizes, available_sizes)
     |> assign(:changeset, changeset)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("create_ca", params, socket) do
    changeset = FormData.changeset(%FormData{}, params)

    if changeset.valid? do
      form_data = Ecto.Changeset.apply_changes(changeset)
      subject_dn = FormData.build_subject_dn(form_data)
      user = socket.assigns.current_user

      opts = [
        key_type: String.to_existing_atom(form_data.key_type),
        key_size: form_data.key_size,
        validity_start: form_data.validity_start,
        validity_end: form_data.validity_end,
        encrypt_key: form_data.encrypt_key,
        password: form_data.password,
        actor: user.email
      ]

      start_time = System.monotonic_time(:millisecond)

      case PKIContext.initialize_ca(subject_dn, opts) do
        {:ok, ca} ->
          duration = System.monotonic_time(:millisecond) - start_time

          # Log telemetry event for successful CA creation
          Logger.info("CA initialized successfully",
            event: "pki.ca.created",
            user_id: user.id,
            user_email: user.email,
            ca_id: ca.id,
            ca_serial: ca.serial,
            common_name: form_data.common_name,
            key_type: form_data.key_type,
            key_size: form_data.key_size,
            encrypted: form_data.encrypt_key,
            duration_ms: duration
          )

          success_msg = build_success_message(ca, form_data)

          {:noreply,
           socket
           |> put_flash(:info, success_msg)
           |> load_cas()
           |> push_navigate(to: ~p"/pki/ca")}

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time

          # Log telemetry event for failed CA creation
          Logger.warning("CA initialization failed",
            event: "pki.ca.creation_failed",
            user_id: user.id,
            user_email: user.email,
            common_name: form_data.common_name,
            key_type: form_data.key_type,
            key_size: form_data.key_size,
            encrypted: form_data.encrypt_key,
            error: inspect(reason),
            duration_ms: duration
          )

          error_msg = build_error_message(reason, form_data)

          {:noreply,
           socket
           |> put_flash(:error, error_msg)
           |> assign(:form, to_form(changeset))}
      end
    else
      {:noreply,
       socket
       |> assign(:changeset, changeset)
       |> assign(:form, to_form(changeset))}
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

  # Build user-friendly success message with key details
  defp build_success_message(ca, form_data) do
    key_type_display =
      case form_data.key_type do
        "rsa" -> "RSA-#{form_data.key_size}"
        "ecdsa" -> "ECDSA P-#{form_data.key_size}"
        "ed25519" -> "Ed25519"
        _ -> form_data.key_type
      end

    encryption_status = if form_data.encrypt_key, do: "encrypted", else: "unencrypted"

    "CA '#{form_data.common_name}' initialized successfully with #{key_type_display} key (#{encryption_status}). Serial: #{ca.serial}"
  end

  # Build user-friendly error message based on error type
  defp build_error_message(reason, form_data) do
    case reason do
      {:invalid_key_parameters, key_type, key_size} ->
        "Invalid key configuration: #{key_type} does not support #{key_size}-bit keys. Please select a valid key size."

      {:key_generation_failed, _details} ->
        "Key generation failed. This may be due to insufficient system resources or cryptographic library issues. Please try again with a smaller key size."

      {:duplicate_subject, existing_serial} ->
        "A CA with Common Name '#{form_data.common_name}' already exists (Serial: #{existing_serial}). Please use a unique Common Name."

      {:invalid_subject_dn, _details} ->
        "Invalid subject information. Please check that all fields contain valid characters and try again."

      {:database_error, _details} ->
        "Unable to save CA to database. Please check your database connection and try again."

      {:encryption_error, _details} ->
        "Failed to encrypt private key. Please verify your password meets the requirements and try again."

      _ ->
        "Failed to initialize CA: #{inspect(reason)}. Please check your inputs and try again."
    end
  end
end
