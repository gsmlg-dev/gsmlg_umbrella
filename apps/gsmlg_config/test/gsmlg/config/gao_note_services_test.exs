defmodule GSMLG.Config.GaoNoteServicesTest do
  use ExUnit.Case, async: false

  setup do
    previous =
      for key <- [:compat_services, :storage_path],
          do: {key, Application.fetch_env(:gsmlg_gao_note, key)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_gao_note, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_gao_note, key)
      end)
    end)

    :ok
  end

  test "TOML service configuration validates and reaches GaoNote application environment" do
    config = %{
      index_url: "http://index/v1/gao-note/index",
      search_url: "http://index/v1/gao-note/search",
      search_token: "service-token",
      minimum_score: 0.01,
      pdf_renderer_url: "http://renderer:3000"
    }

    assert {:ok, validated} = GSMLG.Config.Schema.validate_section(:gao_note, config)
    GSMLG.Config.Setup.setup(%{gao_note: validated})
    assert Application.get_env(:gsmlg_gao_note, :compat_services)[:index_url] == config.index_url
    assert Application.get_env(:gsmlg_gao_note, :compat_services)[:minimum_score] == 0.01

    assert {:error, _} =
             GSMLG.Config.Schema.validate_section(:gao_note, %{minimum_score: "not a number"})
  end

  test "storage path defaults to gaonote and reaches the application environment" do
    assert {:ok, %{storage_path: "gaonote"} = validated} =
             GSMLG.Config.Schema.validate_section(:gao_note, %{})

    GSMLG.Config.Setup.setup(%{gao_note: validated})
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "gaonote"
  end

  test "custom storage path reaches the application environment alongside compatibility services" do
    assert {:ok, validated} =
             GSMLG.Config.Schema.validate_section(:gao_note, %{
               storage_path: "Notes_2026-backup",
               search_url: "http://index/v1/gao-note/search"
             })

    GSMLG.Config.Setup.setup(%{gao_note: validated})
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "Notes_2026-backup"

    assert Application.get_env(:gsmlg_gao_note, :compat_services)[:search_url] ==
             "http://index/v1/gao-note/search"
  end

  test "setup defaults the storage path for callers omitting the field" do
    Application.put_env(:gsmlg_gao_note, :storage_path, "previous")
    GSMLG.Config.Setup.setup(%{gao_note: %{search_url: "http://index/search"}})
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "gaonote"
  end

  test "storage path rejects empty values and unsafe path segments" do
    for path <- ["", " ", "a/b", "/gaonote", "a\\b", ".", "..", "../gaonote", "a.b", "gaonote\n"] do
      assert {:error, reason} =
               GSMLG.Config.Schema.validate_section(:gao_note, %{storage_path: path})

      assert reason =~ "storage_path"
    end
  end

  test "storage path rejects non-string values" do
    for value <- [nil, 123, true, [:gaonote], %{path: "gaonote"}] do
      assert {:error, reason} =
               GSMLG.Config.Schema.validate_section(:gao_note, %{storage_path: value})

      assert reason =~ "storage_path"
    end
  end

  test "default TOML includes the GaoNote storage path" do
    path = Path.expand("../../../priv/gsmlg.toml", __DIR__)
    assert {:ok, config} = Toml.decode_file(path, keys: :atoms)
    assert config.gao_note[:storage_path] == "gaonote"
  end

  test "generic environment override configures the GaoNote storage path" do
    variable = "GSMLG_GAO_NOTE__STORAGE_PATH"
    previous = System.get_env(variable)
    System.put_env(variable, "custom-notes")

    on_exit(fn ->
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end)

    assert {:ok, %{gao_note: config}} =
             GSMLG.Config.Loader.apply_env_overrides(%{gao_note: %{storage_path: "gaonote"}})

    assert {:ok, %{storage_path: "custom-notes"} = validated} =
             GSMLG.Config.Schema.validate_section(:gao_note, config)

    GSMLG.Config.Setup.setup(%{gao_note: validated})
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "custom-notes"
  end
end
