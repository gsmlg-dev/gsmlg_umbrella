defmodule GSMLG.Scout.SecurityTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Fetch.Job

  setup do
    previous = Application.get_env(:gsmlg_scout, :dns_resolver)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gsmlg_scout, :dns_resolver)
        value -> Application.put_env(:gsmlg_scout, :dns_resolver, value)
      end
    end)

    :ok
  end

  test "accepts public HTTP and HTTPS URLs" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.PublicResolver)

    assert {:ok, %Job{url: "https://example.com/docs"}} =
             Job.new(%{"url" => "https://example.com/docs"}, settings())

    assert {:ok, %Job{url: "http://example.com/docs"}} =
             Job.new(%{"url" => "http://example.com/docs"}, settings())
  end

  test "rejects unsupported protocols and local targets" do
    assert {:error, %{type: "unsupported_protocol"}} =
             Job.new(%{"url" => "file:///etc/passwd"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://localhost:4000"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://127.0.0.1:4000"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://10.0.0.1"}, settings())
  end

  test "rejects IPv4-mapped IPv6 targets" do
    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[::ffff:127.0.0.1]/"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[::ffff:10.0.0.1]/"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[::ffff:8.8.8.8]/"}, settings())
  end

  test "rejects unspecified and IPv4-compatible local targets" do
    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://0.0.0.0:4000"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[::]/"}, settings())

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[::127.0.0.1]/"}, settings())
  end

  test "rejects special-use IPv4 and IPv6 targets" do
    blocked_urls = [
      {"CGNAT", "http://100.64.0.1/"},
      {"benchmark IPv4", "http://198.18.0.1/"},
      {"IPv4 multicast", "http://224.0.0.1/"},
      {"reserved IPv4", "http://240.0.0.1/"},
      {"IPv4 broadcast", "http://255.255.255.255/"},
      {"IPv6 multicast", "http://[ff02::1]/"},
      {"NAT64 well-known prefix", "http://[64:ff9b::7f00:1]/"},
      {"NAT64 local-use prefix", "http://[64:ff9b:1::1]/"},
      {"IPv6 discard-only", "http://[100::]/"},
      {"IPv6 dummy prefix", "http://[100:0:0:1::1]/"},
      {"Teredo/special-use", "http://[2001::]/"},
      {"Port Control Protocol anycast", "http://[2001:1::1]/"},
      {"Traversal Using Relays around NAT anycast", "http://[2001:1::2]/"},
      {"DNS-SD service registration protocol anycast", "http://[2001:1::3]/"},
      {"AMT IPv6", "http://[2001:3::1]/"},
      {"AS112-v6", "http://[2001:4:112::1]/"},
      {"6to4", "http://[2002:0a00:0001::]/"},
      {"ORCHID", "http://[2001:10::1]/"},
      {"ORCHIDv2", "http://[2001:20::1]/"},
      {"Drone Remote ID Protocol Entity Tags", "http://[2001:30::1]/"},
      {"Direct Delegation AS112 Service", "http://[2620:4f:8000::1]/"},
      {"IPv6 documentation prefix", "http://[3fff::1]/"},
      {"Segment Routing SIDs", "http://[5f00::1]/"},
      {"6to4 relay anycast", "http://192.88.99.1/"},
      {"AS112-v4", "http://192.31.196.1/"},
      {"AMT", "http://192.52.193.1/"},
      {"Direct Delegation AS112", "http://192.175.48.1/"}
    ]

    for {label, url} <- blocked_urls do
      assert {:error, %{type: "blocked_target"}} = Job.new(%{"url" => url}, settings()),
             "#{label} should be blocked"
    end
  end

  test "rejects malformed and out-of-range URL ports" do
    invalid_urls = [
      "https://example.com:bad/",
      "https://example.com:-1/",
      "http://example.com:0/",
      "https://example.com:99999/",
      "https://example.com:/"
    ]

    for url <- invalid_urls do
      assert {:error, %{type: "invalid_url", retryable: false}} =
               Job.new(%{"url" => url}, settings())
    end
  end

  test "rejects IPv6 link-local targets" do
    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[fe80::1]/"}, settings())
  end

  test "accepts hostnames resolving to public addresses" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.PublicResolver)

    assert {:ok, %Job{url: "https://public.example/docs"}} =
             Job.new(%{"url" => "https://public.example/docs"}, settings())
  end

  test "rejects hostnames resolving to blocked addresses" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.PrivateResolver)

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "https://private.example/docs"}, settings())
  end

  test "rejects hostnames resolving to IPv4-mapped private IPv6 addresses" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.MappedPrivateResolver)

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "https://mapped-private.example/docs"}, settings())
  end

  test "rejects localhost domains without DNS resolution" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.NoDnsResolver)

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "https://service.localhost/docs"}, settings())
  end

  test "treats resolver exceptions as unresolvable hosts" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.RaisingResolver)

    assert {:error, %{type: "unresolvable_host", retryable: true}} =
             Job.new(%{"url" => "https://resolver-raises.example/docs"}, settings())
  end

  test "treats resolver exits as unresolvable hosts" do
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.ExitingResolver)

    assert {:error, %{type: "unresolvable_host", retryable: true}} =
             Job.new(%{"url" => "https://resolver-exits.example/docs"}, settings())
  end

  defp settings do
    GSMLG.Scout.Settings.default_settings()
  end

  defmodule PublicResolver do
    def getaddrs(_host, :inet), do: {:ok, [{93, 184, 216, 34}]}
    def getaddrs(_host, :inet6), do: {:error, :nxdomain}
  end

  defmodule PrivateResolver do
    def getaddrs(_host, :inet), do: {:ok, [{10, 0, 0, 1}]}
    def getaddrs(_host, :inet6), do: {:error, :nxdomain}
  end

  defmodule MappedPrivateResolver do
    def getaddrs(_host, :inet), do: {:error, :nxdomain}
    def getaddrs(_host, :inet6), do: {:ok, [{0, 0, 0, 0, 0, 65_535, 2560, 1}]}
  end

  defmodule NoDnsResolver do
    def getaddrs(_host, _family), do: raise("DNS should not be called")
  end

  defmodule RaisingResolver do
    def getaddrs(_host, _family), do: raise("resolver exploded")
  end

  defmodule ExitingResolver do
    def getaddrs(_host, _family), do: exit(:resolver_exited)
  end
end
