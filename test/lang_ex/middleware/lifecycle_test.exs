defmodule LangEx.Middleware.LifecycleTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Command
  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Prebuilt
  alias LangEx.Tool

  setup do
    LangEx.Checkpointer.Memory.clear()
    :ok
  end

  describe "before_agent" do
    test "setup runs once even when the agent takes several turns" do
      loops_once()

      graph =
        agent(
          Middleware.new(
            name: :loader,
            state_schema: [profile: nil, setups: 0],
            before_agent: fn state ->
              %{profile: "loaded", setups: Map.get(state, :setups, 0) + 1}
            end,
            after_model: fn state -> loop_once(state) end
          )
        )

      {:ok, result} = LangEx.invoke(graph, opening())

      assert %{profile: "loaded", setups: 1} = result
      assert 2 == Enum.count(result.messages, &match?(%Message.AI{}, &1))
    end

    test "what it loads is visible to the first model call" do
      record_calls()

      graph =
        agent(
          Middleware.new(
            name: :loader,
            before_agent: fn _state -> %{messages: [Message.human("known preference: brief")]} end
          )
        )

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:called, messages}
      assert Enum.any?(messages, &match?(%Message.Human{content: "known preference: brief"}, &1))
    end
  end

  describe "after_agent" do
    test "teardown runs once, after the last model call" do
      answers()

      graph =
        agent(
          Middleware.new(
            name: :saver,
            state_schema: [saved: nil],
            after_agent: fn state -> %{saved: length(state.messages)} end
          )
        )

      {:ok, result} = LangEx.invoke(graph, opening())

      assert result.saved == 2
    end

    test "the stack unwinds in reverse on the way out" do
      answers()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          middleware: [
            Middleware.new(
              name: :outer,
              state_schema: [order: []],
              after_agent: &record(&1, :outer)
            ),
            Middleware.new(name: :inner, after_agent: &record(&1, :inner))
          ]
        )

      {:ok, result} = LangEx.invoke(graph, opening())

      assert result.order == [:inner, :outer]
    end
  end

  describe "run scope" do
    test "resuming a paused run does not repeat its setup" do
      requests_a_tool()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [echo_tool()],
          middleware: [
            Middleware.new(
              name: :loader,
              state_schema: [setups: 0],
              before_agent: fn state -> %{setups: Map.get(state, :setups, 0) + 1} end
            ),
            LangEx.Middleware.ToolApproval.new(tools: :all)
          ],
          checkpointer: LangEx.Checkpointer.Memory
        )

      config = [thread_id: "lifecycle-resume"]

      assert {:interrupt, _payload, paused} = LangEx.invoke(graph, opening(), config: config)
      assert paused.setups == 1

      assert {:ok, result} = LangEx.invoke(graph, %Command{resume: :approve}, config: config)

      assert result.setups == 1
    end
  end

  describe "wrap_tool_call composition" do
    test "wrappers nest with the first-declared outermost" do
      requests_a_tool()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [echo_tool()],
          middleware: [
            Middleware.new(name: :outer, wrap_tool_call: tracer(:outer)),
            Middleware.new(name: :inner, wrap_tool_call: tracer(:inner))
          ]
        )

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:enter, :outer}
      assert_received {:enter, :inner}
      assert_received {:leave, :inner}
      assert_received {:leave, :outer}
    end

    test "a wrapper can answer a call without running the tool" do
      requests_a_tool()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [echo_tool()],
          middleware: [
            Middleware.new(
              name: :cache,
              wrap_tool_call: fn request, _execute ->
                Message.tool("from cache", request.tool_call.id)
              end
            )
          ]
        )

      {:ok, result} = LangEx.invoke(graph, opening())

      refute_received {:ran, _args}

      assert %Message.Tool{content: "from cache"} =
               Enum.find(result.messages, &match?(%Message.Tool{}, &1))
    end

    test "the agent's own interceptor still runs inside the stack's" do
      requests_a_tool()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [echo_tool()],
          tool_opts: [wrap_tool_call: tracer(:agent)],
          middleware: [Middleware.new(name: :stack, wrap_tool_call: tracer(:stack))]
        )

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:enter, :stack}
      assert_received {:enter, :agent}
      assert_received {:ran, _args}
    end
  end

  defp agent(middleware) do
    Prebuilt.agent(provider: LangEx.LLM.OpenAI, model: "gpt-4o", middleware: [middleware])
  end

  defp record(state, name), do: %{order: Map.get(state, :order, []) ++ [name]}

  # Tool calls run in their own task, so the trace closes over the test
  # process rather than relying on `self()` at call time.
  defp tracer(name) do
    test_pid = self()
    fn request, execute -> trace(request, execute, name, test_pid) end
  end

  defp trace(request, execute, name, pid) do
    send(pid, {:enter, name})

    request
    |> execute.()
    |> tap(fn _result -> send(pid, {:leave, name}) end)
  end

  defp loop_once(state) do
    state
    |> Map.get(:messages, [])
    |> Enum.count(&match?(%Message.AI{}, &1))
    |> jump()
  end

  defp jump(1), do: %{Middleware.jump_key() => :model}
  defp jump(_n), do: %{}

  defp loops_once, do: answers()

  defp answers do
    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
      {:ok, Message.ai("answer"), %{input_tokens: 1, output_tokens: 1}}
    end)
  end

  defp record_calls do
    test_pid = self()

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
      send(test_pid, {:called, messages})
      {:ok, Message.ai("answer"), %{input_tokens: 1, output_tokens: 1}}
    end)
  end

  defp requests_a_tool do
    counter = :counters.new(1, [])

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
      :counters.add(counter, 1, 1)

      counter
      |> :counters.get(1)
      |> tool_or_answer()
    end)
  end

  defp tool_or_answer(1) do
    {:ok,
     Message.ai(nil,
       id: "ai-1",
       tool_calls: [%Message.ToolCall{name: "echo", id: "call-1", args: %{"text" => "hi"}}]
     ), %{input_tokens: 1, output_tokens: 1}}
  end

  defp tool_or_answer(_n), do: {:ok, Message.ai("done"), %{input_tokens: 1, output_tokens: 1}}

  defp opening, do: %{messages: [Message.human("hi")]}

  defp echo_tool do
    test_pid = self()

    %Tool{
      name: "echo",
      description: "echoes",
      parameters: %{},
      function: fn args ->
        send(test_pid, {:ran, args})
        args["text"]
      end
    }
  end
end
