defmodule GSMLG.Commander.ReleaseConfigurationTest do
  use ExUnit.Case, async: true

  test "protocol application starts permanently in every Commander-bearing release" do
    releases = GSMLG.Umbrella.MixProject.project()[:releases]

    for release <- [:gsmlg_commander, :gsmlg_umbrella, :gsmlg_umbrella_standalone] do
      assert get_in(releases, [release, :applications, :gsmlg_commander_protocol]) == :permanent
    end
  end

  test "remote and central Browser applications stay in their respective releases" do
    releases = GSMLG.Umbrella.MixProject.project()[:releases]

    assert get_in(releases, [:gsmlg_commander, :applications, :gsmlg_browser_agent]) ==
             :permanent

    refute get_in(releases, [:gsmlg_commander, :applications, :gsmlg_browser])

    for release <- [:gsmlg_umbrella, :gsmlg_umbrella_standalone] do
      assert get_in(releases, [release, :applications, :gsmlg_browser]) == :permanent
      refute get_in(releases, [release, :applications, :gsmlg_browser_agent])
    end
  end

  test "generated Commander configuration contains only a runtime credential reference" do
    source = File.read!(Path.expand("../../../rel/env.sh.eex", __DIR__))

    assert source =~ ~s(credential_id = "commander")
    assert source =~ ~s(platform_key_env = "GSMLG_COMMANDER_PLATFORM_KEY")
    refute Regex.match?(~r/^\s*platform_key\s*=/m, source)
    refute source =~ "CHANGE_ME"
  end
end
