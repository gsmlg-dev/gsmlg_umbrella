defmodule GSMLG.GaoNote.Compat.Catalog do
  @moduledoc false
  import Ecto.Query
  alias GSMLG.GaoNote.{Label, LabelSetting}
  alias GSMLG.GaoNote.Compat.LabelSelector
  alias GSMLG.Repo

  def normalize(labels) when is_list(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, acc} ->
      pair =
        case label do
          {key, value} -> {key, value}
          [key, value] -> {key, value}
          %{} -> {field(label, :key), field(label, :value)}
          _ -> {nil, nil}
        end

      case pair do
        {key, value} when is_binary(key) and is_binary(value) ->
          case validate_input_key(key) do
            :ok -> {:cont, {:ok, [{key, value} | acc]}}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, {:invalid_input, "labels must contain key/value string pairs"}}}
      end
    end)
    |> case do
      {:ok, pairs} ->
        if length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs),
          do: {:ok, Enum.sort(pairs)},
          else: {:error, {:invalid_input, "duplicate label key"}}

      error ->
        error
    end
  end

  def normalize(_), do: {:error, {:invalid_input, "labels must be an array"}}

  defp validate_input_key(key) do
    if Repo.get_by(LabelSetting, name: key), do: :ok, else: validate_key(key)
  end

  def validate_key(key) when is_binary(key) do
    cond do
      String.trim(key) == "" ->
        {:error, {:validation_error, "label key must not be empty"}}

      String.contains?(key, ["&", "=", "!", "<", ">", "^", "$", "~"]) ->
        {:error, {:validation_error, "label key contains a reserved character"}}

      true ->
        :ok
    end
  end

  def validate_key(_), do: {:error, {:validation_error, "label key must be a string"}}

  def pairs(note),
    do: note.labels |> Enum.map(&{&1.label_setting.name, &1.value || ""}) |> Enum.sort()

  def replace(note, pairs) do
    with {:ok, settings} <- settings(pairs) do
      Repo.delete_all(from(label in Label, where: label.note_id == ^note.id))

      Enum.reduce_while(pairs, :ok, fn {key, value}, :ok ->
        setting = Map.fetch!(settings, key)

        case %Label{}
             |> Label.changeset(%{
               note_id: note.id,
               label_setting_id: setting.id,
               value: value,
               status: "valid",
               errors: []
             })
             |> Ecto.Changeset.put_change(:value, value)
             |> Repo.insert() do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def validate_values(pairs) do
    Enum.reduce_while(pairs, :ok, fn {key, value}, :ok ->
      setting = Repo.get_by(LabelSetting, name: key) || %LabelSetting{name: key}

      if LabelSelector.valid_value?(setting.value_type, value),
        do: {:cont, :ok},
        else: {:halt, {:error, {:validation_error, "invalid label value for #{key}"}}}
    end)
  end

  defp settings(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, settings} ->
      result =
        case Repo.get_by(LabelSetting, name: key) do
          nil ->
            %LabelSetting{name: key, description: "", value_type: "text", metadata: %{}}
            |> Ecto.Changeset.change()
            |> Repo.insert(on_conflict: :nothing, conflict_target: [:name])

          setting ->
            {:ok, setting}
        end

      with {:ok, _} <- result,
           setting = Repo.get_by!(LabelSetting, name: key),
           true <- LabelSelector.valid_value?(setting.value_type, value) do
        {:cont, {:ok, Map.put(settings, key, setting)}}
      else
        false -> {:halt, {:error, {:validation_error, "invalid label value for #{key}"}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
