defmodule LangEx.Telemetry do
  @moduledoc """
  Telemetry events emitted by LangEx.

  LangEx uses `:telemetry` to emit structured events at key points during
  graph execution. All span events follow the `[prefix, :start]`,
  `[prefix, :stop]`, `[prefix, :exception]` convention produced by
  `:telemetry.span/3`.

  ## Run-tree correlation

  Every span's metadata carries two extra keys:

  | Key              | Type                | Description                              |
  |------------------|---------------------|------------------------------------------|
  | `:run_id`        | `String.t()`        | Unique ID of this span                   |
  | `:parent_run_id` | `String.t() \\| nil` | ID of the enclosing span (nil at root)   |

  Graph invoke → step → node → LLM/checkpoint spans form a tree, so a
  single invocation can be fully reconstructed from the event stream.
  Subgraph invokes appear as child invoke spans of the parent node.
  See `LangEx.Telemetry.Runs` and, for exporting to OpenTelemetry,
  `LangEx.Telemetry.OpenTelemetryBridge`.

  ## Events

  ### `[:lang_ex, :graph, :invoke, :start]`

  Emitted when a graph invocation begins.

    * Measurements: `%{system_time: integer(), monotonic_time: integer()}`
    * Metadata:

      | Key           | Type              | Description                       |
      |---------------|-------------------|-----------------------------------|
      | `:graph_id`   | `atom() \\| nil`   | Graph identifier (first node key) |
      | `:thread_id`  | `term() \\| nil`   | Thread ID from config             |

  ### `[:lang_ex, :graph, :invoke, :stop]`

  Emitted when a graph invocation completes.

    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start, plus:

      | Key       | Type   | Description                              |
      |-----------|--------|------------------------------------------|
      | `:result` | `atom` | `:ok`, `:interrupt`, or `:error`         |

  ### `[:lang_ex, :graph, :invoke, :exception]`

  Emitted when a graph invocation raises.

    * Measurements: `%{duration: integer(), monotonic_time: integer()}`
    * Metadata: same as start, plus `:kind`, `:reason`, `:stacktrace`

  ---

  ### `[:lang_ex, :graph, :step, :start | :stop | :exception]`

  Emitted around each super-step.

    * Metadata:

      | Key             | Type       | Description                    |
      |-----------------|------------|--------------------------------|
      | `:step`         | `integer`  | Super-step number              |
      | `:active_nodes` | `[atom()]` | Nodes executing in this step   |

  ---

  ### `[:lang_ex, :node, :execute, :start | :stop | :exception]`

  Emitted around individual node execution.

    * Metadata:

      | Key      | Type     | Description |
      |----------|----------|-------------|
      | `:node`  | `atom()` | Node name   |

  ---

  ### `[:lang_ex, :llm, :chat, :start | :stop | :exception]`

  Emitted around LLM provider chat calls (inside `ChatModel` nodes).

    * Metadata:

      | Key              | Type       | Description                    |
      |------------------|------------|--------------------------------|
      | `:provider`      | `module()` | LLM provider module            |
      | `:model`         | `term()`   | Model name                     |
      | `:message_count` | `integer`  | Number of messages sent        |

    * Stop metadata adds:

      | Key       | Type   | Description          |
      |-----------|--------|----------------------|
      | `:status` | `atom` | `:ok` or `:error`    |

  ---

  ### `[:lang_ex, :checkpoint, :save, :start | :stop | :exception]`

  Emitted around checkpoint persistence.

    * Metadata:

      | Key             | Type       | Description                 |
      |-----------------|------------|-----------------------------|
      | `:checkpointer` | `module()` | Checkpointer implementation |
      | `:thread_id`    | `term()`   | Thread identifier           |

  ### `[:lang_ex, :checkpoint, :load, :start | :stop | :exception]`

  Emitted around checkpoint loading.

    * Metadata: same as `:checkpoint, :save`.
  """

  @doc "Returns all telemetry event name prefixes emitted by LangEx."
  @spec events() :: [[atom(), ...]]
  def events do
    for prefix <- [
          [:lang_ex, :graph, :invoke],
          [:lang_ex, :graph, :step],
          [:lang_ex, :node, :execute],
          [:lang_ex, :llm, :chat],
          [:lang_ex, :checkpoint, :save],
          [:lang_ex, :checkpoint, :load]
        ],
        suffix <- [:start, :stop, :exception] do
      prefix ++ [suffix]
    end
  end
end
