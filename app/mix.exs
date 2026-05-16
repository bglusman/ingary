defmodule Wardwright.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardwright,
      version: "0.1.0",
      elixir: "~> 1.17",
      compilers: [:gleam] ++ Mix.compilers(),
      aliases: ["deps.get": ["deps.get", "gleam.deps.get"]],
      erlc_paths: [
        "build/dev/erlang/wardwright/_gleam_artefacts",
        "build/dev/erlang/wardwright/build"
      ],
      erlc_include_path: "build/dev/erlang/wardwright/include",
      prune_code_paths: false,
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:lazy_html, ">= 0.1.0", only: :test},
      {:muex, "~> 0.6.1", only: :test},
      {:stream_data, "~> 1.3", only: :test}
    ]
  end
end
