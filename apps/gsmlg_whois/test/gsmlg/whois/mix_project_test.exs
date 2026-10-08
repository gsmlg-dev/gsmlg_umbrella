defmodule GSMLG.Whois.MixProjectTest do
  use ExUnit.Case, async: true

  test "package constrains Concord to the compatible ExTurso release line" do
    assert {:ex_turso, "~> 0.3.0", options} =
             List.keyfind(Mix.Project.config()[:deps], :ex_turso, 0)

    assert options[:runtime] == false
    assert :ex_turso in Application.spec(:concord, :applications)
  end

  test "starts Concord for the built-in Concord cache backend" do
    applications = Application.spec(:gsmlg_whois, :applications)

    assert :concord in applications
  end
end
