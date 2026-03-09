defmodule GSMLG.Umbrella.MixProject do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      coveralls: [minimum_coverage: 0],
      listeners: [Phoenix.CodeReloader],
      releases: [
        gsmlg_commander: [
          include_executables_for: [:unix],
          steps: [:assemble, :tar],
          applications: [
            gsmlg_commander: :permanent
          ],
          config_providers: [
            {Toml.Provider,
             [
               path: {:system, "GSMLG_CONFIG_PATH", ""},
               transforms: []
             ]}
          ]
        ],
        gsmlg_umbrella: [
          include_executables_for: [:unix],
          steps: [&build_assets/1, :assemble, :tar],
          applications: [
            gsmlg: :permanent,
            gsmlg_admin_web: :permanent,
            gsmlg_web: :permanent
          ],
          config_providers: [
            {Toml.Provider,
             [
               path: {:system, "GSMLG_CONFIG_PATH", ""},
               transforms: []
             ]}
          ]
        ],
        gsmlg_umbrella_standalone: [
          applications: [
            gsmlg: :permanent,
            gsmlg_admin_web: :permanent,
            gsmlg_web: :permanent
          ],
          steps: [&build_assets/1, :assemble, &Burrito.wrap/1],
          burrito: [
            targets: [
              linux_amd64: [
                os: :linux,
                cpu: :x86_64,
                custom_erts:
                  "https://github.com/Gao-OS/otp-release/releases/download/main/OTP-27.1.2-linux-amd64.tar.gz"
              ]
            ]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.0", runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.0"},
      {:telemetry, "~> 1.0", override: true}
    ]
  end

  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      prerelease: [&build_assets/1]
    ]
  end

  defp build_assets(release) do
    # File.cd(Path.expand("apps/gsmlg_component", __DIR__))
    IO.puts("Building component for #{inspect(release)}...")

    {output, exit_status} =
      System.cmd(
        "mix",
        [
          "phx.react.bun.bundle",
          "--component-base=assets/component",
          "--output=priv/server.js"
        ],
        cd: Path.expand("apps/gsmlg_component", __DIR__)
      )

    if exit_status != 0 do
      IO.puts("Error building component for #{inspect(release)}: #{output}")
      raise "Failed to build component"
    end

    IO.puts(output)

    IO.puts("Building gsmlg_web for #{inspect(release)}...")
    # File.cd(Path.expand("apps/gsmlg_web", __DIR__))
    {output, exit_status} =
      System.cmd("mix", ["assets.deploy"], cd: Path.expand("apps/gsmlg_web", __DIR__))

    if exit_status != 0 do
      IO.puts("Error building gsmlg_web for #{inspect(release)}: #{output}")
      raise "Failed to build gsmlg_web"
    end

    IO.puts(output)

    IO.puts("Building gsmlg_admin_web for #{inspect(release)}...")
    # File.cd(Path.expand("apps/gsmlg_admin_web", __DIR__))
    {output, exit_status} =
      System.cmd("mix", ["assets.deploy"], cd: Path.expand("apps/gsmlg_admin_web", __DIR__))

    if exit_status != 0 do
      IO.puts("Error building gsmlg_admin_web for #{inspect(release)}: #{output}")
      raise "Failed to build gsmlg_admin_web"
    end

    IO.puts(output)

    release
  end
end
