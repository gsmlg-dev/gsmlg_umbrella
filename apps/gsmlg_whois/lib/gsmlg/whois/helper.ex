defmodule GSMLG.Whois.Helper do
  @moduledoc false

  defmacro define_from_file(name) do
    quote do
      Module.put_attribute(
        __MODULE__,
        unquote(name),
        File.read!(Application.app_dir(:gsmlg_whois, "priv/#{unquote(name)}.csv"))
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(fn line ->
          [k, host] = String.split(line, ",")
          {k, %{__struct__: __MODULE__, host: host}}
        end)
        |> Map.new()
      )

      # @spec unquote(name)() :: map
      def unquote(name)(), do: @unquote(name)()
    end
  end
end
