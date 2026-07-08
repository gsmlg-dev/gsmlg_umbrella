defmodule GSMLG.Whois.MixProjectTest do
  use ExUnit.Case, async: true

  test "starts Concord for the built-in Concord cache backend" do
    applications = Application.spec(:gsmlg_whois, :applications)

    assert :concord in applications
  end
end
