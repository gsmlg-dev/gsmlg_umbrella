defmodule GSMLG.WebPush.Subscriptions do
  @moduledoc """
  This module manages web push subscriptions using a GenServer.
  It allows creating new subscriptions and retrieving existing ones.

  In-memory storage is used for simplicity, but this can be extended to use a database or other persistent storage.

  Add to your `application.ex` supervision tree:

  ```elixir
  def start(_type, _args) do
    children = [
      ...
      GSMLG.WebPush.Subscriptions
    ]

    opts = [strategy: :one_for_one, name: __MODULE__.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```
  """
  alias GSMLG.WebPush.Subscription

  use Agent

  def start_link(args) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def create(attrs \\ %{}) do
    subscription = Subscription.new(attrs)

    Agent.update(__MODULE__, fn subscriptions ->
      Map.put(subscriptions, subscription.endpoint, subscription)
    end)
  end

  def get(endpoint) do
    Agent.get(__MODULE__, fn subscriptions ->
      subscriptions |> Map.get(endpoint)
    end)
  end

  def remove(endpoint) do
    Agent.update(__MODULE__, fn subscriptions ->
      Map.delete(subscriptions, endpoint)
    end)
  end

  def get_subscriptions do
    Agent.get(__MODULE__, fn subscriptions ->
      subscriptions |> to_list()
    end)
  end

  defp to_list(subscriptions) do
    subscriptions
    |> Enum.into([], fn {_key, s} ->
      s
    end)
  end
end
