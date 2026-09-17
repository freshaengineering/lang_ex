defmodule LangEx.LLM.OpenAITest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Graph
  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Tool

  @weather_tool %Tool{
    name: "get_weather",
    description: "Get current weather",
    parameters: %{
      type: "object",
      properties: %{
        location: %{type: "string", description: "City name"},
        units: %{type: "string", enum: ["celsius", "fahrenheit"]}
      },
      required: ["location"]
    }
  }

  describe "tool formatting" do
    test "wraps tool in function type envelope" do
      expect(Req, :post, fn _url, opts ->
        [tool] = opts[:json].tools

        assert %{
                 type: "function",
                 function: %{
                   name: "get_weather",
                   description: "Get current weather",
                   parameters: %{type: "object", properties: %{location: _}}
                 }
               } = tool

        {:ok,
         %{
           status: 200,
           body: %{
             "choices" => [%{"message" => %{"content" => "It's sunny"}}]
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "It's sunny"}} =
               LangEx.LLM.OpenAI.chat(
                 [Message.human("Weather?")],
                 tools: [@weather_tool],
                 model: "gpt-4o-mini",
                 api_key: "test"
               )
    end

    test "preserves parameter types as lowercase" do
      expect(Req, :post, fn _url, opts ->
        [%{function: %{parameters: params}}] = opts[:json].tools

        assert params.type == "object"
        assert params.properties.location.type == "string"

        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => "ok"}}]}
         }}
      end)

      LangEx.LLM.OpenAI.chat(
        [Message.human("test")],
        tools: [@weather_tool],
        model: "gpt-4o-mini",
        api_key: "test"
      )
    end
  end

  describe "streaming" do
    @sse_hello """
    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}],"usage":null}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":null}

    data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}

    data: [DONE]
    """

    test "on_token sends stream: true, include_usage, and :into" do
      test_pid = self()

      expect(Req, :post, fn url, opts ->
        assert url =~ "/chat/completions"
        assert opts[:json].stream == true
        assert opts[:json].stream_options == %{include_usage: true}
        refute Map.has_key?(opts[:json].stream_options, :include_obfuscation)
        assert is_function(opts[:into], 2)

        {:ok, %{status: 200, body: @sse_hello}}
      end)

      assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 3, output_tokens: 2}} =
               LangEx.LLM.OpenAI.chat_with_usage(
                 [Message.human("hi")],
                 model: "gpt-4o-mini",
                 api_key: "test",
                 on_token: &send(test_pid, {:token, &1})
               )

      assert_received {:token, "Hel"}
      assert_received {:token, "lo"}
    end

    test "stream: true uses the :into callback accumulator" do
      expect(Req, :post, fn _url, opts ->
        assert opts[:json].stream == true
        assert is_function(opts[:into], 2)
        {:cont, _} = opts[:into].({:data, @sse_hello}, {nil, nil})
        {:ok, %{status: 200, body: ""}}
      end)

      assert {:ok, %Message.AI{content: "Hello"}} =
               LangEx.LLM.OpenAI.chat(
                 [Message.human("hi")],
                 model: "gpt-4o-mini",
                 api_key: "test",
                 stream: true
               )
    end

    test "without stream opts the request stays batch" do
      expect(Req, :post, fn _url, opts ->
        refute Map.has_key?(opts[:json], :stream)
        refute Map.has_key?(opts[:json], :stream_options)
        assert is_nil(opts[:into])

        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => "ok"}}]}
         }}
      end)

      assert {:ok, %Message.AI{content: "ok"}} =
               LangEx.LLM.OpenAI.chat(
                 [Message.human("hi")],
                 model: "gpt-4o-mini",
                 api_key: "test"
               )
    end

    test "streaming honors base_url" do
      expect(Req, :post, fn url, opts ->
        assert url == "https://openrouter.example/v1/chat/completions"
        assert opts[:json].stream == true
        {:ok, %{status: 200, body: @sse_hello}}
      end)

      assert {:ok, %Message.AI{content: "Hello"}} =
               LangEx.LLM.OpenAI.chat(
                 [Message.human("hi")],
                 model: "gpt-4o-mini",
                 api_key: "test",
                 stream: true,
                 base_url: "https://openrouter.example/v1"
               )
    end

    test "ChatModel.node yields message deltas under :messages stream mode" do
      expect(Req, :post, fn _url, opts ->
        assert opts[:json].stream == true
        assert is_function(opts[:into], 2)
        {:ok, %{status: 200, body: @sse_hello}}
      end)

      events =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(model: "gpt-4o", api_key: "test"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.stream(%{messages: [Message.human("hi")]}, modes: [:messages])
        |> Enum.to_list()

      assert [
               {:message_delta, %{node: :llm, kind: :content, text: "Hel"}},
               {:message_delta, %{node: :llm, kind: :content, text: "lo"}},
               {:done, {:ok, _}}
             ] = events
    end
  end
end
