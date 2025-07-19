defmodule GSMLGAdminWeb.AI.SttLive.Index do
  use GSMLGAdminWeb, :user_live_view

  @impl true
  def mount(_params, _session, socket) do
    files = File.ls!(Path.expand("static/uploads", :code.priv_dir(:gsmlg_admin_web)))
      |> Enum.map(fn f ->
        "/uploads/#{f}"
      end)
    socket = socket
      |> assign(active_menu: "stt_live")
      |> assign(:uploaded_files, files)
      |> assign(:speech_text, %{})
      |> allow_upload(:audio_file, max_file_size: 100_000_000, accept: ~w(.mp3 .wav), max_entries: 1)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :audio_file, ref)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :audio_file, fn %{path: path}, _entry ->
        dest = Path.join([:code.priv_dir(:gsmlg_admin_web), "static", "uploads", Path.basename(path)])
        # You will need to create `priv/static/uploads` for `File.cp!/2` to work.
        File.cp!(path, dest)
        {:ok, ~p"/uploads/#{Path.basename(dest)}"}
      end)

    {:noreply, update(socket, :uploaded_files, &(&1 ++ uploaded_files))}
  end

  def handle_event("stt-file", %{"file" => file}, socket) do
    realpath = Path.join([:code.priv_dir(:gsmlg_admin_web), "static", file])
    view_id = self()

    Task.async(fn ->
      GSMLG.Audio.speech_to_text(realpath, 20, fn ss, out ->
        # IO.inspect({ss, out})
        Process.send_after(view_id, {:update_speech, file, ss, out}, 1000)
      end)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info({:update_speech, file, ss, text}, socket) do
    IO.puts "update speech #{file} #{ss} #{text}"
    socket = socket
    |> update(:speech_text, fn file_map ->
      list = Map.get(file_map, file, [])
      list = list ++ [{ss, text}]
      file_map |> Map.put(file, list)
    end)
    IO.inspect socket.assigns.speech_text

    {:noreply, socket}
  end
  def handle_info(info, socket) do
    IO.inspect {:unhandled_info, info}
    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Whisper Speech to Text")
  end

  defp error_to_string(:too_large), do: "Too large"
  defp error_to_string(:too_many_files), do: "You have selected too many files"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"
end
