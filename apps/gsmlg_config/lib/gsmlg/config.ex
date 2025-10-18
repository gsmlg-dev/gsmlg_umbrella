defmodule GSMLG.Config do
  @moduledoc """
  Documentation for `GSMLG.Config`.
  """

  use Agent

  def start_link(_) do
    initial_value = load()
    GSMLG.Config.Setup.setup(initial_value)
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def load() do
    default_file = Path.expand("gsmlg.toml", :code.priv_dir(:gsmlg_config))
    file_path = System.get_env("GSMLG_CONFIG_PATH", default_file)
    {:ok, config} = Toml.decode_file(file_path, keys: :atoms)

    config
  end

  def config() do
    Agent.get(__MODULE__, & &1)
  end

  def get(name) when is_binary(name) or is_atom(name) do
    Agent.get(__MODULE__, fn config ->
      # Try with the given key first, then try converting
      case Map.get(config, name) do
        nil when is_binary(name) -> Map.get(config, String.to_atom(name))
        nil when is_atom(name) -> Map.get(config, Atom.to_string(name))
        value -> value
      end
    end)
  end

  def get(name_path) when is_list(name_path) do
    Agent.get(__MODULE__, &get_in(&1, name_path))
  end

  def put(name, value) when is_binary(name) or is_atom(name) do
    Agent.update(__MODULE__, &Map.put(&1, name, value))
  end

  def put(name_path, value) when is_list(name_path) do
    Agent.update(__MODULE__, &put_in(&1, name_path, value))
  end
end
