defmodule GSMLG.CouchDB.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # {GSMLG.CouchDB.Connection, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.CouchDB.Supervisor)
  end
end
