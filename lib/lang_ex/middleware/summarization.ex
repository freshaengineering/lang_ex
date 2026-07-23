defmodule LangEx.Middleware.Summarization do
  @moduledoc """
  Middleware that replaces older history with an LLM-written summary.

  When the message list grows past `:max_bytes`, everything older than the
  last `:keep` messages is condensed into a single summary message with one
  LLM call, and the history is rewritten in place via
  `LangEx.Message.remove_all/0` — so the summary *persists* and later turns
  build on it instead of resummarising from scratch. Unlike the byte-notice
  fallback in `LangEx.ContextCompaction`, the agent keeps the *findings* from
  early rounds, not just a list of which tools ran.

  Use this instead of the built-in `:compaction` (pass `compaction: false`
  to `LangEx.Prebuilt.agent/1`), not alongside it.

  ## Options

  - `:model` / `:provider` - the summariser model (required; a cheaper/faster
    model than the main agent is a good fit)
  - `:max_bytes` - trigger threshold for the whole message list (default
    `200_000`)
  - `:keep` - number of most recent messages kept verbatim (default `6`);
    the boundary is shifted so a kept `%Message.Tool{}` never loses its
    originating tool-call message
  - `:summary_prompt` - system prompt for the summariser
  - `:resilient` and other options are forwarded to the summariser call
  """

  alias LangEx.ContextCompaction
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Middleware

  @default_max_bytes 200_000
  @default_keep 6
  @middleware_opt_keys [:max_bytes, :keep, :summary_prompt]

  @default_prompt "You are compressing an assistant's working context. " <>
                    "Summarise the conversation below into a dense briefing that preserves " <>
                    "every concrete finding, decision, identifier, and open question needed to " <>
                    "continue the task. Omit pleasantries. Do not invent facts."

  @doc "Builds a summarisation middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts \\ []) do
    Middleware.new(name: :summarization, before_model: hook(opts))
  end

  defp hook(opts) do
    {mw_opts, llm_opts} = Keyword.split(opts, @middleware_opt_keys)
    max_bytes = Keyword.get(mw_opts, :max_bytes, @default_max_bytes)
    keep = Keyword.get(mw_opts, :keep, @default_keep)
    prompt = Keyword.get(mw_opts, :summary_prompt, @default_prompt)

    fn state ->
      state.messages
      |> ContextCompaction.messages_byte_size()
      |> over_budget?(max_bytes)
      |> summarize(state.messages, keep, prompt, llm_opts)
    end
  end

  defp over_budget?(size, max_bytes), do: size > max_bytes

  defp summarize(false, _messages, _keep, _prompt, _llm_opts), do: %{}

  defp summarize(true, messages, keep, prompt, llm_opts) do
    {system_msgs, rest} = Enum.split_with(messages, &match?(%Message.System{}, &1))

    rest
    |> keep_split(keep)
    |> rewrite(system_msgs, prompt, llm_opts)
  end

  defp rewrite({[], _recent}, _system_msgs, _prompt, _llm_opts), do: %{}

  defp rewrite({older, recent}, system_msgs, prompt, llm_opts) do
    {summary, usage} = run_summary(older, prompt, llm_opts)
    kept = system_msgs ++ [summary_message(summary) | recent]
    %{messages: [Message.remove_all() | kept], llm_usage: usage}
  end

  defp keep_split(messages, keep) when length(messages) <= keep, do: {[], messages}

  defp keep_split(messages, keep) do
    messages
    |> Enum.split(length(messages) - keep)
    |> shift_boundary()
  end

  defp shift_boundary({[_ | _] = older, [%Message.Tool{} | _] = recent}) do
    {rest, [last]} = Enum.split(older, length(older) - 1)
    shift_boundary({rest, [last | recent]})
  end

  defp shift_boundary(split), do: split

  defp run_summary(older, prompt, llm_opts) do
    [Message.system(prompt), Message.human(render(older))]
    |> ChatModel.complete(llm_opts)
    |> summary_result()
  end

  defp summary_result({:ok, %Message.AI{content: content}, usage}) when is_binary(content),
    do: {content, usage}

  defp summary_result(_other), do: {"(summary unavailable)", %{}}

  defp summary_message(summary),
    do: Message.human("[Summary of earlier conversation]\n\n#{summary}")

  defp render(messages), do: Enum.map_join(messages, "\n\n", &render_message/1)

  defp render_message(%Message.Human{content: c}), do: "User: #{c}"
  defp render_message(%Message.System{content: c}), do: "System: #{c}"
  defp render_message(%Message.Tool{content: c}), do: "Tool result: #{c}"

  defp render_message(%Message.AI{content: c, tool_calls: []}) when is_binary(c),
    do: "Assistant: #{c}"

  defp render_message(%Message.AI{content: c, tool_calls: calls}) do
    calls
    |> Enum.map_join(", ", & &1.name)
    |> then(&"Assistant (#{content_prefix(c)}called #{&1})")
  end

  defp content_prefix(c) when is_binary(c) and c != "", do: "#{c}; "
  defp content_prefix(_c), do: ""
end
