defmodule LangEx.MiddlewareTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "contributions" do
    test "collects tools and merges state schema across the stack" do
      tool = %Tool{name: "t", description: "d", parameters: %{}}

      stack = [
        Middleware.new(name: :a, tools: [tool], state_schema: [foo: 0]),
        Middleware.new(name: :b, state_schema: [bar: nil])
      ]

      assert [%Tool{name: "t"}] = Middleware.tools(stack)
      assert [foo: 0, bar: nil] = Middleware.state_schema(stack)
    end
  end

  describe "before_model" do
    test "its update reaches the model and is persisted" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, _opts ->
        send(test_pid, {:sent, messages})
        {:ok, Message.ai("done"), %{input_tokens: 1, output_tokens: 1}}
      end)

      tagger =
        Middleware.new(
          name: :tagger,
          before_model: fn _state -> %{messages: [Message.human("INJECTED")]} end
        )

      graph = Prebuilt.agent(provider: LangEx.LLM.OpenAI, model: "gpt-4o", middleware: [tagger])
      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("hi")]})

      assert_received {:sent, sent}
      assert Enum.any?(sent, &match?(%Message.Human{content: "INJECTED"}, &1))
      assert Enum.any?(result.messages, &match?(%Message.Human{content: "INJECTED"}, &1))
      assert %Message.AI{content: "done"} = List.last(result.messages)
    end
  end

  describe "after_model routing" do
    test "a :model jump loops the agent for another pass" do
      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, _opts ->
        {:ok, Message.ai("answer"), %{input_tokens: 1, output_tokens: 1}}
      end)

      looper =
        Middleware.new(
          name: :looper,
          state_schema: [loops: 0],
          after_model: fn state -> loop_once(state.loops) end
        )

      graph = Prebuilt.agent(provider: LangEx.LLM.OpenAI, model: "gpt-4o", middleware: [looper])
      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("go")]})

      assert result.loops == 1
      assert 2 == Enum.count(result.messages, &match?(%Message.AI{content: "answer"}, &1))
      assert result.__agent_jump__ == nil
    end
  end

  describe "wrap_model_call" do
    test "can narrow the tools offered to the model" do
      test_pid = self()

      stub(LangEx.LLM.OpenAI, :chat_with_usage, fn _messages, opts ->
        send(test_pid, {:tools, opts[:tools]})
        {:ok, Message.ai("ok"), %{input_tokens: 1, output_tokens: 1}}
      end)

      first_only =
        Middleware.new(
          name: :narrow,
          wrap_model_call: fn request, next ->
            next.(%{request | tools: Enum.take(request.tools, 1)})
          end
        )

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          tools: [tool("a"), tool("b")],
          middleware: [first_only]
        )

      {:ok, _result} = LangEx.invoke(graph, %{messages: [Message.human("hi")]})

      assert_received {:tools, [%Tool{name: "a"}]}
    end
  end

  defp loop_once(0), do: %{:loops => 1, LangEx.Middleware.jump_key() => :model}
  defp loop_once(_), do: %{}

  defp tool(name), do: %Tool{name: name, description: "the #{name} tool", parameters: %{}}
end
