defmodule GSMLG.Whois.MixProjectTest do
  use ExUnit.Case, async: true

  test "package constrains Concord to the compatible ExTurso release line" do
    assert {:ex_turso, "~> 0.3.0", options} =
             List.keyfind(Mix.Project.config()[:deps], :ex_turso, 0)

    assert options[:runtime] == false
    assert options[:optional] == true
    assert :ex_turso in Application.spec(:concord, :applications)
  end

  test "Concord is optional and starts when the host opts into it" do
    assert {:concord, "~> 2.0", options} =
             List.keyfind(Mix.Project.config()[:deps], :concord, 0)

    assert options[:optional] == true
    applications = Application.spec(:gsmlg_whois, :applications)

    assert :concord in applications
  end
end
