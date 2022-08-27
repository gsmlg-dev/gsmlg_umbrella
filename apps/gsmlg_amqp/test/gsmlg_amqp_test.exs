defmodule GSMLG_AMQPTest do
  use ExUnit.Case
  doctest GSMLG_AMQP

  test "greets the world" do
    assert GSMLG_AMQP.hello() == :world
  end
end
