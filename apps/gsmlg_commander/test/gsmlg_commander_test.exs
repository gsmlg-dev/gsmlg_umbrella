defmodule GSMLG.CommanderTest do
  use ExUnit.Case
  doctest GSMLG.Commander

  test "return socket opts to have :url and :params" do
    assert {:ok, _} = GSMLG.Commander.socket_opts() |> Keyword.fetch(:url)
    assert {:ok, _} = GSMLG.Commander.socket_opts() |> Keyword.fetch(:params)
  end
end
