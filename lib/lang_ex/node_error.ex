defmodule LangEx.NodeError do
  @moduledoc """
  Structured failure of a graph node.

  Graph execution returns `{:error, %LangEx.NodeError{}}` when a node
  raises (after its retry policy, if any, is exhausted) or its task
  exits. The failing node name is in `:node` and the original exception
  or exit reason is preserved in `:reason`, so callers can pattern match
  on the underlying cause:

      {:error, %LangEx.NodeError{node: :fetch, reason: %Req.TransportError{}}} =
        LangEx.invoke(graph, input)
  """

  defexception [:node, :reason, stacktrace: []]

  @type t :: %__MODULE__{
          node: atom(),
          reason: term(),
          stacktrace: Exception.stacktrace()
        }

  @impl true
  def message(%__MODULE__{node: node, reason: reason}) when is_exception(reason) do
    "node #{inspect(node)} failed: #{Exception.message(reason)}"
  end

  def message(%__MODULE__{node: node, reason: reason}) do
    "node #{inspect(node)} failed: #{inspect(reason)}"
  end

  @doc "Wraps a raised exception or exit reason, preserving existing wrappers."
  @spec wrap(atom(), term(), Exception.stacktrace()) :: t()
  def wrap(_node, %__MODULE__{} = error, _stacktrace), do: error

  def wrap(_node, {%__MODULE__{} = error, _stacktrace}, _outer_stacktrace), do: error

  def wrap(node, reason, stacktrace) when is_atom(node),
    do: %__MODULE__{node: node, reason: reason, stacktrace: stacktrace}
end
