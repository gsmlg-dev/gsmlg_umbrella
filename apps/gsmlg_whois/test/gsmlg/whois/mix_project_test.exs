defmodule GSMLG.Whois.MixProjectTest do
  use ExUnit.Case, async: true

  test "does not start Concord unless the host application opts into clustered cache" do
    applications = Application.spec(:gsmlg_whois, :applications)

    refute :concord in applications
  end
end
