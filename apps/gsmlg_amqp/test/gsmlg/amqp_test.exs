defmodule GSMLG.AMQPTest do
  use ExUnit.Case
  doctest GSMLG.AMQP

  test "greets the world" do
    assert GSMLG.AMQP.hello() == :world
  end
end
