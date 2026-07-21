defmodule LangEx.Store do
  @moduledoc """
  Long-term key-value memory that outlives a single thread.

  Checkpoints persist one conversation; a store persists knowledge
  *across* conversations — user preferences, learned facts, past
  decisions. Entries live under a hierarchical namespace (a list of
  strings, e.g. `["memories", user_id]`) with a string key.

  ## Attaching a store to a graph

      graph = Graph.compile(builder, store: LangEx.Store.ETS)
      # or with backend config:
      graph = Graph.compile(builder, store: {LangEx.Store.Postgres, repo: MyApp.Repo})

  Inside node functions and tools the attached store is reachable
  through the convenience API, no plumbing required:

      Graph.add_node(:remember, fn state ->
        :ok = LangEx.Store.put(["memories", state.user_id], "diet", "vegan")
        %{}
      end)

  Tool functions receive it as `request.store` in `wrap_tool_call`
  interceptors and via the same convenience API.

  ## Built-in backends

  - `LangEx.Store.ETS` — in-memory, per-VM (development / tests)
  - `LangEx.Store.Postgres` — durable, via Ecto (see `LangEx.Migration`)
  """

  @type namespace :: [String.t()]
  @type key :: String.t()
  @type config :: keyword()

  @doc "Fetches a value."
  @callback get(config(), namespace(), key()) :: {:ok, term()} | :none | {:error, term()}

  @doc "Writes a value (upsert)."
  @callback put(config(), namespace(), key(), term()) :: :ok | {:error, term()}

  @doc "Deletes a value."
  @callback delete(config(), namespace(), key()) :: :ok | {:error, term()}

  @doc """
  Lists `{key, value}` pairs in a namespace.

  Options:

  - `:prefix` - key prefix filter (default `""`)
  - `:limit` - maximum entries returned (default `100`)
  - `:query` - natural-language query for semantic ranking. When the
    backend has an embedder configured (see `LangEx.Store.ETS`), results
    are ordered by cosine similarity (highest first) instead of by key;
    backends without an embedder ignore it and fall back to prefix order.
  """
  @callback search(config(), namespace(), keyword()) :: [{key(), term()}] | {:error, term()}

  @doc "Fetches a value from the store attached to the running graph."
  @spec get(namespace(), key()) :: {:ok, term()} | :none | {:error, term()}
  def get(namespace, key), do: call_attached(:get, [namespace, key])

  @doc "Writes a value to the store attached to the running graph."
  @spec put(namespace(), key(), term()) :: :ok | {:error, term()}
  def put(namespace, key, value), do: call_attached(:put, [namespace, key, value])

  @doc "Deletes a value from the store attached to the running graph."
  @spec delete(namespace(), key()) :: :ok | {:error, term()}
  def delete(namespace, key), do: call_attached(:delete, [namespace, key])

  @doc "Searches the store attached to the running graph."
  @spec search(namespace(), keyword()) :: [{key(), term()}] | {:error, term()}
  def search(namespace, opts \\ []), do: call_attached(:search, [namespace, opts])

  @doc """
  Returns the `{module, config}` store attached to the running graph,
  or `nil` when none is configured.
  """
  @spec attached() :: {module(), config()} | nil
  def attached, do: Process.get(:lang_ex_store)

  @doc false
  @spec normalize(module() | {module(), config()} | nil) :: {module(), config()} | nil
  def normalize(nil), do: nil
  def normalize({module, config}) when is_atom(module) and is_list(config), do: {module, config}
  def normalize(module) when is_atom(module), do: {module, []}

  defp call_attached(fun_name, args) do
    attached()
    |> dispatch_attached(fun_name, args)
  end

  defp dispatch_attached(nil, _fun_name, _args), do: {:error, :no_store_attached}

  defp dispatch_attached({module, config}, fun_name, args),
    do: apply(module, fun_name, [config | args])
end
