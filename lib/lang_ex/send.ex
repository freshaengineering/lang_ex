defmodule LangEx.Send do
  @moduledoc """
  Directs execution to a node with a custom state payload.
  Used for map-reduce patterns where the number of edges is dynamic.

  `:id` identifies this unit of work. It is stamped by the engine when the
  Send is resolved into a super-step and persisted with the checkpoint, so
  each fan-out branch stays individually addressable across a pause and
  resume — two Sends to the same node get their own interrupt IDs and can
  be answered separately. Leave it `nil`; the engine fills it in.
  """
  @enforce_keys [:node, :state]
  defstruct [:node, :state, :id]

  @type t :: %__MODULE__{
          node: atom(),
          state: map(),
          id: String.t() | nil
        }

  @doc false
  @spec stamp(t()) :: t()
  def stamp(%__MODULE__{id: nil} = send),
    do: %{send | id: 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)}

  def stamp(%__MODULE__{} = send), do: send
end
