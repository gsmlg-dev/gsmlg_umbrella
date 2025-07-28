defmodule GSMLG.Nx.Audio do
  def speech_to_text(path, chunk_time, func) do
    {:ok, stat} = parse_mp3(path)

    duration = stat.duration |> trunc

    0..duration//chunk_time
    |> Task.async_stream(
      fn ss ->
        args = ~w[-ac 1 -ar 16k -f f32le -ss #{ss} -t #{chunk_time} -v quiet -]
        {data, 0} = System.cmd("ffmpeg", ["-i", path] ++ args)
        {ss, Nx.Serving.batched_run(WhisperServing, Nx.from_binary(data, :f32))}
      end,
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, {ss, %{chunks: [%{text: text}]}}} -> func.(ss, text) end)
  end

  def parse_mp3(path) do
    case System.cmd("ffprobe", [
           "-v",
           "error",
           "-show_entries",
           "format=duration",
           "-of",
           "default=noprint_wrappers=1:nokey=1",
           path
         ]) do
      {duration_str, 0} ->
        duration = String.trim(duration_str) |> String.to_float()
        {:ok, %{duration: duration}}

      {error_msg, _exit_code} ->
        {:error, error_msg}
    end
  end
end
