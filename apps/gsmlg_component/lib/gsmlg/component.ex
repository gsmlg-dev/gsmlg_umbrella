defmodule GSMLG.Component do
  @moduledoc """
  Shared Componennt in `GSMLG` Umbrella Project.
  """

  defmacro __using__([]) do
    quote do
      import GSMLG.Component.Admin
      import GSMLG.Component.Github
      import GSMLG.Component.React
      import GSMLG.Component.Static.Logo
    end
  end
end
