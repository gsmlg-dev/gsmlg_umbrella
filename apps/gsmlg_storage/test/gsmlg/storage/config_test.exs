defmodule GSMLG.Storage.ConfigTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.Config

  describe "defaults/0" do
    test "returns default configuration map" do
      defaults = Config.defaults()

      assert defaults.s3_bucket == "gsmlg-storage"
      assert defaults.max_file_size == 5 * 1024 * 1024 * 1024
      assert defaults.cleanup_interval == 3_600_000
      assert defaults.retention_window == 30 * 24 * 3600
    end

    test "includes allowed_types with known categories" do
      defaults = Config.defaults()

      assert is_map(defaults.allowed_types)
      assert is_list(defaults.allowed_types["avatar"])
      assert "image/jpeg" in defaults.allowed_types["avatar"]
      assert defaults.allowed_types["attachment"] == :any
    end

    test "includes variant_definitions for image types" do
      defaults = Config.defaults()

      assert is_map(defaults.variant_definitions)
      assert is_map(defaults.variant_definitions["avatar"])
      assert Keyword.keyword?(defaults.variant_definitions["avatar"]["thumb"])
    end
  end
end
