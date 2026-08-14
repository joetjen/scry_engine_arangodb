defmodule Scry.Engine.ArangoDBTest do
  @moduledoc """
  `Scry.Engine.ArangoDB` -- confirms behaviors the parity suite
  (`test/scry/engine/arango_db/parity_test.exs`) doesn't naturally
  cover, since `Scry.DocGraph.parse/1`'s own text grammar has no
  syntax for `describe_source/2`, `%Scry.Core.CombinedQuery{}`, a
  `WITH`-bound source, or this package's own real, deliberate
  divergences from the reference (a missing document collection is a
  clear error; a missing `VIA` edge collection is a graceful empty
  result; `SHORTEST` keeps every tie, not just one). All against a
  real ArangoDB container, not just plausible-looking output.

  **Requires a real, reachable ArangoDB instance** -- run one locally
  via `docker run -d --name scry-arangodb -p 8529:8529 -e
  ARANGO_NO_AUTH=1 arangodb:3.11`. Runs `async: false` -- every test
  shares one real server and a small, fixed set of collections,
  dropped and rebuilt (via a fresh database) in `setup_all`.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{CombinedQuery, Query}
  alias Scry.Engine.ArangoDB, as: Engine
  alias Scry.Engine.ArangoDB.Conn

  @database "scry_engine_arangodb_test"

  setup_all do
    {:ok, conn} = open_and_seed!()
    %{conn: conn}
  end

  # A small cyclic graph -- alice -knows-> bob -knows-> carol
  # -knows-> alice -- specifically to exercise `SHORTEST`'s own tie-
  # preserving behavior: carol is reachable from alice via bob (2 hops)
  # and, in a richer graph, could tie; here it mainly proves the cycle
  # doesn't loop forever and `uniqueVertices: "path"` holds.
  defp open_and_seed! do
    {:ok, sys_conn} = Conn.open(database: "_system")
    Arangox.delete(sys_conn.pid, "/_api/database/#{@database}")
    {:ok, %Arangox.Response{}} = Arangox.post(sys_conn.pid, "/_api/database", %{name: @database})

    {:ok, conn} = Conn.open(database: @database)

    :ok = Conn.create_collection(conn, "people")
    :ok = Conn.create_collection(conn, "edge__knows", :edge)

    :ok =
      Conn.insert_document(conn, "people", %{_key: "alice", id: "alice", name: "Alice", age: 30})

    :ok = Conn.insert_document(conn, "people", %{_key: "bob", id: "bob", name: "Bob", age: 25})

    :ok =
      Conn.insert_document(conn, "people", %{_key: "carol", id: "carol", name: "Carol", age: 40})

    :ok = Conn.insert_document(conn, "people", %{_key: "dave", id: "dave", name: "Dave", age: 22})

    :ok = Conn.insert_document(conn, "edge__knows", %{_from: "people/alice", _to: "people/bob"})
    :ok = Conn.insert_document(conn, "edge__knows", %{_from: "people/alice", _to: "people/dave"})
    :ok = Conn.insert_document(conn, "edge__knows", %{_from: "people/bob", _to: "people/carol"})
    :ok = Conn.insert_document(conn, "edge__knows", %{_from: "people/dave", _to: "people/carol"})
    :ok = Conn.insert_document(conn, "edge__knows", %{_from: "people/carol", _to: "people/alice"})

    {:ok, conn}
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list()}
  defp materialize(other), do: other

  defp via_opts(overrides \\ %{}) do
    Map.merge(
      %{
        shortest: false,
        backward: false,
        hops: nil,
        where: nil,
        distinct: false,
        order_bys: [],
        limit: nil,
        offset: nil
      },
      overrides
    )
  end

  describe "a missing document collection is a clear error, matching the reference's strict behavior" do
    test "an ordinary (non-DEEP) source naming a collection that was never created", %{conn: conn} do
      query = %Query{source: ["nonexistent"], select: [{:field, ["name"]}]}

      assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} =
               materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "a missing VIA edge collection is a graceful empty result, not an error" do
    test "no edge of that name exists anywhere", %{conn: conn} do
      query = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "alice"}],
        select: [{:variant, {:via, ["likes"], via_opts(), [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row == %{"via" => []}
    end
  end

  describe "SHORTEST keeps every path tied for minimum length, exact reference parity" do
    test "a tie at minimum depth keeps both, unlike scry_engine_neo4j's own SHORTEST 1", %{
      conn: conn
    } do
      query = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "alice"}],
        select: [
          {:variant,
           {:via, ["knows"], via_opts(%{shortest: true, hops: {1, 10}}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))

      assert Enum.map(row["via"], & &1["name"]) |> Enum.sort() == [
               "Bob",
               "Carol",
               "Carol",
               "Dave"
             ]
    end
  end

  describe "cycle avoidance -- uniqueVertices: \"path\" restores simple-path semantics" do
    test "a path never revisits a node, so the cycle doesn't loop forever", %{conn: conn} do
      query = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "alice"}],
        select: [
          {:variant, {:via, ["knows"], via_opts(%{hops: {1, 10}}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      refute "Alice" in Enum.map(row["via"], & &1["name"])
    end
  end

  describe "BACKWARD -- traverses incoming edges instead of outgoing" do
    test "reaches every node with an edge pointing at the start node", %{conn: conn} do
      query = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "carol"}],
        select: [
          {:variant, {:via, ["knows"], via_opts(%{backward: true}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(row["via"], & &1["name"]) |> Enum.sort() == ["Bob", "Dave"]
    end
  end

  describe "%Scry.Core.CombinedQuery{} and a WITH-bound source" do
    test "CombinedQuery delegates to Scry.Core.QueryOps.run_document/4", %{conn: conn} do
      left = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "alice"}],
        select: [{:field, ["name"]}]
      }

      right = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "bob"}],
        select: [{:field, ["name"]}]
      }

      combined = %CombinedQuery{op: :union, left: left, right: right}

      assert {:ok, rows} = materialize(Engine.execute(conn, combined, %{}))
      assert rows |> Enum.map(& &1["name"]) |> Enum.sort() == ["Alice", "Bob"]
    end

    test "a WITH-bound top-level source runs the binding instead of a real collection", %{
      conn: conn
    } do
      binding = %Query{
        source: ["people"],
        wheres: [{:cmp, :eq, ["id"], "alice"}],
        select: [{:field, ["name"]}]
      }

      query = %Query{
        source: ["alice_only"],
        with_bindings: %{"alice_only" => binding},
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Alice"]
    end
  end

  describe "describe_source/2" do
    test "reports every observed field including id" do
      {:ok, conn} = Conn.open(database: @database)
      assert {:ok, fields} = Engine.describe_source(conn, "people")
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["id"].nullable == false
      assert by_name["name"].scalar == :string
      assert by_name["age"].scalar == :integer
      assert by_name["name"].nullable == true
    end

    test "a collection with no observed documents at all is not found" do
      {:ok, conn} = Conn.open(database: @database)
      assert {:error, :not_found} = Engine.describe_source(conn, "no_such_collection")
    end
  end
end
