defmodule LangEx.LLM.ChatModel do
  @moduledoc """
  Helper to create graph nodes that call an LLM.

  Produces a node function that reads messages from state,
  sends them to the configured LLM provider, and appends
  the response to the messages list.
  """

  alias LangEx.LLM.Registry
  alias LangEx.Telemetry.Runs

  @doc """
  Returns a node function that calls an LLM provider.

  ## Options

  - `:provider` - module implementing `LangEx.LLM` (explicit)
  - `:model` - model string like `"gpt-4o"` or `"claude-sonnet-4-20250514"` (auto-resolves provider)
  - `:messages_key` - state key holding the message list (default: `:messages`)
  - `:usage_key` - state key accumulating token usage (default: `:llm_usage`);
    only written when the key exists in the graph state schema
  - `:tools` - list of `%LangEx.Tool{}` definitions for function calling
  - `:resilient` - route calls through `LangEx.LLM.Resilient` for retries
    with backoff. `true` for defaults, or a keyword list of `Resilient`
    options (`:max_retries`, `:retry_base_ms`, `:fallback`, ...)
  - All other opts forwarded to `provider.chat/2` (`:api_key`, `:temperature`, etc.)

  Either `:provider` or `:model` must be given. When `:model` is a string and
  `:provider` is absent, the provider is resolved via `LangEx.LLM.Registry.init_chat_model/2`.

  Tool execution is handled by a separate `LangEx.Tool.Node` in the graph,
  not by the LLM node itself.

  ## Token usage accounting

  When the provider implements `chat_with_usage/2`, token counts are
  attached to the `[:lang_ex, :llm, :chat, :stop]` telemetry event as
  `:usage` metadata. To also accumulate usage in graph state, declare
  the usage key in the schema with `merge_usage/2` as the reducer:

      Graph.new(
        messages: {[], &Message.add_messages/2},
        llm_usage: {%{}, &ChatModel.merge_usage/2}
      )

  ## Examples

      Graph.add_node(:llm, ChatModel.node(model: "gpt-4o"))
      Graph.add_node(:llm, ChatModel.node(model: "gpt-4o",
        tools: [%LangEx.Tool{name: "search", ...}]
      ))
  """
  @spec node(keyword()) :: (map() -> map())
  def node(opts) do
    {provider, llm_opts} = resolve_provider(opts)
    {messages_key, llm_opts} = Keyword.pop(llm_opts, :messages_key, :messages)
    {usage_key, llm_opts} = Keyword.pop(llm_opts, :usage_key, :llm_usage)
    {resilient, llm_opts} = Keyword.pop(llm_opts, :resilient)
    model = Keyword.get(llm_opts, :model)

    fn state ->
      messages = Map.fetch!(state, messages_key)
      metadata = %{provider: provider, model: model, message_count: length(messages)}

      {:ok, ai_message, usage} =
        Runs.span([:lang_ex, :llm, :chat], metadata, fn ->
          result = dispatch_call(resilient, provider, messages, attach_delta_callback(llm_opts))
          {result, chat_metadata(metadata, result)}
        end)

      %{messages_key => [ai_message]}
      |> with_usage(state, usage_key, usage)
    end
  end

  defp dispatch_call(nil, provider, messages, llm_opts),
    do: call_provider(provider, messages, llm_opts)

  defp dispatch_call(true, provider, messages, llm_opts),
    do: dispatch_call([], provider, messages, llm_opts)

  defp dispatch_call(resilient_opts, provider, messages, llm_opts)
       when is_list(resilient_opts) do
    provider
    |> LangEx.LLM.Resilient.chat_with_usage(messages, resilient_opts ++ llm_opts)
    |> ensure_usage()
  end

  defp ensure_usage({:ok, ai, usage}), do: {:ok, ai, usage}
  defp ensure_usage({:ok, ai}), do: {:ok, ai, %{input_tokens: 0, output_tokens: 0}}
  defp ensure_usage({:error, _} = err), do: err

  # When the graph is being streamed, forward token deltas from streaming
  # adapters as {:message_delta, ...} events (consumed via the :messages
  # stream mode). An explicit user :on_token callback takes precedence.
  defp attach_delta_callback(llm_opts) do
    :lang_ex_stream_emit
    |> Process.get()
    |> add_delta_callback(llm_opts)
  end

  defp add_delta_callback(nil, llm_opts), do: llm_opts

  defp add_delta_callback(_pid, llm_opts) do
    node = Process.get(:lang_ex_current_node)

    Keyword.put_new(llm_opts, :on_token, fn text ->
      LangEx.Graph.Stream.notify({:message_delta, %{node: node, kind: :content, text: text}})
    end)
  end

  @doc """
  Reducer that accumulates token usage maps by summing numeric fields.

  Use as the schema reducer for the usage key:

      Graph.new(llm_usage: {%{}, &ChatModel.merge_usage/2})
  """
  @spec merge_usage(map() | nil, map()) :: map()
  def merge_usage(nil, new), do: new

  def merge_usage(current, new) when is_map(current) and is_map(new) do
    Map.merge(current, new, &merge_usage_field/3)
  end

  defp merge_usage_field(_key, current, new) when is_number(current) and is_number(new),
    do: current + new

  defp merge_usage_field(_key, _current, new), do: new

  defp call_provider(provider, messages, llm_opts) do
    provider
    |> function_exported?(:chat_with_usage, 2)
    |> dispatch_chat(provider, messages, llm_opts)
  end

  defp dispatch_chat(true, provider, messages, llm_opts),
    do: provider.chat_with_usage(messages, llm_opts)

  defp dispatch_chat(false, provider, messages, llm_opts) do
    messages
    |> provider.chat(llm_opts)
    |> zero_usage()
  end

  defp zero_usage({:ok, ai}), do: {:ok, ai, %{input_tokens: 0, output_tokens: 0}}
  defp zero_usage({:error, _} = err), do: err

  defp chat_metadata(metadata, {:ok, _ai, usage}),
    do: metadata |> Map.put(:status, :ok) |> Map.put(:usage, usage)

  defp chat_metadata(metadata, {:error, _reason}), do: Map.put(metadata, :status, :error)

  defp with_usage(update, state, usage_key, usage) do
    state
    |> Map.has_key?(usage_key)
    |> apply_usage(update, usage_key, usage)
  end

  defp apply_usage(true, update, usage_key, usage), do: Map.put(update, usage_key, usage)
  defp apply_usage(false, update, _usage_key, _usage), do: update

  defp resolve_provider(opts) do
    opts
    |> Keyword.pop(:provider)
    |> ensure_provider()
  end

  defp ensure_provider({provider, rest}) when not is_nil(provider), do: {provider, rest}

  defp ensure_provider({nil, rest}) do
    {model, rest} = Keyword.pop!(rest, :model)
    Registry.init_chat_model(model, rest)
  end
end
