if Code.ensure_loaded?(OpentelemetryTelemetry) do
  defmodule LangEx.Telemetry.OpenTelemetryBridge do
    @moduledoc """
    Optional OpenTelemetry bridge for LangEx telemetry spans.

    Converts every LangEx span (graph invoke, super-step, node execution,
    LLM call, checkpoint save/load) into an OpenTelemetry span, preserving
    the parent/child structure within a process via `OpentelemetryTelemetry`
    context tracking. `run_id`/`parent_run_id` are attached as attributes,
    so cross-process node spans can still be correlated.

    Only compiled when the optional `opentelemetry_telemetry` dependency
    is present. Attach once at application start:

        LangEx.Telemetry.OpenTelemetryBridge.attach()
    """

    require OpenTelemetry.Tracer

    @tracer_id __MODULE__
    @handler_id "lang-ex-otel-bridge"
    @attribute_keys [
      :run_id,
      :parent_run_id,
      :graph_id,
      :thread_id,
      :node,
      :step,
      :result,
      :provider,
      :model,
      :message_count,
      :status,
      :checkpointer
    ]

    @doc "Attaches the bridge to all LangEx telemetry events."
    @spec attach() :: :ok | {:error, :already_exists}
    def attach do
      :telemetry.attach_many(
        @handler_id,
        LangEx.Telemetry.events(),
        &__MODULE__.handle_event/4,
        %{}
      )
    end

    @doc "Detaches the bridge."
    @spec detach() :: :ok | {:error, :not_found}
    def detach, do: :telemetry.detach(@handler_id)

    @doc false
    def handle_event(event, _measurements, metadata, _config) do
      event
      |> List.last()
      |> handle_span(event, metadata)

      :ok
    end

    defp handle_span(:start, event, metadata) do
      OpentelemetryTelemetry.start_telemetry_span(
        @tracer_id,
        span_name(event),
        metadata,
        %{attributes: attributes(metadata)}
      )
    end

    defp handle_span(:stop, _event, metadata) do
      OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
      OpenTelemetry.Tracer.set_attributes(attributes(metadata))
      OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    end

    defp handle_span(:exception, _event, %{reason: reason} = metadata) do
      OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
      OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, inspect(reason)))
      OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    end

    defp span_name(event) do
      event
      |> Enum.slice(0..-2//1)
      |> Enum.map_join(".", &Atom.to_string/1)
    end

    defp attributes(metadata) do
      metadata
      |> Map.take(@attribute_keys)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {key, attribute_value(value)} end)
    end

    defp attribute_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
      do: value

    defp attribute_value(value) when is_atom(value), do: Atom.to_string(value)
    defp attribute_value(value), do: inspect(value)
  end
end
