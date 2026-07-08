defmodule LangEx.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/surgeventures/lang_ex"

  def project do
    [
      app: :lang_ex,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "LangEx",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      mod: {LangEx.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Graph-based agent orchestration for building stateful, multi-step LLM workflows " <>
      "with nodes, edges, conditional routing, state reducers, human-in-the-loop interrupts, " <>
      "and checkpointing. Inspired by LangGraph, built on BEAM primitives."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:redix, "~> 1.5", optional: true},
      {:postgrex, "~> 0.19", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:opentelemetry_api, "~> 1.2", optional: true},
      {:opentelemetry_telemetry, "~> 1.1", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:mimic, "~> 1.10", only: :test}
    ]
  end
end
