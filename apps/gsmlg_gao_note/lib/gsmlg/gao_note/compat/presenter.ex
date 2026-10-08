defmodule GSMLG.GaoNote.Compat.Presenter do
  @moduledoc false

  def summary(note) do
    %{
      id: note.id,
      title: note.title,
      labels: labels(note),
      created_at: timestamp(note.created_at),
      updated_at: timestamp(note.updated_at),
      revision: note.revision
    }
  end

  def note(note) do
    Map.merge(summary(note), %{
      content: note.content,
      attachments: Enum.map(loaded(note.attachments), &attachment/1)
    })
  end

  def trash(note), do: Map.put(summary(note), :deleted_at, timestamp(note.deleted_at))

  def mcp_summary(note), do: Map.put(summary(note), :labels, mcp_labels(note))
  def mcp_note(note), do: Map.put(note(note), :labels, mcp_labels(note))

  def attachment(attachment) do
    %{
      id: Map.get(attachment, :api_id) || attachment.id,
      path: String.trim_leading(attachment.path, "./"),
      mime: attachment.mime,
      description: attachment.description || ""
    }
  end

  def label_setting(setting) do
    %{
      key: setting.name,
      description: setting.description || "",
      value_type: value_type(setting.value_type)
    }
  end

  def timestamp(nil), do: nil
  def timestamp(%DateTime{} = value), do: DateTime.to_unix(value)

  def timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  def timestamp(value) when is_integer(value), do: value

  def value_type("date-time"), do: "datetime"
  def value_type(value) when value in ~w(text number date time datetime version), do: value
  def value_type(_value), do: "text"

  defp labels(note), do: Enum.map(mcp_labels(note), &[&1.key, &1.value])

  defp mcp_labels(note) do
    note.labels
    |> loaded()
    |> Enum.map(fn label ->
      Map.put(label_setting(label.label_setting), :value, label.value || "")
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp loaded(values) when is_list(values), do: values
  defp loaded(_), do: []
end
