defmodule GSMLG.ProxyRules.OperationalTest do
  use ExUnit.Case, async: true

  @application_root Path.expand("../../..", __DIR__)
  @umbrella_root Path.expand("../..", @application_root)
  @runtime_directories ["/etc/gsmlg/proxy-rules", "/var/lib/gsmlg/proxy-rules"]

  test "all Docker runtime images create and persist the proxy-rules directories" do
    for dockerfile <- ~w(Dockerfile Dockerfile.alpine Dockerfile.lite) do
      contents = File.read!(Path.join(@umbrella_root, dockerfile))
      runtime_stage = contents |> String.split(~r/^FROM /m) |> List.last()

      mkdir_command =
        runtime_stage
        |> String.split("\n")
        |> Enum.find(fn line ->
          String.starts_with?(String.trim_leading(line), ["mkdir -p", "&& mkdir -p"])
        end)

      volume_command = runtime_stage |> String.split("\n") |> Enum.find(&(&1 =~ ~r/^VOLUME /))

      assert is_binary(mkdir_command), "#{dockerfile} runtime stage must run mkdir -p"

      assert runtime_stage =~ ~r/(?:apt-get install|apk add)[^\n]*\binotify-tools\b/,
             "#{dockerfile} runtime stage must install inotify-tools for FileSystem"

      for directory <- @runtime_directories do
        assert mkdir_command =~ directory,
               "#{dockerfile} runtime mkdir command must create #{directory}"
      end

      assert volume_command =~ "/var/lib/gsmlg/proxy-rules",
             "#{dockerfile} must declare the proxy-rules state directory as a volume"
    end
  end

  test "tarball and systemd deployment protect proxy-rules configuration and state" do
    deploy = File.read!(Path.join(@umbrella_root, "docs/deploy.md"))

    account_setup = :binary.match(deploy, "sudo groupadd --system gsmlg")
    user_setup = :binary.match(deploy, "sudo useradd --system --gid gsmlg")
    directory_setup = :binary.match(deploy, "sudo install -d -o root -g gsmlg -m 0750 /etc/gsmlg")

    assert {account_offset, _length} = account_setup
    assert {user_offset, _length} = user_setup
    assert {directory_offset, _length} = directory_setup
    assert account_offset < directory_offset
    assert user_offset < directory_offset

    assert deploy =~
             "sudo install -o root -g gsmlg -m 0640 /path/to/gsmlg_umbrella.toml " <>
               "/etc/gsmlg/gsmlg_umbrella.toml"

    assert deploy =~
             "ConfigurationDirectory=gsmlg/proxy-rules\n" <>
               "ConfigurationDirectoryMode=0750\n" <>
               "StateDirectory=gsmlg/proxy-rules\n" <>
               "StateDirectoryMode=0750"

    assert deploy =~
             "sudo --user=gsmlg --group=gsmlg -- \\\n" <>
               "  env GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml"

    assert deploy =~ "/opt/gsmlg/gsmlg/bin/gsmlg_umbrella start"

    assert deploy =~
             "sudo --set-home --user=gsmlg --group=gsmlg -- \\\n" <>
               "  /opt/gsmlg/commander/bin/gsmlg_commander start"

    assert deploy =~
             "sudo --user=gsmlg --group=gsmlg -- \\\n" <>
               "  env GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_scout_agent.toml \\\n" <>
               "  /opt/gsmlg/gsmlg_scout_agent/bin/gsmlg_scout_agent start"

    assert deploy =~
             "sudo install -d -o gsmlg -g gsmlg -m 0750 /var/lib/mnesia /var/log/gsmlg"

    assert deploy =~
             "sudo --user=gsmlg --group=gsmlg -- \\\n" <>
               "  env GSMLG_CONFIG_PATH=/etc/gsmlg/gsmlg_umbrella.toml \\\n" <>
               "  /opt/gsmlg/gsmlg/bin/gsmlg_umbrella eval \"GSMLG.Release.migrate()\""

    refute deploy =~
             ~r/sudo GSMLG_CONFIG_PATH=.*\n(?:.*\\\n){0,5}\s*\/opt\/gsmlg\/gsmlg\/bin\/gsmlg_umbrella (?:start|daemon)/
  end

  test "documentation defines the authenticated admin source-management boundary" do
    proxy_readme = File.read!(Path.join(@application_root, "README.md"))
    deploy_doc = File.read!(Path.join(@umbrella_root, "docs/deploy.md"))

    assert proxy_readme =~ "The admin textarea accepts bare domains only, one per line."
    assert proxy_readme =~ "Validation is atomic"
    assert proxy_readme =~ "duplicates are automatically omitted"

    assert proxy_readme =~
             ~r/Raw\/DNS emits `baidu\.com`, Squid emits\s+`\.baidu\.com`, and Clash emits `DOMAIN-SUFFIX,baidu\.com`\./

    assert proxy_readme =~
             "GFWList content is decoded, lazy-loaded, authenticated, and virtualized."

    assert proxy_readme =~
             ~r/Local direct remains outside the\s+admin interface: it cannot be viewed or edited\./

    assert proxy_readme =~
             "proxy-list.txt must be writable by the release service identity"

    assert proxy_readme =~
             "direct-list.txt remains operator-owned and read-only to the release service identity"

    for document <- [proxy_readme, deploy_doc] do
      assert document =~
               "sudo install -d -o root -g gsmlg -m 0750 /etc/gsmlg/proxy-rules\n"

      assert document =~
               "sudo install -d -o gsmlg -g gsmlg -m 0750 " <>
                 "/etc/gsmlg/proxy-rules/proxy"

      assert document =~
               "sudo install -d -o root -g gsmlg -m 0750 " <>
                 "/etc/gsmlg/proxy-rules/direct"

      assert document =~
               "sudo install -o gsmlg -g gsmlg -m 0640 proxy-list.txt \\\n" <>
                 "  /etc/gsmlg/proxy-rules/proxy/proxy-list.txt"

      assert document =~
               "sudo install -o root -g gsmlg -m 0640 direct-list.txt \\\n" <>
                 "  /etc/gsmlg/proxy-rules/direct/direct-list.txt"

      assert document =~
               ~s(local_proxy_list_path = "/etc/gsmlg/proxy-rules/proxy/proxy-list.txt")

      assert document =~
               ~s(local_direct_list_path = "/etc/gsmlg/proxy-rules/direct/direct-list.txt")
    end

    assert deploy_doc =~
             ~r/Mount the configured Local proxy directory read\/write so atomic sibling\s+temporary-file creation and rename can succeed\./

    assert deploy_doc =~
             "Mount the configured Local direct directory read-only."

    assert deploy_doc =~
             "-v /etc/gsmlg/proxy-rules/proxy:" <>
               "/etc/gsmlg/proxy-rules/proxy \\\n"

    assert deploy_doc =~
             "-v /etc/gsmlg/proxy-rules/direct:" <>
               "/etc/gsmlg/proxy-rules/direct:ro \\\n"

    refute deploy_doc =~
             "-v /etc/gsmlg/proxy-rules/proxy-list.txt:"

    refute deploy_doc =~
             "sudo install -d -o gsmlg -g gsmlg -m 0750 /etc/gsmlg/proxy-rules\n"

    refute deploy_doc =~
             "-v /etc/gsmlg/proxy-rules:/etc/gsmlg/proxy-rules"
  end

  test "one benchmark compilation reports positive operational measurements" do
    Code.require_file(Path.join(@application_root, "bench/proxy_rules_benchmark.exs"))

    assert %{
             compile_mean_ms: compile_mean_ms,
             artifact_bytes: artifact_bytes,
             lookup_ops_per_second: lookup_ops_per_second
           } =
             apply(GSMLG.ProxyRules.Benchmark, :run, [
               [iterations: 1, lookup_iterations: 100_000]
             ])

    assert compile_mean_ms > 0
    assert artifact_bytes > 0
    assert lookup_ops_per_second > 0
  end
end
