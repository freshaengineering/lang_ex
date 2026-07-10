defmodule LangEx.NodeTimeoutError do
  @moduledoc """
  Raised when a node attempt exceeds its timeout.

  Timeouts come from the per-node `:timeout` option on
  `LangEx.Graph.add_node/4` or the graph-wide `:node_timeout` invoke
  option. The error is raised per attempt, so a node retry policy can
  retry timed-out attempts (filter with `retryable?:` to opt out).
  """

  defexception [:node, :timeout_ms]

  @type t :: %__MODULE__{node: atom(), timeout_ms: pos_integer()}

  @impl true
  def message(%__MODULE__{node: node, timeout_ms: timeout_ms}) do
    "node #{inspect(node)} timed out after #{timeout_ms}ms"
  end
end
