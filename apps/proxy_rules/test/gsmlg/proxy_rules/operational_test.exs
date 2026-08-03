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

    assert proxy_readme =~
             ~r/independent \*\*Add Local Proxy\*\*\s+and \*\*Add Local Direct\*\* forms/

    assert proxy_readme =~
             ~r/Each textarea accepts one domain per line, with\s+an optional single `\.` or `\*\.` prefix that is removed before storage\./

    assert proxy_readme =~ "Validation is atomic"
    assert proxy_readme =~ ~r/duplicates are\s+automatically omitted/

    assert proxy_readme =~
             ~r/Raw\/DNS emits `baidu\.com`,\s+Squid emits\s+`\.baidu\.com`, and Clash emits `DOMAIN-SUFFIX,baidu\.com`\./

    assert proxy_readme =~
             "The same domain may intentionally remain in both local sources."

    assert proxy_readme =~
             ~r/The compiler\s+counts and reports those conflicts, and downstream consumers must\s+continue to\s+evaluate Direct before Proxy\./

    assert proxy_readme =~
             ~r/GFWList, Local\s+Proxy, and Local Direct are all unloaded by default\./

    assert proxy_readme =~ "Clicking **View content**"
    assert proxy_readme =~ "fetches bounded, authenticated pages"
    assert proxy_readme =~ ~r/displays the complete source\s+text in a scrollable `<pre>`\./

    assert proxy_readme =~ "The viewer does not use a virtual list"
    assert proxy_readme =~ "initial HTML does not contain any source body"

    assert proxy_readme =~
             ~r/Both proxy-list\.txt and direct-list\.txt must be\s+readable and writable by the release service identity\./

    for document <- [proxy_readme, deploy_doc] do
      assert document =~ "proxy_root=/etc/gsmlg/proxy-rules"
      assert document =~ "proxy_dir=\"$proxy_root/proxy\""
      assert document =~ "proxy_target=\"$proxy_dir/proxy-list.txt\""
      assert document =~ "direct_dir=\"$proxy_root/direct\""
      assert document =~ "direct_target=\"$direct_dir/direct-list.txt\""

      assert document =~
               "sudo install -d -o root -g gsmlg -m 0750 -- \"$proxy_root\""

      assert document =~ "sudo systemctl stop gsmlg-umbrella.service"
      assert document =~ "if [ -L \"$proxy_dir\" ]; then"
      assert document =~ "elif [ ! -e \"$proxy_dir\" ]; then"

      assert document =~
               "if [ -L \"$legacy_proxy\" ] || " <>
                 "{ [ -e \"$legacy_proxy\" ] && [ ! -f \"$legacy_proxy\" ]; }; then"

      assert document =~
               "if [ -L \"$proxy_target\" ] || [ ! -f \"$proxy_target\" ]; then"

      assert document =~
               "# Existing service-writable directory: validation only; " <>
                 "no privileged entry mutation."

      assert document =~
               "Manual repair required: Local proxy source is missing, a symlink, or non-regular"

      assert document =~
               "Manual conflict: both legacy and separated Local proxy sources exist"

      assert document =~
               "if ! sudo -u gsmlg sh -c '\n" <>
                 "    test -x \"$1\" &&\n" <>
                 "    test -w \"$1\" &&\n" <>
                 "    test -r \"$2\" &&\n" <>
                 "    test -w \"$2\"\n" <>
                 "  ' proxy-rules-permission-probe \"$proxy_dir\" \"$proxy_target\"; then"

      assert document =~
               "Manual repair required: Local proxy directory/source permissions do not " <>
                 "allow gsmlg atomic replacement"

      assert document =~ "if [ -L \"$direct_dir\" ]; then"
      assert document =~ "elif [ ! -e \"$direct_dir\" ]; then"

      assert document =~
               "if [ -L \"$legacy_direct\" ] || " <>
                 "{ [ -e \"$legacy_direct\" ] && [ ! -f \"$legacy_direct\" ]; }; then"

      assert document =~
               "if [ -L \"$direct_target\" ] || [ ! -f \"$direct_target\" ]; then"

      assert document =~
               "Manual repair required: Local direct source is missing, a symlink, or non-regular"

      assert document =~
               "Manual conflict: both legacy and separated Local direct sources exist"

      assert document =~
               "if ! sudo -u gsmlg sh -c '\n" <>
                 "    test -x \"$1\" &&\n" <>
                 "    test -w \"$1\" &&\n" <>
                 "    test -r \"$2\" &&\n" <>
                 "    test -w \"$2\"\n" <>
                 "  ' proxy-rules-permission-probe \"$direct_dir\" \"$direct_target\"; then"

      assert document =~
               "Manual repair required: Local direct directory/source permissions do not " <>
                 "allow gsmlg atomic replacement"

      root_dir_setup =
        :binary.match(document, "sudo install -d -o root -g gsmlg -m 0750 -- \"$proxy_dir\"")

      file_owner_setup = :binary.match(document, "sudo chown gsmlg:gsmlg -- \"$proxy_target\"")
      service_dir_setup = :binary.match(document, "sudo chown gsmlg:gsmlg -- \"$proxy_dir\"")

      assert {root_dir_offset, _length} = root_dir_setup
      assert {file_owner_offset, _length} = file_owner_setup
      assert {service_dir_offset, _length} = service_dir_setup
      assert root_dir_offset < file_owner_offset
      assert file_owner_offset < service_dir_offset

      direct_root_dir_setup =
        :binary.match(document, "sudo install -d -o root -g gsmlg -m 0750 -- \"$direct_dir\"")

      direct_file_owner_setup =
        :binary.match(document, "sudo chown gsmlg:gsmlg -- \"$direct_target\"")

      direct_service_dir_setup =
        :binary.match(document, "sudo chown gsmlg:gsmlg -- \"$direct_dir\"")

      assert {direct_root_dir_offset, _length} = direct_root_dir_setup
      assert {direct_file_owner_offset, _length} = direct_file_owner_setup
      assert {direct_service_dir_offset, _length} = direct_service_dir_setup
      assert direct_root_dir_offset < direct_file_owner_offset
      assert direct_file_owner_offset < direct_service_dir_offset

      refute document =~
               "sudo install -o gsmlg -g gsmlg -m 0640 proxy-list.txt"

      refute document =~
               "sudo chown gsmlg:gsmlg /etc/gsmlg/proxy-rules/proxy/proxy-list.txt"

      refute document =~
               "sudo chmod 0640 /etc/gsmlg/proxy-rules/proxy/proxy-list.txt"

      assert document =~
               ~s(local_proxy_list_path = "/etc/gsmlg/proxy-rules/proxy/proxy-list.txt")

      assert document =~
               ~s(local_direct_list_path = "/etc/gsmlg/proxy-rules/direct/direct-list.txt")

      assert document =~
               ~r/Stop the service before replacing either source externally, or otherwise\s+serialize the edit with admin mutations\./

      assert document =~
               "if sudo --user=gsmlg --group=gsmlg -- sh -c '\n" <>
                 "  set -eu\n" <>
                 "  source=$1\n" <>
                 "  target=$2\n" <>
                 "  target_dir=${target%/*}\n" <>
                 "  tmp=$(mktemp \"$target_dir/.proxy-rules.external.XXXXXX\")\n" <>
                 "  cleanup() { rm -f -- \"$tmp\"; }\n" <>
                 "  trap cleanup EXIT HUP INT TERM\n" <>
                 "  cat -- \"$source\" >\"$tmp\"\n" <>
                 "  chmod 0640 -- \"$tmp\"\n" <>
                 "  mv -f -- \"$tmp\" \"$target\"\n" <>
                 "  trap - EXIT HUP INT TERM\n" <>
                 "' proxy-rules-external-update /path/to/updated-list.txt \"$target\"; then\n" <>
                 "  sudo systemctl start gsmlg-umbrella.service\n" <>
                 "else\n" <>
                 "  echo \"Replacement failed; service remains stopped\" >&2\n" <>
                 "fi"

      assert document =~
               ~r/Running the replacement as `gsmlg:gsmlg` and setting mode `0640` before\s+the\s+rename keeps the resulting target readable and writable by the service\./
    end

    assert deploy_doc =~
             ~r/Mount both configured local source directories read\/write so same-directory\s+temporary-file creation and atomic rename can succeed\./

    assert deploy_doc =~ "Do not make either source writable by untrusted users."

    assert deploy_doc =~
             ~r/The current Docker images do not set `USER`, so the release runs as root\s+in the\s+container by default\./

    assert deploy_doc =~
             ~r/The `gsmlg` ownership above applies to the tarball service\./

    assert deploy_doc =~
             "-v /etc/gsmlg/proxy-rules/proxy:" <>
               "/etc/gsmlg/proxy-rules/proxy \\\n"

    assert deploy_doc =~
             "-v /etc/gsmlg/proxy-rules/direct:" <>
               "/etc/gsmlg/proxy-rules/direct \\\n"

    refute deploy_doc =~
             "-v /etc/gsmlg/proxy-rules/proxy-list.txt:"

    refute deploy_doc =~
             "sudo install -d -o gsmlg -g gsmlg -m 0750 /etc/gsmlg/proxy-rules\n"

    refute deploy_doc =~
             "-v /etc/gsmlg/proxy-rules:/etc/gsmlg/proxy-rules"

    assert proxy_readme =~
             ~r/Admin-added entries are stored as canonical bare domains\. Existing semantic\s+entries and comments are retained, while mutation normalizes line endings,\s+trailing\s+spaces, and trailing blank lines\. Renderers normalize parsed rules for\s+Raw\/DNS,\s+Squid, and Clash output\./
  end

  @tag :tmp_dir
  test "documented upgrade guards reject hostile links and insufficient permissions", %{
    tmp_dir: tmp_dir
  } do
    sentinel = "/etc/hosts"
    sentinel_before = File.stat!(sentinel)
    contents_before = File.read!(sentinel)
    target = Path.join(tmp_dir, "proxy-list.txt")

    assert sentinel_before.uid == 0
    File.ln_s!(sentinel, target)

    {_output, exit_status} =
      System.cmd(
        "sh",
        [
          "-c",
          """
          target=$1
          if [ -L "$target" ] || [ ! -f "$target" ]; then
            exit 73
          fi
          chmod 0640 "$target"
          """,
          "proxy-rules-upgrade-guard",
          target
        ],
        stderr_to_stdout: true
      )

    assert exit_status == 73
    assert File.read!(sentinel) == contents_before

    sentinel_after = File.stat!(sentinel)
    assert sentinel_after.uid == sentinel_before.uid
    assert sentinel_after.gid == sentinel_before.gid
    assert Bitwise.band(sentinel_after.mode, 0o7777) == Bitwise.band(sentinel_before.mode, 0o7777)

    permission_dir = Path.join(tmp_dir, "permission-probe")
    permission_target = Path.join(permission_dir, "proxy-list.txt")
    File.mkdir!(permission_dir)
    File.write!(permission_target, "example.com\n")
    File.chmod!(permission_dir, 0o700)
    File.chmod!(permission_target, 0o600)

    probe = "test -x \"$1\" && test -w \"$1\" && test -r \"$2\" && test -w \"$2\""

    assert {_output, 0} =
             System.cmd("sh", [
               "-c",
               probe,
               "proxy-rules-permission-probe",
               permission_dir,
               permission_target
             ])

    try do
      File.chmod!(permission_dir, 0o500)

      assert {_output, 1} =
               System.cmd("sh", [
                 "-c",
                 probe,
                 "proxy-rules-permission-probe",
                 permission_dir,
                 permission_target
               ])
    after
      File.chmod!(permission_dir, 0o700)
    end
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
