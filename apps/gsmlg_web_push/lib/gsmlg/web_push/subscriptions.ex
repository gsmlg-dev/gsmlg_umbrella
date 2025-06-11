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

  use GenServer

  def create_subscription(attrs \\ %{}) do
    subscription = Subscription.new(attrs)

    GenServer.call(__MODULE__, {:create_subscription, subscription})
  end

  def get_subscriptions do
    GenServer.call(__MODULE__, :get_subscriptions)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_init_arg) do
    {:ok, []}
  end

  def handle_call(:get_subscriptions, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:create_subscription, subscription}, _from, state) do
    {:reply, {:ok, subscription}, [subscription | state]}
  end
end
