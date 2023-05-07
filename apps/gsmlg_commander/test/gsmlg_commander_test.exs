defmodule GSMLGCommanderTest do
  use ExUnit.Case
  doctest GSMLGCommander

  test "return socket opts to have :url and :params" do
    assert {:ok, _} = GSMLGCommander.socket_opts() |> Keyword.fetch(:url)
    assert {:ok, _} = GSMLGCommander.socket_opts() |> Keyword.fetch(:params)
  end
end
