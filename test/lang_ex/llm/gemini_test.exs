defmodule LangEx.LLM.GeminiTest do
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

  @search_tool %Tool{
    name: "search",
    description: "Search documents",
    parameters: %{
      type: "object",
      properties: %{
        query: %{type: "string"},
        results: %{type: "array", items: %{type: "integer"}}
      },
      required: ["query"]
    }
  }

  describe "tool formatting" do
    test "uppercases schema types" do
      expect(Req, :post, fn _url, opts ->
        [%{functionDeclarations: [decl]}] = opts[:json].tools

        assert %{name: "get_weather", parameters: params} = decl
        assert params.type == "OBJECT"
        assert params.properties.location.type == "STRING"

        {:ok,
         %{
           status: 200,
           body: %{
             "candidates" => [
               %{"content" => %{"parts" => [%{"text" => "It's sunny"}]}}
             ]
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "It's sunny"}} =
               LangEx.LLM.Gemini.chat(
                 [Message.human("Weather?")],
                 tools: [@weather_tool],
                 model: "gemini-2.5-flash",
                 api_key: "test"
               )
    end

    test "uppercases nested array item types" do
      expect(Req, :post, fn _url, opts ->
        [%{functionDeclarations: [decl]}] = opts[:json].tools

        assert %{parameters: %{properties: %{results: arr}}} = decl
        assert arr.type == "ARRAY"
        assert arr.items.type == "INTEGER"

        {:ok,
         %{
           status: 200,
           body: %{
             "candidates" => [
               %{"content" => %{"parts" => [%{"text" => "ok"}]}}
             ]
           }
         }}
      end)

      LangEx.LLM.Gemini.chat(
        [Message.human("test")],
        tools: [@search_tool],
        model: "gemini-2.5-flash",
        api_key: "test"
      )
    end
  end

  describe "tool_choice" do
    test "forces a named function via function_calling_config" do
      expect(Req, :post, fn _url, opts ->
        assert %{function_calling_config: %{mode: "ANY", allowed_function_names: ["respond"]}} =
                 opts[:json].tool_config

        {:ok,
         %{
           status: 200,
           body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}]}
         }}
      end)

      LangEx.LLM.Gemini.chat(
        [Message.human("hi")],
        tools: [@weather_tool],
        model: "gemini-2.5-flash",
        api_key: "test",
        tool_choice: {:tool, "respond"}
      )
    end

    test "maps :required to ANY mode" do
      expect(Req, :post, fn _url, opts ->
        assert %{function_calling_config: %{mode: "ANY"}} = opts[:json].tool_config

        {:ok,
         %{
           status: 200,
           body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}]}
         }}
      end)

      LangEx.LLM.Gemini.chat(
        [Message.human("hi")],
        tools: [@weather_tool],
        model: "gemini-2.5-flash",
        api_key: "test",
        tool_choice: :required
      )
    end
  end

  describe "streaming" do
    @sse_hello """
    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]},"index":0}]}

    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"lo"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2,"totalTokenCount":5}}
    """

    test "on_token hits streamGenerateContent with :into set" do
      test_pid = self()

      expect(Req, :post, fn url, opts ->
        assert url =~ "streamGenerateContent"
        assert url =~ "alt=sse"
        assert is_function(opts[:into], 2)
        refute url =~ ":generateContent?"
        refute Map.has_key?(opts[:json], :stream)
        assert {"x-goog-api-key", "test"} in opts[:headers]

        {:ok, %{status: 200, body: @sse_hello}}
      end)

      assert {:ok, %Message.AI{content: "Hello"}, %{input_tokens: 3, output_tokens: 2}} =
               LangEx.LLM.Gemini.chat_with_usage(
                 [Message.human("hi")],
                 model: "gemini-2.0-flash",
                 api_key: "test",
                 on_token: &send(test_pid, {:token, &1})
               )

      assert_received {:token, "Hel"}
      assert_received {:token, "lo"}
    end

    test "stream: true uses the :into callback accumulator" do
      expect(Req, :post, fn url, opts ->
        assert url =~ "streamGenerateContent"
        assert is_function(opts[:into], 2)
        {:cont, _} = opts[:into].({:data, @sse_hello}, {nil, nil})
        {:ok, %{status: 200, body: ""}}
      end)

      assert {:ok, %Message.AI{content: "Hello"}} =
               LangEx.LLM.Gemini.chat(
                 [Message.human("hi")],
                 model: "gemini-2.0-flash",
                 api_key: "test",
                 stream: true
               )
    end

    test "batch still hits generateContent" do
      expect(Req, :post, fn url, opts ->
        assert url =~ ":generateContent"
        refute url =~ "streamGenerateContent"
        assert is_nil(opts[:into])

        {:ok,
         %{
           status: 200,
           body: %{
             "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}]
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "ok"}} =
               LangEx.LLM.Gemini.chat(
                 [Message.human("hi")],
                 model: "gemini-2.0-flash",
                 api_key: "test"
               )
    end
  end
end
