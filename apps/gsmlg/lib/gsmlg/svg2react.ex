defmodule GSMLG.SVG2React do
  @moduledoc """
  SVG-to-React conversion entry point, retained while conversion is unavailable.
  """

  @unavailable_message "SVG to React conversion is temporarily unavailable."

  @doc false
  def unavailable_message, do: @unavailable_message

  @doc """
  Returns an unavailable error until SVG-to-React conversion is restored.
  """
  @spec convert(map()) :: {:error, String.t()}
  # Restore conversion here with a supported converter before enabling the form.
  def convert(_data), do: {:error, @unavailable_message}
end
