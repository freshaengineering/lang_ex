defmodule LangEx.Middleware.ModelRequest do
  @moduledoc """
  The model call a `wrap_model_call` hook is about to make, as data.

  A middleware receives the request, may derive a changed one, and calls
  `next.(request)` to run it. Because every input to the call is a field
  rather than a closed-over option, a middleware can redirect the call
  itself — escalate to a stronger model for a hard turn, force a specific
  tool, swap the system prompt per user — without the agent needing a
  dedicated option for each case.

  ## Fields

  - `:messages` — the conversation the model will see
  - `:tools` — the tools offered on this call
  - `:state` — the working graph state, for state-derived decisions
  - `:system_prompt` — replaces the leading system message when set
  - `:model` — model string or `{provider_module, model}`, overriding the
    agent's configured model for this call
  - `:tool_choice` — forces tool use, e.g. `:required`, `:none`, or
    `{:tool, "name"}` (honoured by adapters that support it)
  - `:opts` — extra provider options merged into this call
    (`:temperature`, `:max_tokens`, `:thinking`, ...)

  Unset override fields mean "use the agent's configuration", so a
  middleware only states what it wants to change.

  ## Overriding

  Use `override/2` rather than struct update syntax: it rejects unknown
  and non-overridable keys, so a typo fails loudly instead of silently
  doing nothing on the call that mattered.

      Middleware.new(
        name: :escalate,
        wrap_model_call: fn request, next ->
          request
          |> escalate_when_stuck()
          |> next.()
        end
      )

      defp escalate_when_stuck(request) do
        request.state
        |> Map.get(:failed_attempts, 0)
        |> case do
          n when n >= 2 -> ModelRequest.override(request, model: "claude-opus-4-20250514")
          _ -> request
        end
      end
  """

  alias LangEx.Message
  alias LangEx.Tool

  @overridable [:messages, :tools, :system_prompt, :model, :tool_choice, :opts]

  defstruct [:messages, :tools, :state, :system_prompt, :model, :tool_choice, opts: []]

  @type t :: %__MODULE__{
          messages: [Message.t()],
          tools: [Tool.t()],
          state: map(),
          system_prompt: String.t() | nil,
          model: String.t() | {module(), String.t()} | nil,
          tool_choice: term() | nil,
          opts: keyword()
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Returns the request with `changes` applied.

  Raises when a change names something that is not overridable — `:state`
  is read-only, since rewriting the working state from inside the model
  call would diverge from what the agent persists. Use a `before_model`
  hook to change state.
  """
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = request, changes) do
    :ok = validate_changes!(changes)
    struct!(request, changes)
  end

  @doc "The provider options this request implies, layered over the agent's."
  @spec provider_opts(t(), keyword()) :: keyword()
  def provider_opts(%__MODULE__{} = request, base) do
    base
    |> Keyword.merge(request.opts)
    |> Keyword.put(:tools, request.tools)
    |> put_model(request.model)
    |> put_tool_choice(request.tool_choice)
  end

  @doc "The messages this request implies, with its system prompt applied."
  @spec resolved_messages(t()) :: [Message.t()]
  def resolved_messages(%__MODULE__{system_prompt: nil} = request), do: request.messages

  def resolved_messages(%__MODULE__{system_prompt: prompt} = request),
    do: [Message.system(prompt) | drop_leading_system(request.messages)]

  defp drop_leading_system([%Message.System{} | rest]), do: rest
  defp drop_leading_system(messages), do: messages

  defp put_model(opts, nil), do: opts

  defp put_model(opts, {provider, model}),
    do: Keyword.merge(opts, provider: provider, model: model)

  defp put_model(opts, model) when is_binary(model),
    do: opts |> Keyword.delete(:provider) |> Keyword.put(:model, model)

  defp put_tool_choice(opts, nil), do: opts
  defp put_tool_choice(opts, choice), do: Keyword.put(opts, :tool_choice, choice)

  defp validate_changes!(changes) do
    changes
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @overridable))
    |> assert_overridable!()
  end

  defp assert_overridable!([]), do: :ok

  defp assert_overridable!(invalid) do
    raise ArgumentError,
          "cannot override #{inspect(invalid)} on a model request — " <>
            "overridable: #{inspect(@overridable)}"
  end
end
