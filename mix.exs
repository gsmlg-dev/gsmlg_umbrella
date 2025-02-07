defmodule GSMLG.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.0.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [
        gsmlg_commander: [
          applications: [
            gsmlg_commander: :permanent
          ]
        ],
        gsmlg_umbrella: [
          applications: [
            gsmlg: :permanent,
            gsmlg_admin_web: :permanent,
            gsmlg_web: :permanent
          ]
        ],
        gsmlg_umbrella_standalone: [
          applications: [
            gsmlg: :permanent,
            gsmlg_admin_web: :permanent,
            gsmlg_web: :permanent
          ],
          steps: [:assemble, &Burrito.wrap/1],
          burrito: [
            targets: [
              linux_arm64: [os: :linux, cpu: :aarch64],
              linux_amd64: [os: :linux, cpu: :x86_64]
            ]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.0", runtime: false},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"]
    ]
  end
end
