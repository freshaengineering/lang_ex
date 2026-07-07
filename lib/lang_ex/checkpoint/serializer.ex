defmodule LangEx.Checkpoint.Serializer do
  @moduledoc """
  Lossless JSON-safe encoding for checkpoint payloads.

  Graph state holds arbitrary Elixir terms — message structs, atoms,
  tuples, and maps with non-string keys. Plain JSON encoding destroys
  those shapes: structs come back as string-keyed maps and pattern
  matching on restored state breaks. This serializer tags each rich
  term so `decode/1` rebuilds the exact original value.

  Decoding never creates atoms: module and field names are resolved
  with `String.to_existing_atom/1`, so a malicious or corrupted payload
  cannot exhaust the atom table.

  ## Encoding scheme

  | Term            | Encoded form                                    |
  |-----------------|-------------------------------------------------|
  | `nil`/bool/num  | as-is                                           |
  | UTF-8 binary    | as-is                                           |
  | other binary    | `%{"~b" => base64}`                             |
  | atom            | `%{"~a" => "name"}`                             |
  | tuple           | `%{"~t" => [encoded...]}`                       |
  | struct          | `%{"~s" => "Elixir.Mod", "~f" => %{...}}`       |
  | map             | `%{"~m" => [[encoded_key, encoded_value], ...]}`|
  | list            | JSON array of encoded elements                  |
  """

  @doc "Encodes a term into a JSON-compatible representation."
  @spec encode(term()) :: term()
  def encode(term) when is_number(term), do: term
  def encode(term) when is_nil(term) or is_boolean(term), do: term
  def encode(term) when is_binary(term), do: encode_binary(String.valid?(term), term)
  def encode(term) when is_atom(term), do: %{"~a" => Atom.to_string(term)}
  def encode(term) when is_list(term), do: Enum.map(term, &encode/1)

  def encode(term) when is_tuple(term),
    do: %{"~t" => term |> Tuple.to_list() |> Enum.map(&encode/1)}

  def encode(%module{} = term) do
    %{
      "~s" => Atom.to_string(module),
      "~f" =>
        term
        |> Map.from_struct()
        |> Map.new(fn {key, value} -> {Atom.to_string(key), encode(value)} end)
    }
  end

  def encode(term) when is_map(term),
    do: %{"~m" => Enum.map(term, fn {key, value} -> [encode(key), encode(value)] end)}

  def encode(term) do
    raise ArgumentError,
          "cannot serialize #{inspect(term)} into a checkpoint — " <>
            "functions, pids, ports, and references are not persistable"
  end

  @doc "Decodes a term previously produced by `encode/1`."
  @spec decode(term()) :: term()
  def decode(%{"~a" => name}), do: String.to_existing_atom(name)
  def decode(%{"~b" => base64}), do: Base.decode64!(base64)
  def decode(%{"~t" => items}), do: items |> Enum.map(&decode/1) |> List.to_tuple()

  def decode(%{"~s" => module_name, "~f" => fields}) do
    struct!(
      resolve_module!(module_name),
      Map.new(fields, fn {key, value} -> {String.to_existing_atom(key), decode(value)} end)
    )
  end

  def decode(%{"~m" => pairs}),
    do: Map.new(pairs, fn [key, value] -> {decode(key), decode(value)} end)

  def decode(term) when is_list(term), do: Enum.map(term, &decode/1)

  def decode(term) when is_map(term),
    do: Map.new(term, fn {key, value} -> {key, decode(value)} end)

  def decode(term), do: term

  defp encode_binary(true, term), do: term
  defp encode_binary(false, term), do: %{"~b" => Base.encode64(term)}

  defp resolve_module!(module_name) do
    module = String.to_existing_atom(module_name)
    {:module, ^module} = Code.ensure_loaded(module)
    module
  end
end
