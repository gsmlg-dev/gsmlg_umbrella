defmodule GSMLG.Config.GaoNoteSettings do
  @moduledoc "Persists GaoNote's attachment storage root in the selected TOML configuration."

  alias GSMLG.Config.Schema

  @table ~r/^[\t ]*\[gao_note\][\t ]*(?:#[^\r\n]*)?\r?$/m
  @next_table ~r/^[\t ]*\[/m
  @field ~r/^([\t ]*storage_path[\t ]*=[\t ]*)(?:"[^"\r\n]*"|'[^'\r\n]*')([\t ]*(?:#[^\r\n]*)?\r?)$/m

  def storage_path, do: Application.get_env(:gsmlg_gao_note, :storage_path, "gaonote")

  def save_storage_path(value) do
    :global.trans({__MODULE__, self()}, fn -> save(value) end, [node()])
  end

  defp save(value) do
    with {:ok, _validated} <- Schema.validate_section(:gao_note, %{storage_path: value}),
         :ok <- check_environment_override(),
         {:ok, path} <- selected_path(),
         {:ok, original} <- File.read(path),
         {:ok, decoded} <- Toml.decode(original, keys: :atoms),
         {:ok, candidate} <- update_toml(original, decoded, value),
         :ok <- verify_candidate(candidate, decoded, value),
         :ok <- atomic_write(path, candidate) do
      config = Application.get_env(:gsmlg_config, :loaded_config, %{})
      section = Map.put(Map.get(config, :gao_note, %{}), :storage_path, value)
      Application.put_env(:gsmlg_config, :loaded_config, Map.put(config, :gao_note, section))
      Application.put_env(:gsmlg_gao_note, :storage_path, value)
      {:ok, value}
    end
  end

  defp check_environment_override do
    overridden? =
      Enum.any?(System.get_env(), fn {key, _value} ->
        String.starts_with?(key, "GSMLG_") and
          String.downcase(key) == "gsmlg_gao_note__storage_path"
      end)

    if overridden?,
      do: {:error, :environment_override},
      else: :ok
  end

  defp selected_path do
    case Application.get_env(:gsmlg_config, :loaded_config_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :config_not_loaded}
    end
  end

  defp update_toml(text, decoded, value) do
    case Regex.run(@table, text, return: :index) do
      [{start, length}] ->
        section_start = start + length
        rest = binary_part(text, section_start, byte_size(text) - section_start)

        section_length =
          case Regex.run(@next_table, rest, return: :index) do
            [{offset, _length}] -> offset
            nil -> byte_size(rest)
          end

        section = binary_part(rest, 0, section_length)

        with {:ok, updated} <- update_section(section, decoded, value) do
          prefix = binary_part(text, 0, section_start)
          suffix = binary_part(rest, section_length, byte_size(rest) - section_length)
          {:ok, prefix <> updated <> suffix}
        end

      nil ->
        if Map.has_key?(decoded, :gao_note) do
          {:error, :unsupported_gao_note_toml_format}
        else
          {:ok, text <> "\n[gao_note]\nstorage_path = \"#{value}\"\n"}
        end
    end
  end

  defp update_section(section, decoded, value) do
    cond do
      Regex.match?(@field, section) ->
        {:ok,
         Regex.replace(
           @field,
           section,
           fn _match, before, after_value ->
             before <> "\"#{value}\"" <> after_value
           end,
           global: false
         )}

      Map.has_key?(Map.get(decoded, :gao_note, %{}), :storage_path) ->
        {:error, :unsupported_gao_note_toml_format}

      true ->
        {:ok, "\nstorage_path = \"#{value}\"" <> section <> "\n"}
    end
  end

  defp verify_candidate(candidate, decoded, value) do
    expected =
      Map.update(decoded, :gao_note, %{storage_path: value}, &Map.put(&1, :storage_path, value))

    case Toml.decode(candidate, keys: :atoms) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :unsupported_gao_note_toml_format}
    end
  end

  defp atomic_write(path, contents) do
    temporary = path <> ".gaonote-" <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, %{type: :regular, mode: mode, uid: uid, gid: gid}} <- File.lstat(path),
         {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
      try do
        result =
          try do
            with :ok <- File.chown(temporary, uid),
                 :ok <- File.chgrp(temporary, gid),
                 :ok <- File.chmod(temporary, Bitwise.band(mode, 0o7777)),
                 :ok <- IO.binwrite(file, contents),
                 :ok <- :file.sync(file) do
              :ok
            end
          after
            File.close(file)
          end

        with :ok <- result, do: File.rename(temporary, path)
      after
        File.rm(temporary)
      end
    else
      {:ok, _stat} -> {:error, :unsupported_config_file_type}
      {:error, _reason} = error -> error
    end
  end
end
