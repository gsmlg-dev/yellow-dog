defmodule YellowDog.Server.Control.RevisionTest do
  use ExUnit.Case, async: true

  alias YellowDog.Server.Control.Result
  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @revision String.duplicate("a", 64)

  test "normalizes bounded JSON-safe values, fixed atoms, maps, lists, and UTC DateTimes" do
    value = %{
      state: :running,
      family: :ipv4,
      observed_at: ~U[2026-07-16 01:02:03Z],
      scopes: [:all, :apply],
      values: [nil, true, 12, 1.5, "text"]
    }

    assert {:ok,
            %{
              "state" => "running",
              "family" => "ipv4",
              "observed_at" => "2026-07-16T01:02:03Z",
              "scopes" => ["all", "apply"],
              "values" => [nil, true, 12, 1.5, "text"]
            }} = Result.normalize(value)
  end

  test "rejects normalized key collisions and malformed text" do
    assert_invalid(Result.normalize(%{:name => "one", "name" => "two"}))
    assert_invalid(Result.normalize(%{name: <<255>>}))
  end

  test "rejects unsupported runtime terms and structs without codecs" do
    port = Port.open({:spawn, "cat"}, [])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    for value <- [
          {:tuple, 1},
          self(),
          make_ref(),
          port,
          fn -> :ok end,
          %URI{scheme: "https", host: "example.test"},
          :server_control_unknown_atom
        ] do
      assert_invalid(Result.normalize(value))
    end
  end

  test "rejects excessive depth and scalar or collection sizes" do
    too_deep = Enum.reduce(1..9, "leaf", fn index, nested -> %{"level#{index}" => nested} end)
    too_large_map = Map.new(1..101, &{"key#{&1}", &1})

    for value <- [
          too_deep,
          too_large_map,
          Enum.to_list(1..1_001),
          String.duplicate("x", 1_025),
          9_223_372_036_854_775_808
        ] do
      assert_invalid(Result.normalize(value))
    end
  end

  test "calculates deterministic canonical SHA-256 revisions from stable content" do
    first = %{
      name: "dns",
      nested: %{value: 1, observed_at: ~U[2026-07-16 00:00:00Z]},
      revision: String.duplicate("1", 64),
      local_metadata: %{node: "one", owner: self()}
    }

    second = %{
      "local_metadata" => %{"node" => "two"},
      "revision" => String.duplicate("2", 64),
      "nested" => %{"observed_at" => "2026-07-17T00:00:00Z", "value" => 1},
      "name" => "dns"
    }

    assert {:ok, first_revision} = Revision.calculate(first)
    assert {:ok, ^first_revision} = Revision.calculate(second)
    assert String.match?(first_revision, ~r/\A[0-9a-f]{64}\z/)

    assert {:ok, expected_revision} =
             Digest.calculate(%{"name" => "dns", "nested" => %{"value" => 1}})

    assert first_revision == expected_revision
  end

  test "preserves semantic list order in canonical revisions" do
    assert {:ok, first} = Revision.calculate(%{items: ["a", "b"]})
    assert {:ok, second} = Revision.calculate(%{"items" => ["b", "a"]})
    refute first == second
  end

  test "rejects collisions and unsupported values before hashing" do
    assert_invalid(Revision.calculate(%{:name => "one", "name" => "two"}))
    assert_invalid(Revision.calculate(%{pid: self()}))
  end

  test "allows equal revisions and returns an explicit stale conflict" do
    current = %{service: "dns", state: :running}
    assert {:ok, current_revision} = Revision.calculate(current)
    assert :ok = Revision.check(current_revision, current, :mutation)

    assert {:error,
            %Error{
              code: :conflict,
              message: "stale revision",
              details: %{
                "expected_revision" => @revision,
                "current_revision" => ^current_revision
              }
            }} = Revision.check(@revision, current, :mutation)
  end

  test "enforces missing-resource and nil-precondition policy" do
    current = %{service: "dns", state: :running}

    assert :ok = Revision.check(nil, current, :query)
    assert :ok = Revision.check(nil, :missing, :create)

    assert {:error, %Error{code: :invalid, details: %{"field" => "expected_revision"}}} =
             Revision.check(nil, current, :mutation)

    assert {:error, %Error{code: :conflict, message: "resource already exists"}} =
             Revision.check(nil, current, :create)

    assert {:error, %Error{code: :not_found, message: "resource not found"}} =
             Revision.check(nil, :missing, :mutation)

    assert {:error, %Error{code: :not_found, message: "resource not found"}} =
             Revision.check(@revision, :missing, :create)
  end

  defp assert_invalid({:error, %Error{code: :invalid}}), do: :ok
  defp assert_invalid(other), do: flunk("expected invalid error, got: #{inspect(other)}")
end
