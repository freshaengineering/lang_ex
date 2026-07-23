defmodule LangEx.MixProject do
  use Mix.Project

  @version "0.11.2"
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
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Graph: [
          LangEx.Graph,
          LangEx.Graph.Compiled,
          LangEx.Graph.RetryPolicy,
          LangEx.Graph.State,
          LangEx.Graph.Stream
        ],
        "Control Flow": [
          LangEx.Command,
          LangEx.Interrupt,
          LangEx.Send
        ],
        Errors: [
          LangEx.NodeError,
          LangEx.NodeTimeoutError
        ],
        Checkpointing: [
          LangEx.Checkpoint,
          LangEx.Checkpoint.Serializer,
          LangEx.Checkpointer,
          LangEx.Checkpointer.Memory,
          LangEx.Checkpointer.Postgres,
          LangEx.Checkpointer.Redis,
          LangEx.Migration
        ],
        Store: [
          LangEx.Store,
          LangEx.Store.ETS,
          LangEx.Store.Postgres
        ],
        Messages: [
          LangEx.Message,
          LangEx.MessagesState
        ],
        LLM: [
          LangEx.LLM,
          LangEx.LLM.Anthropic,
          LangEx.LLM.ChatModel,
          LangEx.LLM.Gemini,
          LangEx.LLM.OpenAI,
          LangEx.LLM.Registry,
          LangEx.LLM.Resilient
        ],
        Tools: [
          LangEx.Tool,
          LangEx.Tool.Annotation,
          LangEx.Tool.Node
        ],
        Embeddings: [
          LangEx.Embedding.Hashing
        ],
        "Multi-Agent": [
          LangEx.Prebuilt.Handoff,
          LangEx.Prebuilt.Member,
          LangEx.Prebuilt.Supervisor,
          LangEx.Prebuilt.Swarm
        ],
        Observability: [
          LangEx.Telemetry,
          LangEx.Telemetry.OpenTelemetryBridge,
          LangEx.Telemetry.Runs
        ]
      ]
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
