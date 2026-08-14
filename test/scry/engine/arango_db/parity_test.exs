defmodule Scry.Engine.ArangoDB.ParityTest do
  @moduledoc """
  AGENTS.md's "Parity between multiple implementations" rule, applied
  directly: `scry_docgraph`'s own reference `Scry.DocGraph.Executor`
  (one in-memory space serving both document-tree and graph-node roles
  at once, plus a separate in-memory adjacency map) and this package's
  `Scry.Engine.ArangoDB` (a real collection-and-AQL-traversal-backed
  adapter) are two implementations of the identical fused `DEEP`/
  `PARENT`/`SIBLINGS`/`ANCESTORS` + `VIA`/`PATH` semantics -- the same
  posture already established for `scry_graph`/`scry_engine_neo4j` and
  `scry_document`/`scry_engine_mongodb_driver`/`scry_engine_couchdb`.
  This suite parses one query text *once* (`Scry.DocGraph.parse/1`, the
  same grammar/AST both engines are handed), then runs the exact same
  `%Scry.Core.Query{}` against a byte-for-byte identical fixture --
  `scry_docgraph`'s own `Scry.DocGraphTest` fixture, reused verbatim --
  in both a real ArangoDB container and the reference's own in-memory
  `Conn`, and asserts the results agree.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.Cursor
  alias Scry.DocGraph.Conn, as: RefConn
  alias Scry.DocGraph.Executor, as: RefEngine
  alias Scry.Engine.ArangoDB, as: RealEngine
  alias Scry.Engine.ArangoDB.Conn, as: RealConn

  @database "scry_arangodb_parity_test"

  setup_all do
    {:ok, real_conn} = open_and_seed!()
    %{real_conn: real_conn, ref_conn: fixture_ref_conn()}
  end

  # `scry_docgraph`'s own `Scry.DocGraphTest` fixture, reused verbatim:
  # a small org chart (`company` is the parent of `company.people`)
  # whose people rows are *also* graph nodes, chained by a "knows"
  # edge; `reviews` is an ordinary flat source correlated to a
  # person's own "id".
  defp fixture_ref_conn do
    document = %{
      ["company"] => [%{"name" => "Acme"}],
      ["company", "people"] => [
        %{"id" => "1", "name" => "Alice"},
        %{"id" => "2", "name" => "Bob"},
        %{"id" => "3", "name" => "Carol"}
      ],
      ["reviews"] => [
        %{"person_id" => "1", "score" => 9},
        %{"person_id" => "2", "score" => 7}
      ]
    }

    edges = %{
      {"1", "knows"} => ["2"],
      {"2", "knows"} => ["3"]
    }

    RefConn.new(document, edges)
  end

  defp open_and_seed! do
    {:ok, sys_conn} = RealConn.open(database: "_system")

    # Drop and recreate for a clean slate every run -- collections
    # (and the documents/edges inside them) persist across test runs
    # against a long-lived container, and this fixture inserts
    # documents with explicit `_key` values, which a stale collection
    # from a prior run would reject as a duplicate.
    Arangox.delete(sys_conn.pid, "/_api/database/#{@database}")
    {:ok, %Arangox.Response{}} = Arangox.post(sys_conn.pid, "/_api/database", %{name: @database})

    {:ok, conn} = RealConn.open(database: @database)

    :ok = RealConn.create_collection(conn, "company")
    :ok = RealConn.create_collection(conn, "company__people")
    :ok = RealConn.create_collection(conn, "reviews")
    :ok = RealConn.create_collection(conn, "edge__knows", :edge)

    :ok = RealConn.insert_document(conn, "company", %{name: "Acme"})
    :ok = RealConn.insert_document(conn, "company__people", %{_key: "1", id: "1", name: "Alice"})
    :ok = RealConn.insert_document(conn, "company__people", %{_key: "2", id: "2", name: "Bob"})
    :ok = RealConn.insert_document(conn, "company__people", %{_key: "3", id: "3", name: "Carol"})
    :ok = RealConn.insert_document(conn, "reviews", %{person_id: "1", score: 9})
    :ok = RealConn.insert_document(conn, "reviews", %{person_id: "2", score: 7})

    :ok =
      RealConn.insert_document(conn, "edge__knows", %{
        _from: "company__people/1",
        _to: "company__people/2"
      })

    :ok =
      RealConn.insert_document(conn, "edge__knows", %{
        _from: "company__people/2",
        _to: "company__people/3"
      })

    {:ok, conn}
  end

  defp run_both(source, ref_conn, real_conn) do
    {:ok, query} = Scry.DocGraph.parse(source)
    {:ok, ref_cursor} = RefEngine.run(query, ref_conn)
    {:ok, real_enumerable} = RealEngine.execute(real_conn, query, %{})
    {Cursor.to_list(ref_cursor), Enum.to_list(real_enumerable)}
  end

  for {label, query_text, comparison} <- [
        {"an ordinary query with no pseudo-construct at all",
         "SELECT company.people ORDER BY id { name }", :order_sensitive},
        {"DEEP resolves a source across every matching key",
         "SELECT people DEEP ORDER BY id { name, PARENT { name } }", :order_sensitive},
        {"PARENT, VIA, and a correlated nested SELECT compose in the same body",
         """
         SELECT company.people ORDER BY id {
           name,
           PARENT { name },
           VIA knows { name },
           SELECT reviews WHERE person_id = people.id { score }
         }
         """, :order_sensitive},
        {"a VIA hop's own inner body can nest PARENT",
         """
         SELECT company.people ORDER BY id {
           name,
           VIA knows { name, PARENT { name } }
         }
         """, :order_sensitive},
        # No `ORDER BY` inside this one's own `VIA` body, and `HOPS 1-2`
        # gives two real candidates (Bob at 1 hop, Carol at 2) -- which
        # order they come back in was never a contract either engine
        # makes, the identical "compared sorted" reasoning `scry_engine_
        # neo4j`'s own parity suite already states for the same shape.
        {"PATH resolves the full traversal, ids included, inside a VIA body",
         """
         SELECT company.people WHERE id = "1" {
           name,
           VIA knows HOPS 1-2 { name, PATH }
         }
         """, :sorted}
      ] do
    test "#{label} -- reference and real engine agree", %{
      real_conn: real_conn,
      ref_conn: ref_conn
    } do
      {ref_rows, real_rows} = run_both(unquote(query_text), ref_conn, real_conn)

      case unquote(comparison) do
        :order_sensitive -> assert ref_rows == real_rows
        :sorted -> assert Enum.map(ref_rows, &sort_via/1) == Enum.map(real_rows, &sort_via/1)
      end
    end
  end

  defp sort_via(row) do
    case row do
      %{"via" => via} -> Map.put(row, "via", Enum.sort_by(via, & &1["name"]))
      _no_via -> row
    end
  end

  test "a bare PATH inside a PARENT nested inside a VIA is a clear error, not a stale path", %{
    real_conn: real_conn,
    ref_conn: ref_conn
  } do
    source = ~s(SELECT company.people WHERE id = "1" { VIA knows { PARENT { PATH } } })
    {:ok, query} = Scry.DocGraph.parse(source)

    assert RefEngine.run(query, ref_conn) ==
             {:error, {:unsupported, :path_outside_via}}

    assert RealEngine.execute(real_conn, query, %{}) ==
             {:error, {:unsupported, :path_outside_via}}
  end

  test "GROUP BY alongside any special item is declined explicitly", %{
    real_conn: real_conn,
    ref_conn: ref_conn
  } do
    source = "SELECT company.people GROUP BY id { id, VIA knows { name } }"
    {:ok, query} = Scry.DocGraph.parse(source)

    assert RefEngine.run(query, ref_conn) ==
             {:error, {:unsupported, :special_item_with_group_by}}

    assert RealEngine.execute(real_conn, query, %{}) ==
             {:error, {:unsupported, :special_item_with_group_by}}
  end
end
