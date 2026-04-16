defmodule ExCodeRemote.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_code_remote,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExCodeRemote.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.17"},
      {:ex_mcp, "== 0.9.1"},
      {:jason, "~> 1.4"},
      {:websock_adapter, "~> 0.5"}
    ]
  end
end
