defmodule GSMLG.Config.FailClosedTest do
  use ExUnit.Case, async: false

  alias GSMLG.Config.Loader

  @enable_envs ~w(
    GSMLG_BROWSER__ENABLED
    GSMLG_BROWSER_AGENT__ENABLED
    GSMLG_COMMANDER__START
    GSMLG_COMMANDER__SERVER
  )

  setup do
    previous = Map.new(@enable_envs, &{&1, System.get_env(&1)})
    Enum.each(@enable_envs, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "configuration errors fail closed when a Browser or Commander component is enabled" do
    for body <- [
          "[browser]\nenabled = true\n",
          "[browser_agent]\nenabled = true\n",
          "[commander]\nstart = true\n",
          "[commander]\nserver = true\n"
        ] do
      path = write_config(body)
      assert Loader.fail_closed_on_error?(config_path: path, env: :test)
    end
  end

  test "disabled unrelated deployments retain the existing fallback behavior" do
    path =
      write_config("""
      [browser]
      enabled = false

      [browser_agent]
      enabled = false

      [commander]
      start = false
      server = false
      """)

    refute Loader.fail_closed_on_error?(config_path: path, env: :test)
  end

  test "an explicit unreadable config and runtime enable override always fail closed" do
    missing = Path.join(System.tmp_dir!(), "missing-browser-config-#{System.unique_integer()}")
    assert Loader.fail_closed_on_error?(config_path: missing, env: :test)

    path = write_config("[browser]\nenabled = false\n")
    System.put_env("GSMLG_BROWSER__ENABLED", "true")
    assert Loader.fail_closed_on_error?(config_path: path, env: :test)
  end

  test "runtime configuration aborts for an invalid enabled Browser component" do
    path = write_config("[browser]\nenabled = true\n")
    previous = System.get_env("GSMLG_CONFIG_PATH")
    System.put_env("GSMLG_CONFIG_PATH", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("GSMLG_CONFIG_PATH", previous),
        else: System.delete_env("GSMLG_CONFIG_PATH")
    end)

    runtime = Path.expand("../../../../../config/runtime.exs", __DIR__)

    assert_raise RuntimeError, ~r/invalid configuration for an enabled Browser/, fn ->
      Config.Reader.read!(runtime, env: :test, target: :host)
    end
  end

  defp write_config(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "gsmlg-browser-config-#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
