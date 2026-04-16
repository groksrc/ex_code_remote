defmodule ExCodeRemote.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_code_remote,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExCodeRemote.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp releases do
    [
      ex_code_remote: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug_cowboy, "~> 2.8"},
      {:plug, "~> 1.17"},
      {:ex_mcp, "== 0.9.1"},
      {:jason, "~> 1.4"},
      {:websock_adapter, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:telemetry_metrics, "~> 1.0"},
      {:logger_json, "~> 6.0"}
    ]
  end
end
