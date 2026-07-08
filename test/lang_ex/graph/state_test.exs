defmodule LangEx.Graph.StateTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph.State

  describe "parse_schema/1" do
    test "splits defaults and reducers" do
      {initial, reducers} =
        State.parse_schema(count: 0, log: {[], &Kernel.++/2}, label: nil)

      assert %{count: 0, log: [], label: nil} = initial
      assert Map.keys(reducers) == [:log]
    end

    test "an empty schema yields empty state and no reducers" do
      assert State.parse_schema([]) == {%{}, %{}}
    end

    test "a two-element tuple default without a function is a plain default" do
      {initial, reducers} = State.parse_schema(range: {1, 10})

      assert %{range: {1, 10}} = initial
      assert reducers == %{}
    end
  end

  describe "apply_update/3" do
    test "keys without reducers are last-write-wins" do
      assert State.apply_update(%{a: 1, b: 2}, %{a: 10}, %{}) == %{a: 10, b: 2}
    end

    test "registered reducers merge old and new values" do
      reducers = %{log: &Kernel.++/2}

      assert State.apply_update(%{log: [1]}, %{log: [2, 3]}, reducers) == %{log: [1, 2, 3]}
    end

    test "unknown keys in the update are added" do
      assert State.apply_update(%{a: 1}, %{b: 2}, %{}) == %{a: 1, b: 2}
    end

    test "an empty update returns the state unchanged" do
      assert State.apply_update(%{a: 1}, %{}, %{}) == %{a: 1}
    end

    test "sequential updates through a reducer accumulate in order" do
      reducers = %{log: &Kernel.++/2}

      result =
        %{log: []}
        |> State.apply_update(%{log: [:first]}, reducers)
        |> State.apply_update(%{log: [:second]}, reducers)

      assert result == %{log: [:first, :second]}
    end
  end
end
