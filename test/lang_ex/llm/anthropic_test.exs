defmodule LangEx.LLM.AnthropicTest do
  use ExUnit.Case, async: false
  use Mimic

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
    test "uses input_schema key with cache_control on last tool" do
      expect(Req, :post, fn _url, opts ->
        [tool] = opts[:json].tools

        assert %{
                 name: "get_weather",
                 description: "Get current weather",
                 input_schema: %{type: "object", properties: %{location: _}},
                 cache_control: %{"type" => "ephemeral"}
               } = tool

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "It's sunny"}],
             "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "It's sunny"}} =
               LangEx.LLM.Anthropic.chat(
                 [Message.human("Weather?")],
                 tools: [@weather_tool],
                 model: "claude-sonnet-4-20250514",
                 api_key: "test",
                 stream: false,
                 prompt_caching: true
               )
    end

    test "preserves parameter types as lowercase" do
      expect(Req, :post, fn _url, opts ->
        [%{input_schema: schema}] = opts[:json].tools

        assert schema.type == "object"

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("test")],
        tools: [@weather_tool],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false
      )
    end
  end

  describe "chat_with_usage/2" do
    test "returns usage alongside AI message" do
      expect(Req, :post, fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "Hello!"}],
             "usage" => %{
               "input_tokens" => 42,
               "output_tokens" => 10,
               "cache_creation_input_tokens" => 5,
               "cache_read_input_tokens" => 3
             }
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "Hello!"}, usage} =
               LangEx.LLM.Anthropic.chat_with_usage(
                 [Message.human("Hi")],
                 model: "claude-sonnet-4-20250514",
                 api_key: "test",
                 stream: false
               )

      assert %{
               input_tokens: 42,
               output_tokens: 10,
               cache_creation_input_tokens: 5,
               cache_read_input_tokens: 3
             } = usage
    end
  end

  describe "streaming SSE parsing" do
    test "parses SSE text response" do
      sse_body =
        [
          ~s(data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}),
          ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}),
          ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}),
          ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}),
          ~s(data: {"type":"message_delta","usage":{"output_tokens":5}})
        ]
        |> Enum.join("\n")

      expect(Req, :post, fn _url, _opts ->
        {:ok, %{status: 200, body: sse_body}}
      end)

      assert {:ok, %Message.AI{content: "Hello world"}, usage} =
               LangEx.LLM.Anthropic.chat_with_usage(
                 [Message.human("Hi")],
                 model: "claude-sonnet-4-20250514",
                 api_key: "test"
               )

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
    end

    test "parses SSE tool use response" do
      sse_body =
        [
          ~s(data: {"type":"message_start","message":{"usage":{"input_tokens":20}}}),
          ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"get_weather"}}),
          ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\""}}),
          ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":": \\"London\\"}"}}),
          ~s(data: {"type":"message_delta","usage":{"output_tokens":8}})
        ]
        |> Enum.join("\n")

      expect(Req, :post, fn _url, _opts ->
        {:ok, %{status: 200, body: sse_body}}
      end)

      assert {:ok, %Message.AI{tool_calls: [call]}, _usage} =
               LangEx.LLM.Anthropic.chat_with_usage(
                 [Message.human("Weather?")],
                 model: "claude-sonnet-4-20250514",
                 api_key: "test"
               )

      assert %Message.ToolCall{name: "get_weather", id: "tu_1", args: %{"location" => "London"}} =
               call
    end
  end

  describe "prompt caching" do
    test "system prompt gets cache_control when caching enabled" do
      expect(Req, :post, fn _url, opts ->
        assert [%{"type" => "text", "text" => "Be helpful", "cache_control" => _}] =
                 opts[:json].system

        assert Enum.any?(opts[:headers], fn {k, _} -> k == "anthropic-beta" end)

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.system("Be helpful"), Message.human("test")],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        prompt_caching: true
      )
    end

    test "no cache headers when caching disabled" do
      expect(Req, :post, fn _url, opts ->
        refute Enum.any?(opts[:headers], fn {k, _} -> k == "anthropic-beta" end)
        assert is_binary(opts[:json].system)

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.system("Be helpful"), Message.human("test")],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        prompt_caching: false
      )
    end
  end

  describe "thinking support" do
    test "sends thinking config when enabled" do
      expect(Req, :post, fn _url, opts ->
        assert %{type: "adaptive"} = opts[:json].thinking
        refute Map.has_key?(opts[:json], :temperature)

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "thought about it"}],
             "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "thought about it"}} =
               LangEx.LLM.Anthropic.chat(
                 [Message.human("think")],
                 model: "claude-sonnet-4-20250514",
                 api_key: "test",
                 stream: false,
                 thinking: true
               )
    end
  end

  describe "model-aware max_tokens" do
    test "sonnet models get 64K default" do
      expect(Req, :post, fn _url, opts ->
        assert opts[:json].max_tokens == 64_000

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("test")],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false
      )
    end

    test "non-sonnet models get 128K default" do
      expect(Req, :post, fn _url, opts ->
        assert opts[:json].max_tokens == 128_000

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 2}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("test")],
        model: "claude-opus-4-6",
        api_key: "test",
        stream: false
      )
    end
  end

  describe "tool_choice" do
    test "forces a named tool" do
      expect(Req, :post, fn _url, opts ->
        assert %{"type" => "tool", "name" => "respond"} = opts[:json].tool_choice

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("hi")],
        tools: [@weather_tool],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        tool_choice: {:tool, "respond"}
      )
    end

    test "drops a forced tool_choice when extended thinking is enabled" do
      expect(Req, :post, fn _url, opts ->
        refute Map.has_key?(opts[:json], :tool_choice)
        assert %{type: "adaptive"} = opts[:json].thinking

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("hi")],
        tools: [@weather_tool],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        thinking: true,
        tool_choice: {:tool, "respond"}
      )
    end

    test "maps :required to the any type" do
      expect(Req, :post, fn _url, opts ->
        assert %{"type" => "any"} = opts[:json].tool_choice

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("hi")],
        tools: [@weather_tool],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        tool_choice: :required
      )
    end
  end

  describe "conversation caching" do
    test "marks a cache breakpoint on the last message when caching is enabled" do
      expect(Req, :post, fn _url, opts ->
        assert %{content: [%{"cache_control" => %{"type" => "ephemeral"}, "text" => "second"}]} =
                 List.last(opts[:json].messages)

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("first"), Message.human("second")],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        prompt_caching: true
      )
    end

    test "does not touch messages when caching is disabled" do
      expect(Req, :post, fn _url, opts ->
        assert %{role: "user", content: "second"} = List.last(opts[:json].messages)

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "ok"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("first"), Message.human("second")],
        model: "claude-sonnet-4-20250514",
        api_key: "test",
        stream: false,
        prompt_caching: false
      )
    end
  end
end
