defmodule GSMLGMnesia.Support.Case do
  use ExUnit.CaseTemplate

  @moduledoc """
  Default Test Case with important aliases/imports
  """

  using do
    quote do
      alias GSMLGMnesia.Support
      alias GSMLGMnesia.Support.Definitions.Tables

      import Support.Mnesia,
        only: [
          transaction: 1,
          transaction!: 1
        ]
    end
  end

  setup tags do
    unless tags[:async] do
      GSMLGMnesia.Support.Mnesia.reset()
    end

    :ok
  end
end
