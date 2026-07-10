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
            node_opts: %{},
            edges: %{},
            conditional_edges: %{},
            schema: []

  @type node_fn :: (map() -> map() | LangEx.Command.t())

  @type node_opt ::
          {:retry, keyword() | true}
          | {:cache, keyword() | true}
          | {:defer, boolean()}
          | {:timeout, pos_integer()}
          | {:on_error, (Exception.t(), map() -> map() | LangEx.Command.t())}

  @type routing_fn :: (map() -> atom() | String.t())

  @type t :: %__MODULE__{
          nodes: %{atom() => node_fn() | Compiled.t()},
          node_opts: %{atom() => [node_opt()]},
          edges: %{atom() => [atom()]},
          conditional_edges: %{atom() => {routing_fn(), map() | nil}},
          schema: keyword()
        }

  @node_opt_keys [:retry, :cache, :defer, :timeout, :on_error]
  @reserved_names [:__start__, :__end__]

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

  ## Execution policy options

  - `:retry` - retry the node on exceptions. `true` for defaults, or a
    keyword list — see `LangEx.Graph.RetryPolicy` for options
    (`max_attempts:`, `initial_interval_ms:`, `backoff_factor:`,
    `max_interval_ms:`, `jitter:`, `retryable?:`).
  - `:cache` - memoize successful results keyed by the node's input
    state. `true` for no expiry, or `[ttl: milliseconds]`. Cannot be
    combined with `:on_error`.
  - `:defer` - when `true`, the node runs only once no other
    (non-deferred) nodes are active — a fan-in barrier for parallel
    branches that converge at different depths.
  - `:timeout` - per-attempt time budget in milliseconds. A timed-out
    attempt raises `LangEx.NodeTimeoutError`, which the retry policy
    can retry; when exhausted it surfaces as `{:error, %LangEx.NodeError{}}`.
  - `:on_error` - `fn exception, state -> update end` invoked after the
    retry policy is exhausted; its return value becomes the node result
    (a state update map or `%LangEx.Command{}`). Failures inside the
    handler propagate.
  """
  @spec add_node(t(), atom(), node_fn() | Compiled.t(), [node_opt()]) :: t()
  def add_node(graph, name, node_value, node_opts \\ [])

  def add_node(%__MODULE__{} = graph, name, %Compiled{} = subgraph, node_opts)
      when is_atom(name) do
    graph
    |> put_node(name, subgraph)
    |> put_node_opts(name, node_opts)
  end

  def add_node(%__MODULE__{} = graph, name, fun, node_opts)
      when is_atom(name) and is_function(fun) do
    graph
    |> put_node(name, fun)
    |> put_node_opts(name, node_opts)
  end

  defp put_node(graph, name, value) do
    :ok = validate_node_name!(graph, name)
    %{graph | nodes: Map.put(graph.nodes, name, value)}
  end

  defp validate_node_name!(_graph, name) when name in @reserved_names do
    raise ArgumentError,
          "#{inspect(name)} is a reserved node name — " <>
            "graphs start at :__start__ and finish at :__end__ implicitly"
  end

  defp validate_node_name!(%__MODULE__{nodes: nodes}, name) when is_map_key(nodes, name) do
    raise ArgumentError,
          "node #{inspect(name)} is already defined — node names must be unique"
  end

  defp validate_node_name!(_graph, _name), do: :ok

  defp put_node_opts(graph, _name, []), do: graph

  defp put_node_opts(graph, name, node_opts) do
    :ok = validate_node_opts!(name, node_opts)
    %{graph | node_opts: Map.put(graph.node_opts, name, node_opts)}
  end

  defp validate_node_opts!(name, node_opts) do
    node_opts
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @node_opt_keys))
    |> assert_no_unknown_opts!(name)

    Enum.each(node_opts, &validate_node_opt!(name, &1))
    assert_compatible_opts!(name, node_opts)
  end

  defp assert_no_unknown_opts!([], _name), do: :ok

  defp assert_no_unknown_opts!(unknown, name) do
    raise ArgumentError,
          "unknown node option(s) #{inspect(unknown)} for #{inspect(name)} — " <>
            "supported: #{inspect(@node_opt_keys)}"
  end

  defp validate_node_opt!(_name, {:retry, value}) when value == true or is_list(value), do: :ok
  defp validate_node_opt!(_name, {:cache, value}) when value == true or is_list(value), do: :ok
  defp validate_node_opt!(_name, {:defer, value}) when is_boolean(value), do: :ok

  defp validate_node_opt!(_name, {:timeout, value}) when is_integer(value) and value > 0,
    do: :ok

  defp validate_node_opt!(_name, {:on_error, handler}) when is_function(handler, 2), do: :ok

  defp validate_node_opt!(name, {key, value}) do
    raise ArgumentError,
          "invalid value #{inspect(value)} for node option #{inspect(key)} on #{inspect(name)}"
  end

  defp assert_compatible_opts!(name, node_opts) do
    node_opts
    |> Keyword.has_key?(:cache)
    |> Kernel.and(Keyword.has_key?(node_opts, :on_error))
    |> assert_no_cache_with_handler!(name)
  end

  defp assert_no_cache_with_handler!(false, _name), do: :ok

  defp assert_no_cache_with_handler!(true, name) do
    raise ArgumentError,
          "node #{inspect(name)} combines :cache with :on_error — " <>
            "caching error-handler results is unsafe"
  end

  @doc "Adds a fixed edge from `from` to `to`."
  @spec add_edge(t(), atom(), atom()) :: t()
  def add_edge(%__MODULE__{}, :__end__, _to) do
    raise ArgumentError, ":__end__ is terminal — edges cannot start from it"
  end

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
    :ok = validate_conditional_source!(graph, source)
    %{graph | conditional_edges: Map.put(graph.conditional_edges, source, {routing_fn, mapping})}
  end

  defp validate_conditional_source!(%__MODULE__{conditional_edges: existing}, source)
       when is_map_key(existing, source) do
    raise ArgumentError,
          "conditional edges from #{inspect(source)} are already defined — " <>
            "a node has at most one routing function"
  end

  defp validate_conditional_source!(_graph, _source), do: :ok

  @doc """
  Compiles the graph builder into an executable `CompiledGraph`.

  Options:
  - `:name` - stable graph identifier used in telemetry (`:graph_id`)
  - `:checkpointer` - module implementing `LangEx.Checkpointer` behaviour
  - `:store` - long-term memory backend, `Module` or `{Module, config}`
    (see `LangEx.Store`)
  - `:interrupt_before` - node names to pause at before execution
    (static breakpoints; requires a checkpointer to resume)
  - `:interrupt_after` - node names to pause at after execution
  - `:warn_unreachable` - warn about nodes not reachable via declared
    edges (default `true`; disable for graphs routed via Command goto)
  """
  @spec compile(t(), keyword()) :: Compiled.t()
  def compile(%__MODULE__{} = graph, opts \\ []) do
    :ok = validate_entry_point(graph)
    :ok = validate_edge_targets(graph)
    :ok = validate_conditional_targets(graph)
    :ok = validate_breakpoints(graph, opts, :interrupt_before)
    :ok = validate_breakpoints(graph, opts, :interrupt_after)
    :ok = warn_on_unreachable_nodes(graph, Keyword.get(opts, :warn_unreachable, true))

    {initial_state, reducers} = State.parse_schema(graph.schema)

    %Compiled{
      name: Keyword.get(opts, :name),
      nodes: graph.nodes,
      node_opts: graph.node_opts,
      edges: graph.edges,
      conditional_edges: graph.conditional_edges,
      initial_state: initial_state,
      reducers: reducers,
      checkpointer: Keyword.get(opts, :checkpointer),
      store: opts |> Keyword.get(:store) |> LangEx.Store.normalize(),
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

  defp validate_breakpoints(%__MODULE__{nodes: nodes}, opts, key) do
    opts
    |> Keyword.get(key, [])
    |> Enum.reject(&Map.has_key?(nodes, &1))
    |> assert_breakpoints_exist!(key)
  end

  defp assert_breakpoints_exist!([], _key), do: :ok

  defp assert_breakpoints_exist!(unknown, key) do
    raise ArgumentError,
          "#{inspect(key)} references undefined node(s) #{inspect(unknown)}"
  end

  defp validate_conditional_targets(%__MODULE__{} = graph) do
    valid = known_targets(graph)

    graph.conditional_edges
    |> Enum.flat_map(&mapping_targets/1)
    |> Enum.each(fn {source, target} ->
      validate_node_exists!(target, valid, "conditional edge target from #{inspect(source)}")
    end)

    :ok
  end

  defp mapping_targets({_source, {_routing_fn, nil}}), do: []

  defp mapping_targets({source, {_routing_fn, mapping}}) when is_map(mapping) do
    mapping
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&{source, &1})
  end

  # Reachability over *declared* edges is best-effort: mapping-less
  # conditional edges are opaque (stay silent), and nodes reached only
  # via Command goto look unreachable — silence those with
  # `compile(warn_unreachable: false)`.
  defp warn_on_unreachable_nodes(_graph, false), do: :ok

  defp warn_on_unreachable_nodes(%__MODULE__{} = graph, true) do
    graph.conditional_edges
    |> Enum.any?(&match?({_source, {_fn, nil}}, &1))
    |> report_unreachable(graph)
  end

  defp report_unreachable(true, _graph), do: :ok

  defp report_unreachable(false, graph) do
    graph.nodes
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.difference(reachable_from_start(graph))
    |> MapSet.to_list()
    |> emit_unreachable_warning()
  end

  defp emit_unreachable_warning([]), do: :ok

  defp emit_unreachable_warning(unreachable) do
    IO.warn(
      "graph node(s) not reachable via declared edges: #{inspect(Enum.sort(unreachable))} — " <>
        "pass `warn_unreachable: false` to compile/2 if they are Command goto targets"
    )

    :ok
  end

  defp reachable_from_start(graph), do: traverse(graph, [:__start__], MapSet.new())

  defp traverse(_graph, [], visited), do: visited

  defp traverse(graph, [node | rest], visited) do
    node
    |> targets_of(graph)
    |> Enum.reject(&(&1 in [:__end__] or MapSet.member?(visited, &1)))
    |> then(&traverse(graph, &1 ++ rest, MapSet.union(visited, MapSet.new(&1))))
  end

  defp targets_of(node, graph) do
    static = Map.get(graph.edges, node, [])

    conditional =
      graph.conditional_edges
      |> Map.take([node])
      |> Enum.flat_map(&mapping_targets/1)
      |> Enum.map(&elem(&1, 1))

    List.flatten(static ++ conditional)
  end

  defp known_targets(graph) do
    graph.nodes
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.put(:__start__)
    |> MapSet.put(:__end__)
  end

  @doc """
  Renders the graph as a Mermaid flowchart.

  Solid arrows are static edges; dashed arrows are conditional edges,
  labelled with the routing value when a mapping is given. Accepts a
  builder or a compiled graph.

      graph |> Graph.to_mermaid() |> IO.puts()
  """
  @spec to_mermaid(t() | Compiled.t()) :: String.t()
  def to_mermaid(%Compiled{} = compiled) do
    to_mermaid(%__MODULE__{
      nodes: compiled.nodes,
      edges: compiled.edges,
      conditional_edges: compiled.conditional_edges
    })
  end

  def to_mermaid(%__MODULE__{} = graph) do
    [
      "flowchart TD",
      "  __start__([start])",
      "  __end__([finish])",
      Enum.map(Map.keys(graph.nodes), &"  #{&1}[#{&1}]"),
      Enum.flat_map(graph.edges, &static_edge_lines/1),
      Enum.flat_map(graph.conditional_edges, &conditional_edge_lines/1)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp static_edge_lines({from, targets}), do: Enum.map(targets, &"  #{from} --> #{&1}")

  defp conditional_edge_lines({source, {_routing_fn, nil}}),
    do: ["  %% #{source}: dynamic routing (no mapping)"]

  defp conditional_edge_lines({source, {_routing_fn, mapping}}) do
    Enum.flat_map(mapping, fn {label, targets} ->
      targets
      |> List.wrap()
      |> Enum.map(&"  #{source} -.->|#{format_label(label)}| #{&1}")
    end)
  end

  defp format_label(label) when is_binary(label), do: label
  defp format_label(label), do: inspect(label)
end
