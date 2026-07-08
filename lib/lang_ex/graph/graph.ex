defmodule LangEx.Graph do
  @moduledoc """
  StateGraph builder.

  Constructs a graph definition via a pipeline of `add_node`, `add_edge`,
  and `add_conditional_edges` calls, then compiles it into an executable
  `LangEx.Graph.Compiled`.
  """

  alias LangEx.Graph.Compiled
  alias LangEx.Graph.State

  defstruct nodes: %{},
            edges: %{},
            conditional_edges: %{},
            schema: []

  @type node_fn :: (map() -> map() | LangEx.Command.t())

  @type routing_fn :: (map() -> atom() | String.t())

  @type t :: %__MODULE__{
          nodes: %{atom() => node_fn() | Compiled.t()},
          edges: %{atom() => [atom()]},
          conditional_edges: %{atom() => {routing_fn(), map() | nil}},
          schema: keyword()
        }

  @doc """
  Creates a new graph builder with the given state schema.

  Schema entries are `key: default` or `key: {default, reducer_fn}`.
  """
  @spec new(keyword()) :: t()
  def new(schema \\ []), do: %__MODULE__{schema: schema}

  @doc """
  Adds a named node with its handler function.

  A compiled graph can be used as a node (subgraph). The runtime
  context, streaming events, and interrupts propagate through it, and
  its checkpoints (when it has its own checkpointer) are namespaced
  under `"{thread_id}/{node_name}"`.
  """
  @spec add_node(t(), atom(), node_fn() | Compiled.t()) :: t()
  def add_node(%__MODULE__{} = graph, name, %Compiled{} = subgraph) when is_atom(name) do
    %{graph | nodes: Map.put(graph.nodes, name, subgraph)}
  end

  def add_node(%__MODULE__{} = graph, name, fun) when is_atom(name) and is_function(fun) do
    %{graph | nodes: Map.put(graph.nodes, name, fun)}
  end

  @doc "Adds a fixed edge from `from` to `to`."
  @spec add_edge(t(), atom(), atom()) :: t()
  def add_edge(%__MODULE__{} = graph, from, to) when is_atom(from) and is_atom(to) do
    %{graph | edges: Map.update(graph.edges, from, [to], &(&1 ++ [to]))}
  end

  @doc """
  Chains a list of node names with sequential edges.

      Graph.add_sequence(graph, [:a, :b, :c])
      # equivalent to add_edge(graph, :a, :b) |> add_edge(:b, :c)
  """
  @spec add_sequence(t(), [atom()]) :: t()
  def add_sequence(%__MODULE__{} = graph, nodes) when is_list(nodes) do
    nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [a, b], g -> add_edge(g, a, b) end)
  end

  @doc """
  Adds conditional edges from `source` using a routing function.

  The routing function receives the current state and returns a node name
  (atom or string). An optional `mapping` converts return values to node names.
  """
  @spec add_conditional_edges(t(), atom(), routing_fn(), map() | nil) :: t()
  def add_conditional_edges(%__MODULE__{} = graph, source, routing_fn, mapping \\ nil)
      when is_atom(source) and is_function(routing_fn, 1) do
    %{graph | conditional_edges: Map.put(graph.conditional_edges, source, {routing_fn, mapping})}
  end

  @doc """
  Compiles the graph builder into an executable `CompiledGraph`.

  Options:
  - `:name` - stable graph identifier used in telemetry (`:graph_id`)
  - `:checkpointer` - module implementing `LangEx.Checkpointer` behaviour
  - `:interrupt_before` - node names to pause at before execution
    (static breakpoints; requires a checkpointer to resume)
  - `:interrupt_after` - node names to pause at after execution
  """
  @spec compile(t(), keyword()) :: Compiled.t()
  def compile(%__MODULE__{} = graph, opts \\ []) do
    :ok = validate_entry_point(graph)
    :ok = validate_edge_targets(graph)

    {initial_state, reducers} = State.parse_schema(graph.schema)

    %Compiled{
      name: Keyword.get(opts, :name),
      nodes: graph.nodes,
      edges: graph.edges,
      conditional_edges: graph.conditional_edges,
      initial_state: initial_state,
      reducers: reducers,
      checkpointer: Keyword.get(opts, :checkpointer),
      interrupt_before: Keyword.get(opts, :interrupt_before, []),
      interrupt_after: Keyword.get(opts, :interrupt_after, [])
    }
  end

  defp validate_entry_point(%__MODULE__{edges: %{__start__: _}}), do: :ok
  defp validate_entry_point(%__MODULE__{conditional_edges: %{__start__: _}}), do: :ok

  defp validate_entry_point(_graph) do
    raise ArgumentError,
          "graph must have an edge from :__start__ — use add_edge(:__start__, :first_node)"
  end

  defp validate_edge_targets(%__MODULE__{nodes: nodes, edges: edges}) do
    valid = nodes |> Map.keys() |> MapSet.new() |> MapSet.put(:__start__) |> MapSet.put(:__end__)
    Enum.each(edges, &validate_edge(&1, valid))
    :ok
  end

  defp validate_edge({from, targets}, valid) do
    validate_node_exists!(from, valid, "edge source")
    Enum.each(targets, &validate_node_exists!(&1, valid, "edge target from #{inspect(from)}"))
  end

  defp validate_node_exists!(name, valid, context) do
    valid
    |> MapSet.member?(name)
    |> assert_node_exists!(name, context)
  end

  defp assert_node_exists!(true, _name, _context), do: :ok

  defp assert_node_exists!(false, name, context) do
    raise ArgumentError, "#{context} #{inspect(name)} is not a defined node"
  end
end
