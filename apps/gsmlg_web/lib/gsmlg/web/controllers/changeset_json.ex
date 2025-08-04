defmodule GSMLG.Web.ChangesetJSON do
  defp te({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(GSMLG.Web.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GSMLG.Web.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Traverses and translates changeset errors.

  See `Ecto.Changeset.traverse_errors/2` and
  `GSMLG.Web.CoreCompponents.translate_error/1` for more details.
  """
  def translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &te/1)
  end

  @doc """
  Renders changeset errors.
  """
  def error(%{changeset: changeset}) do
    # When encoded, the changeset returns its errors
    # as a JSON object. So we just pass it forward.
    %{errors: translate_errors(changeset)}
  end
end
