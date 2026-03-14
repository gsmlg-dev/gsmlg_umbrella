defmodule GSMLG.IpGeoTest do
  use ExUnit.Case, async: false

  alias GSMLG.IpGeo.Database

  setup do
    _pid =
      case Process.whereis(Database) do
        nil ->
          {:ok, new_pid} = Database.start_link([])
          new_pid

        existing_pid ->
          existing_pid
      end

    :ok
  end

  describe "lookup/2" do
    @tag :requires_database
    test "returns geo info for valid IPv4 address" do
      assert {:ok, info} = GSMLG.IpGeo.lookup("8.8.8.8")
      assert is_map(info)
      assert Map.has_key?(info, :country)
      assert Map.has_key?(info, :country_code)
    end

    @tag :requires_database
    test "returns geo info for IPv4 tuple" do
      assert {:ok, info} = GSMLG.IpGeo.lookup({8, 8, 8, 8})
      assert is_map(info)
    end

    @tag :requires_database
    test "returns geo info for IPv6 address" do
      assert {:ok, info} = GSMLG.IpGeo.lookup("2001:4860:4860::8888")
      assert is_map(info)
    end

    test "returns error for invalid IP" do
      assert {:error, {:invalid_ip, _}} = GSMLG.IpGeo.lookup(:not_an_ip)
    end

    test "returns error for malformed IP string" do
      assert {:error, :einval} = GSMLG.IpGeo.lookup("not.a.valid.ip")
    end
  end

  describe "country/2" do
    @tag :requires_database
    test "returns country name for valid IP" do
      assert {:ok, country} = GSMLG.IpGeo.country("8.8.8.8")
      assert is_binary(country) or is_nil(country)
    end
  end

  describe "country_code/2" do
    @tag :requires_database
    test "returns ISO country code for valid IP" do
      assert {:ok, code} = GSMLG.IpGeo.country_code("8.8.8.8")
      assert is_nil(code) or (is_binary(code) and byte_size(code) == 2)
    end
  end

  describe "city/2" do
    @tag :requires_database
    test "returns city name for valid IP" do
      assert {:ok, city} = GSMLG.IpGeo.city("8.8.8.8")
      assert is_binary(city) or is_nil(city)
    end
  end

  describe "coordinates/2" do
    @tag :requires_database
    test "returns lat/long tuple for valid IP" do
      case GSMLG.IpGeo.coordinates("8.8.8.8") do
        {:ok, {lat, lon}} ->
          assert is_float(lat) or is_integer(lat)
          assert is_float(lon) or is_integer(lon)
          assert lat >= -90 and lat <= 90
          assert lon >= -180 and lon <= 180

        {:ok, nil} ->
          :ok
      end
    end
  end

  describe "list_databases/0" do
    @tag :requires_database
    test "returns list of loaded database names" do
      databases = GSMLG.IpGeo.list_databases()
      assert is_list(databases)
    end
  end

  describe "database_info/1" do
    @tag :requires_database
    test "returns metadata for loaded database" do
      case GSMLG.IpGeo.database_info(:city) do
        {:ok, info} ->
          assert Map.has_key?(info, :database_type)
          assert Map.has_key?(info, :build_epoch)
          assert %DateTime{} = info.build_epoch

        {:error, {:database_not_loaded, :city}} ->
          :ok
      end
    end

    test "returns error for unknown database" do
      assert {:error, {:database_not_loaded, :nonexistent}} =
               GSMLG.IpGeo.database_info(:nonexistent)
    end
  end
end
