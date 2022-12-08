defmodule GSMLG.Mnesia.Support.Case do
  use ExUnit.CaseTemplate

  @moduledoc """
  Default Test Case with important aliases/imports
  """

  using do
    quote do
      alias GSMLG.Mnesia.Support
      alias GSMLG.Mnesia.Support.Definitions.Tables

      import Support.Mnesia,
        only: [
          transaction: 1,
          transaction!: 1
        ]
    end
  end

  setup tags do
    unless tags[:async] do
      GSMLG.Mnesia.Support.Mnesia.reset()
    end

    :ok
  end
end
