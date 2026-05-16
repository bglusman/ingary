defmodule Wardwright.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardwright,
      version: "0.0.2",
      elixir: "~> 1.17",
      compilers: [:gleam] ++ Mix.compilers(),
      aliases: ["deps.get": ["deps.get", "gleam.deps.get"]],
      erlc_paths: [
        "_build/#{Mix.env()}/lib/wardwright/_gleam_artefacts"
      ],
      erlc_include_path: "_build/#{Mix.env()}/lib/wardwright/include",
      prune_code_paths: false,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      tinfoil: [
        targets: [:darwin_arm64, :darwin_x86_64, :linux_x86_64, :linux_arm64],
        github: [
          repo: "bglusman/wardwright"
        ],
        homebrew: [
          enabled: true,
          tap: "bglusman/homebrew-tap",
          formula_name: "wardwright"
        ],
        installer: [
          enabled: true
        ],
        ci: [
          elixir_version: "1.19",
          otp_version: "28"
        ],
        prerelease_pattern: ~r/-(rc|beta|alpha|dev)(\.|$)/
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Wardwright.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:dune, "~> 0.3.15"},
      {:gleam_stdlib, "~> 1.0", compile: false, app: false},
      {:mix_gleam, "~> 0.6", runtime: false},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug_cowboy, "~> 2.7"},
      {:hermes_mcp, "~> 0.14.1"},
      {:burrito, "~> 1.5", runtime: false},
      {:tinfoil, "~> 0.2", runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:muex, "~> 0.6.1", only: :test},
      {:stream_data, "~> 1.3", only: :test}
    ]
  end

  defp releases do
    [
      wardwright: [
        include_executables_for: [],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            darwin_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
end
