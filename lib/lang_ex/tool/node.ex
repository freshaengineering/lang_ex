defmodule LangEx.Tool.Node do
  @moduledoc """
  Graph node for executing tool calls from AI messages.

  Extracts `tool_calls` from the last `%Message.AI{}`, dispatches each
  call to its matching `%LangEx.Tool{}` in parallel, and returns
  `%Message.Tool{}` results.

  ## Control-flow tools

  A tool function may return a `%LangEx.Command{}` instead of a plain
  value. The command's `:update` is merged into the graph state (a tool
  updating `active_agent`, appending its own messages, etc.) and its
  `:goto` joins the node's routing. A `%Message.Tool{}` correlated by
  `tool_call_id` is guaranteed for every call — one is synthesized when
  the command does not carry it — so the provider always sees a reply
  for each requested call. When no tool returns a command the node keeps
  returning a plain `%{messages_key => [...]}` update.

  ## Usage in a graph

      tools = [
        %LangEx.Tool{
          name: "get_weather",
          description: "Get weather for a city",
          parameters: %{...},
          function: fn %{"city" => city} -> %{temp: 22, city: city} end
        }
      ]

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:agent, ChatModel.node(model: "gpt-4o", tools: tools))
        |> Graph.add_node(:tools, LangEx.Tool.Node.node(tools))
        |> Graph.add_conditional_edges(:agent, &LangEx.Tool.Node.tools_condition/1, %{
          tools: :tools,
          __end__: :__end__
        })
        |> Graph.add_edge(:__start__, :agent)
        |> Graph.add_edge(:tools, :agent)
        |> Graph.compile()

  ## Options

    * `:messages_key` — state key holding the message list (default `:messages`)
    * `:handle_tool_errors` — error handling strategy (default `true`):
      - `true`  — catch all errors, return error `%Message.Tool{}`
      - `false` — let exceptions propagate
      - `String.t()` — catch all, return this string as error content
      - `(Exception.t() -> String.t())` — custom handler
    * `:wrap_tool_call` — interceptor `fn(request, execute) -> result`
    * `:max_concurrency` — cap on parallel tool tasks
      (default `System.schedulers_online()`)
    * `:timeout` — per-tool timeout in ms (default `30_000`)
  """

  require Logger

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Tool

  @invalid_tool_template "Error: ~s is not a valid tool, try one of [~s]."
  @tool_error_template "Error: ~s\n Please fix your mistakes."

  defmodule ToolCallRequest do
    @moduledoc """
    Tool execution request passed to `wrap_tool_call` interceptors.

    Fields:

      * `:tool_call` — `%Message.ToolCall{}` from the AI message
      * `:tool` — `%LangEx.Tool{}` or `nil` when unregistered
      * `:state` — current graph state
      * `:store` — persistent store (or `nil`)
    """
    defstruct [:tool_call, :tool, :state, :store]

    @type t :: %__MODULE__{
            tool_call: LangEx.Message.ToolCall.t(),
            tool: LangEx.Tool.t() | nil,
            state: map(),
            store: term()
          }
  end

  @type error_handler ::
          boolean()
          | String.t()
          | (Exception.t() -> String.t())

  @doc """
  Returns a graph node function that executes tool calls.

  The returned function reads the last `%Message.AI{}` from state,
  executes each `tool_call` in parallel, and returns the results
  as `%Message.Tool{}` messages under the configured messages key.
  """
  @default_timeout 30_000

  @spec node([Tool.t()], keyword()) :: (map() -> map())
  def node(tools, opts \\ []) do
    messages_key = Keyword.get(opts, :messages_key, :messages)
    handle_errors = Keyword.get(opts, :handle_tool_errors, true)
    wrapper = Keyword.get(opts, :wrap_tool_call)

    exec_opts = %{
      max_concurrency: Keyword.get(opts, :max_concurrency) || System.schedulers_online(),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }

    tools_by_name = Map.new(tools, fn %Tool{name: name} = tool -> {name, tool} end)

    fn state ->
      store = LangEx.Store.attached()

      state
      |> Map.fetch!(messages_key)
      |> extract_tool_calls()
      |> then(
        &execute_all(
          &1,
          tools_by_name,
          state,
          store,
          handle_errors,
          wrapper,
          messages_key,
          exec_opts
        )
      )
      |> then(&assemble_result(&1, messages_key))
    end
  end

  @doc """
  Routing condition for tool-calling workflows.

  Returns `:tools` when the last message has pending tool calls,
  `:__end__` otherwise. Use with `Graph.add_conditional_edges/4`.

  ## Options

    * `:messages_key` — state key (default `:messages`)
  """
  @spec tools_condition(map(), keyword()) :: :tools | :__end__
  def tools_condition(state, opts \\ []) do
    messages_key = Keyword.get(opts, :messages_key, :messages)

    state
    |> Map.get(messages_key, [])
    |> List.last()
    |> has_tool_calls?()
  end

  defp has_tool_calls?(%Message.AI{tool_calls: [_ | _]}), do: :tools
  defp has_tool_calls?(_), do: :__end__

  defp extract_tool_calls(messages) do
    messages
    |> List.last()
    |> last_tool_calls()
  end

  defp last_tool_calls(%Message.AI{tool_calls: calls}) when calls != [], do: calls
  defp last_tool_calls(_), do: []

  defp execute_all(
         tool_calls,
         tools_by_name,
         state,
         store,
         handle_errors,
         wrapper,
         messages_key,
         exec_opts
       ) do
    LangEx.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      tool_calls,
      &run_one(&1, tools_by_name, state, store, handle_errors, wrapper, messages_key),
      max_concurrency: exec_opts.max_concurrency,
      timeout: exec_opts.timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(&handle_task_outcome/1)
  end

  # A batch of tool results is either plain `%Message.Tool{}` values (the
  # common case, returned as a messages update) or a mix that includes
  # `%LangEx.Command{}` results, which collapse into one node-level
  # command carrying every reply plus the merged updates and gotos.
  defp assemble_result(results, messages_key) do
    results
    |> Enum.any?(&match?(%Command{}, &1))
    |> build_node_result(results, messages_key)
  end

  defp build_node_result(false, results, messages_key), do: %{messages_key => results}

  defp build_node_result(true, results, messages_key) do
    messages =
      results |> Enum.flat_map(&result_messages(&1, messages_key)) |> tool_replies_first()

    updates =
      results |> Enum.filter(&match?(%Command{}, &1)) |> merge_command_updates(messages_key)

    %Command{update: Map.put(updates, messages_key, messages), goto: collect_gotos(results)}
  end

  defp result_messages(%Command{update: update}, messages_key),
    do: Map.get(update, messages_key, [])

  defp result_messages(%Message.Tool{} = message, _messages_key), do: [message]

  # Every `%Message.Tool{}` reply must sit immediately after the AI's
  # tool-call message (some providers reject a tool call whose result is
  # separated from it), so replies lead and any extra command messages
  # (e.g. a handoff task brief) follow.
  defp tool_replies_first(messages) do
    {replies, rest} = Enum.split_with(messages, &match?(%Message.Tool{}, &1))
    replies ++ rest
  end

  # Parallel tool calls in one batch can each write state. Map-valued keys
  # are accumulators (e.g. a shared cache): they deep-merge so every call's
  # entries survive. Scalar keys that diverge (e.g. two handoffs both setting
  # `:active_agent`) cannot both win in a single super-step, so the earliest
  # call wins and the conflict is logged.
  defp merge_command_updates(commands, messages_key) do
    Enum.reduce(commands, %{}, fn %Command{update: update}, acc ->
      update
      |> Map.delete(messages_key)
      |> merge_into(acc)
    end)
  end

  defp merge_into(update, acc), do: Map.merge(acc, update, &keep_earliest/3)

  defp keep_earliest(_key, existing, existing), do: existing

  defp keep_earliest(_key, existing, dropped)
       when is_map(existing) and is_map(dropped) and
              not is_struct(existing) and not is_struct(dropped),
       do: Map.merge(existing, dropped, &keep_earliest/3)

  defp keep_earliest(key, existing, dropped) do
    Logger.warning(
      "Tool.Node: conflicting updates for #{inspect(key)} from parallel tool calls — " <>
        "keeping #{inspect(existing)}, dropping #{inspect(dropped)}"
    )

    existing
  end

  defp collect_gotos(results) do
    results
    |> Enum.filter(&match?(%Command{}, &1))
    |> Enum.flat_map(fn %Command{goto: goto} -> List.wrap(goto) end)
  end

  defp handle_task_outcome({:ok, result}), do: result

  defp handle_task_outcome({:exit, {exception, stacktrace}}) when is_exception(exception),
    do: reraise(exception, stacktrace)

  defp handle_task_outcome({:exit, :timeout}), do: raise("Tool execution timed out")
  defp handle_task_outcome({:exit, reason}), do: exit(reason)

  defp run_one(call, tools_by_name, state, store, handle_errors, wrapper, messages_key) do
    Process.put(:lang_ex_store, store)

    request = %ToolCallRequest{
      tool_call: call,
      tool: Map.get(tools_by_name, call.name),
      state: state,
      store: store
    }

    request
    |> dispatch_tool_call(
      fn req -> execute_tool(req, tools_by_name, handle_errors) end,
      wrapper,
      handle_errors,
      call
    )
    |> ensure_tool_message(call, messages_key)
  end

  # Every requested call must get a reply for the provider. A command
  # result that already carries its own `%Message.Tool{}` is left alone;
  # otherwise a default reply is prepended to its messages update.
  defp ensure_tool_message(%Command{update: update} = command, call, messages_key) do
    update
    |> Map.get(messages_key, [])
    |> tool_message?(call.id)
    |> put_default_reply(command, call, messages_key)
  end

  defp ensure_tool_message(result, _call, _messages_key), do: result

  defp tool_message?(messages, id),
    do: Enum.any?(messages, &match?(%Message.Tool{tool_call_id: ^id}, &1))

  defp put_default_reply(true, command, _call, _messages_key), do: command

  defp put_default_reply(false, %Command{update: update} = command, call, messages_key) do
    reply = Message.tool("Transferred to #{call.name}.", call.id)
    replies = [reply | Map.get(update, messages_key, [])]
    %{command | update: Map.put(update, messages_key, replies)}
  end

  defp dispatch_tool_call(request, execute_fn, nil, _handle_errors, _call),
    do: execute_fn.(request)

  defp dispatch_tool_call(request, execute_fn, wrap, handle_errors, call)
       when is_function(wrap, 2) do
    wrap.(request, execute_fn)
  rescue
    e ->
      propagate_error(handle_errors, e, __STACKTRACE__)
      format_error(e, call, handle_errors)
  end

  defp execute_tool(%ToolCallRequest{tool: nil, tool_call: call}, tools_by_name, false) do
    raise ArgumentError,
          tools_by_name
          |> Map.keys()
          |> Enum.join(", ")
          |> then(&:io_lib.format(@invalid_tool_template, [call.name, &1]))
          |> to_string()
  end

  defp execute_tool(%ToolCallRequest{tool: nil, tool_call: call}, tools_by_name, _handle_errors),
    do: invalid_tool_message(call, tools_by_name)

  defp execute_tool(
         %ToolCallRequest{tool: tool, tool_call: call, state: state, store: store},
         _tools_by_name,
         handle_errors
       ) do
    tool.function
    |> call_function(call.args, state, store, call.id)
    |> to_tool_result(call)
  rescue
    e ->
      propagate_error(handle_errors, e, __STACKTRACE__)
      format_error(e, call, handle_errors)
  end

  defp to_tool_result(%Command{} = command, _call), do: command
  defp to_tool_result(result, call), do: result |> encode_result() |> Message.tool(call.id)

  defp propagate_error(false, e, stacktrace), do: reraise(e, stacktrace)
  defp propagate_error(_, _e, _stacktrace), do: :ok

  defp call_function(fun, args, state, store, tool_call_id) do
    fun
    |> Function.info(:arity)
    |> dispatch_function(fun, args, state, store, tool_call_id)
  end

  defp dispatch_function({:arity, 1}, fun, args, _state, _store, _tool_call_id), do: fun.(args)

  defp dispatch_function({:arity, 2}, fun, args, state, store, tool_call_id),
    do: fun.(args, %{state: state, store: store, tool_call_id: tool_call_id})

  defp format_error(exception, call, true) do
    @tool_error_template
    |> :io_lib.format([Exception.message(exception)])
    |> to_string()
    |> Message.tool(call.id)
  end

  defp format_error(_exception, call, message) when is_binary(message),
    do: Message.tool(message, call.id)

  defp format_error(exception, call, handler) when is_function(handler, 1),
    do: Message.tool(handler.(exception), call.id)

  defp invalid_tool_message(call, tools_by_name) do
    tools_by_name
    |> Map.keys()
    |> Enum.join(", ")
    |> then(&:io_lib.format(@invalid_tool_template, [call.name, &1]))
    |> to_string()
    |> Message.tool(call.id)
  end

  defp encode_result(result) when is_binary(result), do: result

  defp encode_result(result) do
    result
    |> Jason.encode()
    |> format_encoded(result)
  end

  defp format_encoded({:ok, json}, _result), do: json
  defp format_encoded({:error, _}, result), do: inspect(result)
end
