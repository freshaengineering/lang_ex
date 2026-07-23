defmodule LangEx.Middleware.ToolSelector do
  @moduledoc """
  Middleware that narrows a large tool set before the model call.

  When the agent carries more than `:max_tools` tools, a cheap LLM call
  picks the subset relevant to the current task and only those are offered
  to the main model — cutting prompt size and tool-selection errors. Below
  the threshold the model sees every tool and no extra call is made, so this
  only earns its keep once a tool surface grows large (~15+ tools).

  Implemented as a `wrap_model_call` hook, so it composes with other
  middleware and always defers to the real model call. If the selector call
  fails or returns nothing usable, it falls back to offering every tool. Its
  own (small) token usage is not added to `:llm_usage`.

  ## Options

  - `:model` / `:provider` - the selector model (required; a fast, cheap
    model is ideal)
  - `:max_tools` - offer at most this many tools to the main model
    (default `7`); the selector runs only when more than this are available
  - `:always_include` - tool names always kept regardless of selection
  - `:resilient` and other options are forwarded to the selector call
  """

  alias LangEx.LLM.ChatModel
  alias LangEx.Message
  alias LangEx.Middleware

  @default_max_tools 7
  @middleware_opt_keys [:max_tools, :always_include]

  @selection_schema %{
    "type" => "object",
    "properties" => %{
      "tools" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "names of the tools relevant to the current task"
      }
    },
    "required" => ["tools"]
  }

  @doc "Builds a tool-selection middleware. See the module doc for options."
  @spec new(keyword()) :: Middleware.t()
  def new(opts) do
    Middleware.new(name: :tool_selector, wrap_model_call: wrapper(opts))
  end

  defp wrapper(opts) do
    {mw_opts, llm_opts} = Keyword.split(opts, @middleware_opt_keys)
    max_tools = Keyword.get(mw_opts, :max_tools, @default_max_tools)
    always = Keyword.get(mw_opts, :always_include, [])

    fn request, next ->
      request.tools
      |> length()
      |> narrow(request, next, max_tools, always, llm_opts)
    end
  end

  defp narrow(count, request, next, max_tools, _always, _llm_opts) when count <= max_tools,
    do: next.(request)

  defp narrow(_count, request, next, max_tools, always, llm_opts) do
    request
    |> pick(max_tools, always, llm_opts)
    |> then(&Map.put(request, :tools, &1))
    |> next.()
  end

  defp pick(request, max_tools, always, llm_opts) do
    [Message.system(selector_prompt(request.tools, max_tools)) | recent(request.messages)]
    |> ChatModel.structured(Keyword.put(llm_opts, :schema, @selection_schema))
    |> chosen(request.tools, max_tools, always)
  end

  defp chosen({:ok, %{"tools" => names}}, tools, max_tools, always) when is_list(names) do
    keep = MapSet.new(names ++ always)

    tools
    |> Enum.filter(&MapSet.member?(keep, &1.name))
    |> cap(max_tools, always, tools)
  end

  defp chosen(_result, tools, _max_tools, _always), do: tools

  defp cap([], _max_tools, _always, tools), do: tools

  defp cap(selected, max_tools, always, _tools) do
    {kept, extra} = Enum.split_with(selected, &(&1.name in always))
    kept ++ Enum.take(extra, max_tools - length(kept))
  end

  defp recent(messages) do
    messages
    |> Enum.reject(&match?(%Message.System{}, &1))
    |> Enum.filter(&match?(%Message.Human{}, &1))
    |> Enum.take(-4)
  end

  defp selector_prompt(tools, max_tools) do
    catalog = Enum.map_join(tools, "\n", &"- #{&1.name}: #{&1.description}")

    "Select up to #{max_tools} tools from the catalog that are relevant to the user's " <>
      "current request. Return their exact names.\n\nCatalog:\n#{catalog}"
  end
end
