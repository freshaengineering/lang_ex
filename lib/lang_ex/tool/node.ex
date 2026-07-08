defmodule LangEx.Tool.Node do
  @moduledoc """
  Graph node for executing tool calls from AI messages.

  Extracts `tool_calls` from the last `%Message.AI{}`, dispatches each
  call to its matching `%LangEx.Tool{}` in parallel, and returns
  `%Message.Tool{}` results.

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
      state
      |> Map.fetch!(messages_key)
      |> extract_tool_calls()
      |> then(&execute_all(&1, tools_by_name, state, handle_errors, wrapper, exec_opts))
      |> then(&%{messages_key => &1})
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

  defp execute_all(tool_calls, tools_by_name, state, handle_errors, wrapper, exec_opts) do
    LangEx.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      tool_calls,
      &run_one(&1, tools_by_name, state, handle_errors, wrapper),
      max_concurrency: exec_opts.max_concurrency,
      timeout: exec_opts.timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(&handle_task_outcome/1)
  end

  defp handle_task_outcome({:ok, result}), do: result

  defp handle_task_outcome({:exit, {exception, stacktrace}}) when is_exception(exception),
    do: reraise(exception, stacktrace)

  defp handle_task_outcome({:exit, :timeout}), do: raise("Tool execution timed out")
  defp handle_task_outcome({:exit, reason}), do: exit(reason)

  defp run_one(call, tools_by_name, state, handle_errors, wrapper) do
    request = %ToolCallRequest{
      tool_call: call,
      tool: Map.get(tools_by_name, call.name),
      state: state,
      store: nil
    }

    dispatch_tool_call(
      request,
      fn req -> execute_tool(req, tools_by_name, handle_errors) end,
      wrapper,
      handle_errors,
      call
    )
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
         %ToolCallRequest{tool: tool, tool_call: call, state: state},
         _tools_by_name,
         handle_errors
       ) do
    tool.function
    |> call_function(call.args, state, call.id)
    |> encode_result()
    |> Message.tool(call.id)
  rescue
    e ->
      propagate_error(handle_errors, e, __STACKTRACE__)
      format_error(e, call, handle_errors)
  end

  defp propagate_error(false, e, stacktrace), do: reraise(e, stacktrace)
  defp propagate_error(_, _e, _stacktrace), do: :ok

  defp call_function(fun, args, state, tool_call_id) do
    fun
    |> Function.info(:arity)
    |> dispatch_function(fun, args, state, tool_call_id)
  end

  defp dispatch_function({:arity, 1}, fun, args, _state, _tool_call_id), do: fun.(args)

  defp dispatch_function({:arity, 2}, fun, args, state, tool_call_id),
    do: fun.(args, %{state: state, store: nil, tool_call_id: tool_call_id})

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
