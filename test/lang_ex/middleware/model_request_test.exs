defmodule LangEx.Middleware.ModelRequestTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Middleware
  alias LangEx.Middleware.ModelRequest
  alias LangEx.Prebuilt
  alias LangEx.Tool

  describe "redirecting the call" do
    test "a middleware can send a hard turn to a stronger model" do
      record_calls()
      graph = agent(overriding(model: {LangEx.LLM.OpenAI, "gpt-5"}))

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:called, _messages, opts}
      assert opts[:model] == "gpt-5"
    end

    test "a model named as a string resolves its own provider" do
      record_calls()
      graph = agent(overriding(model: "gpt-4o-mini"))

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:called, _messages, opts}
      assert opts[:model] == "gpt-4o-mini"
    end

    test "a middleware can replace the system prompt for one call" do
      record_calls()
      graph = agent(overriding(system_prompt: "You are terse."), system_prompt: "You are chatty.")

      {:ok, result} = LangEx.invoke(graph, opening())

      assert_received {:called, messages, _opts}
      assert [%Message.System{content: "You are terse."} | _] = messages

      refute Enum.any?(result.messages, &match?(%Message.System{}, &1))
    end

    test "a middleware can force the model to use a tool" do
      record_calls()
      graph = agent(overriding(tool_choice: :required), tools: [search_tool()])

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:called, _messages, opts}
      assert opts[:tool_choice] == :required
    end

    test "provider options are layered over the agent's own" do
      record_calls()
      graph = agent(overriding(opts: [temperature: 0.0]))

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:called, _messages, opts}
      assert opts[:temperature] == 0.0
      assert opts[:model] == "gpt-4o"
    end
  end

  describe "guard rails" do
    test "overriding the working state is refused" do
      request = ModelRequest.new(messages: [], tools: [], state: %{})

      assert_raise ArgumentError, ~r/cannot override \[:state\]/, fn ->
        ModelRequest.override(request, state: %{tampered: true})
      end
    end

    test "a misspelled override fails instead of being ignored" do
      request = ModelRequest.new(messages: [], tools: [], state: %{})

      assert_raise ArgumentError, ~r/cannot override \[:models\]/, fn ->
        ModelRequest.override(request, models: ["gpt-5"])
      end
    end
  end

  describe "composition" do
    test "the outer middleware sees what the inner one asked for" do
      record_calls()

      graph =
        Prebuilt.agent(
          provider: LangEx.LLM.OpenAI,
          model: "gpt-4o",
          middleware: [
            overriding(model: {LangEx.LLM.OpenAI, "gpt-5"}),
            overriding(opts: [temperature: 0.5])
          ]
        )

      {:ok, _result} = LangEx.invoke(graph, opening())

      assert_received {:called, _messages, opts}
      assert opts[:model] == "gpt-5"
      assert opts[:temperature] == 0.5
    end
  end

  defp agent(middleware, opts \\ []) do
    [provider: LangEx.LLM.OpenAI, model: "gpt-4o", middleware: [middleware]]
    |> Keyword.merge(opts)
    |> Prebuilt.agent()
  end

  defp overriding(changes) do
    Middleware.new(
      name: :overrider,
      wrap_model_call: fn request, next ->
        request
        |> ModelRequest.override(changes)
        |> next.()
      end
    )
  end

  defp record_calls do
    test_pid = self()

    stub(LangEx.LLM.OpenAI, :chat_with_usage, fn messages, opts ->
      send(test_pid, {:called, messages, opts})
      {:ok, Message.ai("done"), %{input_tokens: 1, output_tokens: 1}}
    end)
  end

  defp opening, do: %{messages: [Message.human("hi")]}

  defp search_tool,
    do: %Tool{name: "search", description: "search", parameters: %{}, function: fn _ -> "ok" end}
end
