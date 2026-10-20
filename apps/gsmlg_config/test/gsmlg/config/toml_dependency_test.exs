defmodule GSMLG.Config.TomlDependencyTest do
  use ExUnit.Case, async: true

  test "the TOML application supplies the parser and release provider" do
    assert :ok = Application.ensure_loaded(:gsmlg_toml)

    for module <- [Toml, Toml.Decoder, Toml.Provider, Toml.Transform] do
      assert {:ok, :gsmlg_toml} = :application.get_application(module)
    end

    assert {:ok, %{"service" => %{"enabled" => true}}} =
             Toml.decode("[service]\nenabled = true\n")
  end
end
