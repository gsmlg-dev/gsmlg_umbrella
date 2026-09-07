defmodule GSMLG.Browser.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias GSMLG.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import GSMLG.Browser.DataCase
      import GSMLG.Browser.Fixtures
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(GSMLG.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  def actor_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      GSMLG.Accounts.create_user(%{
        username: "browser_actor_#{suffix}",
        email: "browser_actor_#{suffix}@example.com",
        password: "browser-test-password"
      })

    actor
  end
end
