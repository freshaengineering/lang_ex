defmodule LangEx.Message do
  @moduledoc """
  Chat message types for LLM interactions.

  Provides struct-based message types and a reducer for accumulating
  messages in graph state.
  """

  defmodule Human do
    @moduledoc "A message authored by the human user."
    @derive Jason.Encoder
    defstruct [:content, :id]
    @type t :: %__MODULE__{content: String.t(), id: String.t() | nil}
  end

  defmodule ToolCall do
    @moduledoc "A structured tool/function call requested by the LLM."
    @derive Jason.Encoder
    defstruct [:name, :id, :args]

    @type t :: %__MODULE__{
            name: String.t(),
            id: String.t() | nil,
            args: map()
          }
  end

  defmodule AI do
    @moduledoc "A message authored by the LLM, optionally carrying tool calls."
    @derive Jason.Encoder
    defstruct [:content, :id, tool_calls: []]

    @type t :: %__MODULE__{
            content: String.t() | nil,
            id: String.t() | nil,
            tool_calls: [LangEx.Message.ToolCall.t()]
          }
  end

  defmodule System do
    @moduledoc "A system prompt message."
    @derive Jason.Encoder
    defstruct [:content, :id]
    @type t :: %__MODULE__{content: String.t(), id: String.t() | nil}
  end

  defmodule Tool do
    @moduledoc "The result of a tool call, correlated by `tool_call_id`."
    @derive Jason.Encoder
    defstruct [:content, :tool_call_id, :id]
    @type t :: %__MODULE__{content: String.t(), tool_call_id: String.t(), id: String.t() | nil}
  end

  defmodule RemoveMessage do
    @moduledoc """
    A deletion instruction consumed by `LangEx.Message.add_messages/2`.

    Emitted (never stored) so a reducer update can prune history instead of
    only appending. `id` targets a single message by its `:id`; the special
    `LangEx.Message.remove_all/0` sentinel clears every prior message,
    letting a node replace the whole history (e.g. summarization).
    """
    @derive Jason.Encoder
    defstruct [:id]
    @type t :: %__MODULE__{id: String.t()}
  end

  @type t :: Human.t() | AI.t() | System.t() | Tool.t()
  @type instruction :: t() | RemoveMessage.t()

  @remove_all "__remove_all__"

  @doc "Create a human message."
  @spec human(String.t(), keyword()) :: Human.t()
  def human(content, opts \\ []), do: struct!(Human, [{:content, content} | opts])

  @doc "Create an AI message."
  @spec ai(String.t(), keyword()) :: AI.t()
  def ai(content, opts \\ []), do: struct!(AI, [{:content, content} | opts])

  @doc "Create a system message."
  @spec system(String.t(), keyword()) :: System.t()
  def system(content, opts \\ []), do: struct!(__MODULE__.System, [{:content, content} | opts])

  @doc "Create a tool result message."
  @spec tool(String.t(), String.t(), keyword()) :: Tool.t()
  def tool(content, tool_call_id, opts \\ []) do
    struct!(Tool, [{:content, content}, {:tool_call_id, tool_call_id} | opts])
  end

  @doc "Create a `RemoveMessage` targeting a single message by its `:id`."
  @spec remove(String.t()) :: RemoveMessage.t()
  def remove(id) when is_binary(id), do: %RemoveMessage{id: id}

  @doc "Create a `RemoveMessage` that clears the entire prior history."
  @spec remove_all() :: RemoveMessage.t()
  def remove_all, do: %RemoveMessage{id: @remove_all}

  @doc """
  Reducer that folds a list of instructions onto the existing history.

  Instructions are applied left to right:

  - a plain message is appended, or replaces an existing one when their
    `:id` values match (corrections/updates)
  - a `RemoveMessage` with a matching `:id` deletes that message
  - the `remove_all/0` sentinel clears everything accumulated so far, so a
    node can replace the whole history in a single update

  Order matters: `[remove_all(), summary]` clears the history and keeps
  `summary`, while `[summary, remove_all()]` would discard `summary` too.
  """
  @spec add_messages([t()], [instruction()] | instruction()) :: [t()]
  def add_messages(existing, new) when is_list(new) do
    Enum.reduce(new, existing, &apply_instruction/2)
  end

  def add_messages(existing, single), do: add_messages(existing, [single])

  defp apply_instruction(%RemoveMessage{id: @remove_all}, _acc), do: []

  defp apply_instruction(%RemoveMessage{id: id}, acc),
    do: Enum.reject(acc, &(message_id(&1) == id))

  defp apply_instruction(msg, acc) do
    msg
    |> message_id()
    |> upsert(msg, acc)
  end

  defp upsert(nil, msg, acc), do: acc ++ [msg]

  defp upsert(id, msg, acc) do
    acc
    |> Enum.any?(&(message_id(&1) == id))
    |> replace_or_append(id, msg, acc)
  end

  defp replace_or_append(true, id, msg, acc),
    do: Enum.map(acc, &replace_matching(&1, id, msg))

  defp replace_or_append(false, _id, msg, acc), do: acc ++ [msg]

  defp replace_matching(existing, id, msg) do
    existing
    |> message_id()
    |> matched(existing, id, msg)
  end

  defp matched(id, _existing, id, msg), do: msg
  defp matched(_other, existing, _id, _msg), do: existing

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(_), do: nil
end
