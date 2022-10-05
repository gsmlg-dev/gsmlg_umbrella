defmodule GSMLG_CouchDB.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {GSMLG_CouchDB.Connection, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG_CouchDB.Supervisor)
  end
end
