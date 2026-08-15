defmodule Scry.Engine.ArangoDB do
  @moduledoc """
  A real `Scry.Core.EngineBehaviour` implementation over ArangoDB, via
  [`arangox`](https://hex.pm/packages/arangox) (`Scry.Engine.ArangoDB.
  Conn`'s own moduledoc has the driver choice and two real, confirmed
  findings). Replaces `scry_docgraph`'s own reference implementation
  (`Scry.DocGraph.Executor` -- one in-memory `%{path => rows}` space
  serving both document-tree and graph-node roles at once, plus a
  separate in-memory adjacency map) with genuine collection-and-AQL-
  traversal-backed `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` *and*
  `VIA`/`PATH` execution, each
  independently nestable inside the other -- the document+graph
  composite kind's first real adapter, closing the one remaining kind
  package with a real fused executor and zero real-backend validation
  (`scry_docgraph`'s own moduledoc names ArangoDB directly as the
  deferred candidate for exactly this).

  ArangoDB is a genuinely natural fit, not an arbitrary pick: it's a
  real multi-model database with native document collections *and*
  native graph traversal (edge collections, AQL's own `FOR v, e, p IN
  min..max OUTBOUND/INBOUND ...` syntax) in one query language -- the
  same "validate against the kind's own namesake/most-natural reference
  technology" posture `scry_engine_neo4j` (Cypher, `graph`'s own
  namesake) and `scry_engine_elasticsearch`/`scry_engine_influxdb`
  (each kind's own most SQL-like real language) already established.

  ## Document collection-per-tree-key, joined with `__`

  The identical convention `scry_engine_mongodb_driver`/`scry_engine_
  couchdb` already established for the pure `document` kind: one real
  ArangoDB *document* collection per tree-position key, name the
  segments joined with `__` -- ArangoDB's own collection-naming rule
  disallows a literal `.` outright (confirmed directly, the identical
  restriction `scry_engine_couchdb` already found for CouchDB), so `__`
  is the separator here too, for the identical "still legal, lower
  collision risk than a single `_`" reasoning. `DEEP`/`PARENT`/
  `SIBLINGS`/`ANCESTORS` all resolve via `GET /_api/collection` (ArangoDB's
  own `isSystem`/`type` flags cleanly separate real document
  collections from both ArangoDB's own system collections and this
  package's own edge collections, below -- a real, confirmed-clean
  three-way split, no name-prefix filtering needed the way `scry_engine_
  neo4j`/`scry_engine_couchdb` each needed for their own system/reserved
  names) plus client-side filtering, the identical shape `scry_engine_
  mongodb_driver`'s own `db.listCollections()`-based resolution has.

  ## Edge collections, one per `VIA` edge name, and `_key` doubles as the reference's own required `"id"`

  One real ArangoDB *edge* collection per distinct `VIA` edge name,
  prefixed `edge__` to keep its own name out of the document-tree
  collection namespace (ArangoDB requires every collection name --
  document and edge alike -- unique within one database). Unlike
  `scry_engine_mongodb_driver`/`scry_engine_couchdb` (where the
  driver's own document-identity field is pure internal noise, stripped
  from every row), `scry_docgraph`'s own reference `Conn` explicitly
  requires a graph-participating row to carry a real, user-visible
  `"id"` field (`Scry.DocGraph.Conn`'s own moduledoc: unlike `Scry.
  Graph.Conn`, not every row needs one, but any row that's a `VIA`
  start or edge target does) -- so this package renames ArangoDB's own
  `_key` to `"id"` in every decoded row rather than stripping it, a
  real, deliberate difference from its pure-document siblings, not an
  inconsistency: `_key` and the reference's own required `"id"` are the
  same real thing here, confirmed by the reference's own contract, not
  assumed. `_id`/`_rev`/`_from`/`_to` are still ArangoDB-internal
  routing detail and stay stripped.

  ## `VIA`'s own traversal: one AQL query per hop, `uniqueVertices: "path"`, and client-side `SHORTEST`

  A real, confirmed finding, not assumed: AQL's own variable-length
  traversal does not enforce simple-path semantics by default either
  (the identical divergence `scry_engine_neo4j` already found for
  Cypher) -- but unlike Cypher, ArangoDB has a **native, plugin-free
  fix**: `OPTIONS { uniqueVertices: "path" }`, confirmed directly
  against a real cyclic graph to restore exact simple-path semantics,
  no manual `WHERE ALL(...)` filter construction needed at all.
  `opts.shortest` is *not* translated into any AQL
  `SHORTEST_PATH`/`K_SHORTEST_PATHS` construct -- both name a single
  target, not "shortest to every reachable node" (`VIA`'s own real
  semantics); instead, every simple path within `opts.hops` is fetched
  (the identical query the non-`shortest` case already runs), and
  `keep_shortest/1` -- a direct, line-for-line port of `scry_docgraph`'s
  own reference function -- groups by end-vertex `"id"` and keeps every
  path tied for minimum length, client-side. This is a real, deliberate
  improvement over `scry_engine_neo4j`'s own analogous choice: Neo4j's
  native `SHORTEST 1` clause keeps only *one* path per end node,
  a real, stated divergence from the reference documented there --
  reusing the reference's own tie-preserving algorithm here instead
  means this package has **no such divergence at all**, exact parity
  with the reference on tie-handling.

  Every other `VIA` modifier -- `WHERE`/`ORDER BY`/`DISTINCT`/`LIMIT`/
  `OFFSET` -- applies generically afterward, via `Scry.Core.QueryOps.
  run_flat/3` and a plain `Enum.uniq/1`/drop/take, the identical
  "reference's own predicate evaluator, not a hand-rolled translator"
  posture `scry_engine_neo4j` already established; no AQL `FILTER`/
  `SORT`/`LIMIT` is ever generated for these.

  ## `path_rows` resets to `nil` when recursing into `PARENT`/`SIBLINGS`/`ANCESTORS`

  A real, stated scope decision `scry_docgraph`'s own reference
  `Executor` already makes, reused unchanged here: those three jump to
  an entirely different document position, so the enclosing `VIA`'s own
  traversal no longer describes "how we got here" -- a bare `PATH`
  immediately inside such a body is `{:error, {:unsupported,
  :path_outside_via}}`, the same error it already is anywhere outside a
  `VIA` entirely. A `VIA` nested *inside* one of those three bodies
  starts its own, fresh traversal regardless, so this only affects a
  bare `PATH` with no intervening `VIA` of its own.

  `PARENT`/`SIBLINGS`/`ANCESTORS`/`VIA`/`PATH`/a nested `SELECT`
  combined with `GROUP BY` declines (`{:unsupported,
  :special_item_with_group_by}`, the reference's own atom name, kept
  as-is). `%Scry.Core.CombinedQuery{}`/a `WITH`-bound source both
  delegate to `Scry.Core.QueryOps.run_document/4` rather than declining
  outright the way the reference does -- the same upgrade every real
  adapter past `scry_engine_neo4j` already makes over its own
  reference, since (unlike the reference) this package *is* registered
  as a real `EngineBehaviour` implementation.

  A tree-key-derived collection matching no document at all -- or that
  was never created -- is a clear error (`{:query_error,
  {:no_such_source, source}}`), matching the reference's own strict
  behavior: confirmed directly, an AQL `FOR doc IN <collection>`
  against a collection that doesn't exist is a real, clean error, not
  an empty result (`Scry.Engine.ArangoDB.Conn`'s own moduledoc has the
  full finding) -- the identical divergence-from-Neo4j/MongoDB
  `scry_engine_couchdb` already documents for its own strict-database
  model. A `VIA` edge collection that was never created is different,
  though, and deliberately so: it means *no edge of that name exists
  anywhere*, matching the reference's own graceful `Map.get(adjacency,
  ..., [])` -- an empty `"via"` list, not an error.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps}
  alias Scry.Engine.ArangoDB.Conn

  @docgraph_key_field "__scry_arangodb_key__"
  @path_marker_field "__scry_arangodb_path__"
  @doc_separator "__"
  @edge_prefix "edge__"

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{} = query, params) do
    if with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      run(conn, query, params)
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp run(conn, query, params) do
    with {:ok, matches} <- resolve_source(conn, query.source, deep?(query)) do
      if special_items?(query.select) do
        run_with_special_items(conn, query, matches, params)
      else
        run_flat_over_matches(matches, query, params)
      end
    end
  end

  # Neither a PARENT/SIBLINGS/ANCESTORS/VIA/PATH pseudo-construct nor a
  # nested SELECT anywhere in this query's own top-level select --
  # nothing docgraph-specific to do. Delegating wholesale, unmodified
  # query included, is the correctness-critical path here -- the
  # identical reasoning `scry_docgraph`'s own reference `run/3` states
  # (GROUP BY/aggregation needs `run_flat/3` to see every row belonging
  # to a group at once).
  defp run_flat_over_matches(matches, query, params) do
    rows = Enum.map(matches, fn {_key, row} -> row end)
    QueryOps.run_flat(rows, query, params)
  end

  defp run_with_special_items(conn, query, matches, params) do
    with :ok <- validate_no_grouping(query),
         {:ok, ordered} <- order_and_limit(matches, query, params) do
      own_name = List.last(query.source)
      project_all(ordered, query.select, conn, own_name, params)
    end
  end

  defp special_items?(body_items) do
    Enum.any?(body_items, fn
      {:variant, {kind, _body}} when kind in [:parent, :siblings, :ancestors] -> true
      {:variant, {:via, _edge, _opts, _body}} -> true
      {:variant, :path} -> true
      %Query{} -> true
      _other -> false
    end)
  end

  defp deep?(%Query{variant: %{select_ep1a: :deep}}), do: true
  defp deep?(_query), do: false

  defp validate_no_grouping(%Query{group_bys: []}), do: :ok
  defp validate_no_grouping(_query), do: {:error, {:unsupported, :special_item_with_group_by}}

  defp resolve_source(conn, source, false) do
    collection = doc_collection_name(source)

    case Conn.query(conn, "FOR doc IN @@collection RETURN doc", %{"@collection" => collection}) do
      {:ok, docs} -> {:ok, Enum.map(docs, &{source, decode_doc(&1)})}
      {:error, :not_found} -> {:error, {:query_error, {:no_such_source, source}}}
      {:error, {:query_error, _}} = error -> error
    end
  end

  defp resolve_source(conn, source, true) do
    with {:ok, names} <- Conn.collection_names(conn, :document) do
      keys =
        names
        |> Enum.map(&String.split(&1, @doc_separator))
        |> Enum.filter(&deep_match?(&1, source))
        |> Enum.sort()

      fetch_all(conn, keys)
    end
  end

  defp deep_match?(key, [only]), do: List.last(key) == only

  defp deep_match?(key, source),
    do: List.first(key) == List.first(source) and List.last(key) == List.last(source)

  defp fetch_all(conn, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Conn.query(conn, "FOR doc IN @@collection RETURN doc", %{
             "@collection" => doc_collection_name(key)
           }) do
        {:ok, docs} -> {:cont, {:ok, acc ++ Enum.map(docs, &{key, decode_doc(&1)})}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        {:error, {:query_error, _}} = err -> {:halt, err}
      end
    end)
  end

  defp doc_collection_name(key), do: Enum.join(key, @doc_separator)
  defp edge_collection_name(edge), do: @edge_prefix <> Enum.join(edge, @doc_separator)

  defp decode_doc(doc) do
    {id, rest} = Map.pop(doc, "_key")
    rest |> Map.drop(["_id", "_rev", "_from", "_to"]) |> Map.put("id", id)
  end

  # Threads a unique, synthetic per-row index through `run_flat/3` (not
  # the tree key itself -- two distinct matched rows can legitimately
  # share the same key) so the post-filter/order/limit survivor list
  # can be mapped back to its own original `{key, row}` pair. Mirrors
  # `scry_docgraph`'s reference `Executor`'s own identical technique.
  defp order_and_limit(matches, query, params) do
    indexed = Enum.with_index(matches)
    lookup = Map.new(indexed, fn {{key, row}, idx} -> {idx, {key, row}} end)

    tagged_rows =
      Enum.map(indexed, fn {{_key, row}, idx} -> Map.put(row, @docgraph_key_field, idx) end)

    marker_query = %{query | select: [{:field, [@docgraph_key_field]}]}

    with {:ok, marker_rows} <- QueryOps.run_flat(tagged_rows, marker_query, params) do
      ordered =
        marker_rows
        |> Enum.to_list()
        |> Enum.map(fn %{@docgraph_key_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp project_all(ordered, select, conn, own_name, params) do
    ordered
    |> Enum.map(fn {key, row} -> project_body(key, row, select, nil, conn, own_name, params) end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, row} -> row end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  # Projects one already-resolved `{key, row}` (or `{end_key, end_row}`
  # reached via a `VIA` hop) against `body`. `own_name` is always the
  # *original, top-level* query's own source name, unchanged as this
  # recurses into any pseudo-construct's own nested body -- the
  # identical scope limit the reference already states.
  defp project_body(key, row, body, path_rows, conn, own_name, params) do
    {flat_select, nested_items, pseudo_items, via_items, has_path?} = partition_body(body)

    with {:ok, base} <- project_ordinary(row, flat_select, params),
         {:ok, with_nested} <- add_nested_results(base, nested_items, row, conn, own_name, params),
         {:ok, with_path} <- add_path(with_nested, has_path?, path_rows),
         {:ok, with_pseudo} <-
           add_pseudo_results(with_path, pseudo_items, key, conn, own_name, params) do
      add_via_results(with_pseudo, via_items, key, row, conn, own_name, params)
    end
  end

  defp partition_body(body_items) do
    {flat, nested, pseudo, vias, has_path?} =
      Enum.reduce(body_items, {[], [], [], [], false}, fn item,
                                                          {flat, nested, pseudo, vias, has_path?} ->
        case item do
          %Query{} = q ->
            {flat, [q | nested], pseudo, vias, has_path?}

          {:variant, {kind, item_body}} when kind in [:parent, :siblings, :ancestors] ->
            {flat, nested, [{Atom.to_string(kind), kind, item_body} | pseudo], vias, has_path?}

          {:variant, {:via, edge, opts, inner}} ->
            {flat, nested, pseudo, [{edge, opts, inner} | vias], has_path?}

          {:variant, :path} ->
            {flat, nested, pseudo, vias, true}

          other ->
            {[other | flat], nested, pseudo, vias, has_path?}
        end
      end)

    {Enum.reverse(flat), Enum.reverse(nested), Enum.reverse(pseudo), Enum.reverse(vias),
     has_path?}
  end

  defp add_nested_results(base, [], _row, _conn, _own_name, _params), do: {:ok, base}

  defp add_nested_results(base, nested_items, row, conn, own_name, params) do
    Enum.reduce_while(nested_items, {:ok, base}, fn nested, {:ok, acc} ->
      resolve_nested(nested, acc, row, conn, own_name, params)
    end)
  end

  defp resolve_nested(nested, acc, row, conn, own_name, params) do
    fetch_fn = fn q, p -> fetch_and_drain(conn, q, p) end

    case QueryOps.resolve_correlated_nested(nested, row, own_name, params, fetch_fn) do
      {:ok, rows} -> {:cont, {:ok, Map.put(acc, List.last(nested.source), rows)}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp fetch_and_drain(conn, query, params) do
    with {:ok, enumerable} <- execute(conn, query, params) do
      {:ok, Enum.to_list(enumerable)}
    end
  end

  defp add_path(base, false, _path_rows), do: {:ok, base}
  defp add_path(_base, true, nil), do: {:error, {:unsupported, :path_outside_via}}
  defp add_path(base, true, path_rows), do: {:ok, Map.put(base, "path", path_rows)}

  defp project_ordinary(_row, [], _params), do: {:ok, %{}}

  defp project_ordinary(row, select, params) do
    case QueryOps.run_flat([row], %Query{select: select}, params) do
      {:ok, enumerable} ->
        case Enum.to_list(enumerable) do
          [projected] -> {:ok, projected}
          [] -> {:ok, %{}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp add_pseudo_results(base, [], _key, _conn, _own_name, _params), do: {:ok, base}

  defp add_pseudo_results(base, pseudo_items, key, conn, own_name, params) do
    Enum.reduce_while(pseudo_items, {:ok, base}, fn {output_key, kind, nested_body}, {:ok, acc} ->
      case resolve_pseudo_field(kind, nested_body, key, conn, own_name, params) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, output_key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # `path_rows` is always `nil` inside `PARENT`/`SIBLINGS`/`ANCESTORS` --
  # this module's own moduledoc has the full "why" (a real, stated
  # scope decision the reference already makes, reused unchanged).
  defp resolve_pseudo_field(:parent, body, key, conn, own_name, params) do
    case parent_key(key) do
      nil -> {:ok, nil}
      parent_key -> project_first(parent_key, body, conn, own_name, params)
    end
  end

  defp resolve_pseudo_field(:siblings, body, key, conn, own_name, params) do
    parent = parent_key(key)

    with {:ok, names} <- Conn.collection_names(conn, :document) do
      names
      |> Enum.map(&String.split(&1, @doc_separator))
      |> Enum.filter(&(&1 != key and parent_key(&1) == parent))
      |> Enum.sort()
      |> project_all_rows(body, conn, own_name, params)
    end
  end

  defp resolve_pseudo_field(:ancestors, body, key, conn, own_name, params) do
    key
    |> ancestor_keys()
    |> Enum.reduce_while({:ok, []}, fn ancestor_key, {:ok, acc} ->
      case project_first(ancestor_key, body, conn, own_name, params) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_all_rows(keys, body, conn, own_name, params) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      fetch_and_project_rows(key, body, conn, own_name, params, acc)
    end)
  end

  defp fetch_and_project_rows(key, body, conn, own_name, params, acc) do
    case Conn.query(conn, "FOR doc IN @@collection RETURN doc", %{
           "@collection" => doc_collection_name(key)
         }) do
      {:ok, docs} -> continue_with_projected(docs, key, body, conn, own_name, params, acc)
      {:error, :not_found} -> {:cont, {:ok, acc}}
      {:error, {:query_error, _}} = err -> {:halt, err}
    end
  end

  defp continue_with_projected(docs, key, body, conn, own_name, params, acc) do
    case project_rows(key, docs, body, conn, own_name, params) do
      {:ok, projected} -> {:cont, {:ok, acc ++ projected}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp project_rows(key, docs, body, conn, own_name, params) do
    docs
    |> Enum.map(fn doc ->
      project_body(key, decode_doc(doc), body, nil, conn, own_name, params)
    end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, r} -> r end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  defp project_first(key, body, conn, own_name, params) do
    case Conn.query(conn, "FOR doc IN @@collection LIMIT 1 RETURN doc", %{
           "@collection" => doc_collection_name(key)
         }) do
      {:ok, [doc | _rest]} ->
        project_body(key, decode_doc(doc), body, nil, conn, own_name, params)

      {:ok, []} ->
        {:ok, nil}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, {:query_error, _}} = err ->
        err
    end
  end

  defp parent_key([_single]), do: nil
  defp parent_key(key), do: Enum.drop(key, -1)

  defp ancestor_keys(key) when length(key) <= 1, do: []
  defp ancestor_keys(key), do: for(i <- (length(key) - 1)..1//-1, do: Enum.take(key, i))

  defp add_via_results(base, [], _key, _row, _conn, _own_name, _params), do: {:ok, base}

  defp add_via_results(base, [{edge, opts, inner}], key, row, conn, own_name, params) do
    with {:ok, results} <- resolve_via(key, row, edge, opts, inner, conn, own_name, params) do
      {:ok, Map.put(base, "via", results)}
    end
  end

  defp add_via_results(base, via_items, key, row, conn, own_name, params) do
    via_items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, base}, fn {{edge, opts, inner}, idx}, {:ok, acc} ->
      case resolve_via(key, row, edge, opts, inner, conn, own_name, params) do
        {:ok, results} -> {:cont, {:ok, Map.put(acc, "via_#{idx}", results)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_via(key, row, edge, opts, inner_body, conn, own_name, params) do
    with {:ok, id} <- fetch_id(row) do
      start_vertex = doc_collection_name(key) <> "/" <> id
      {min_hops, max_hops} = opts.hops || {1, 1}
      direction = if opts.backward, do: "INBOUND", else: "OUTBOUND"
      edge_collection = edge_collection_name(edge)

      aql = """
      FOR v, e, p IN #{min_hops}..#{max_hops} #{direction} @start @@edge_collection
        OPTIONS { uniqueVertices: "path" }
        RETURN {end_vertex: v, path_vertices: p.vertices}
      """

      bind_vars = %{"start" => start_vertex, "@edge_collection" => edge_collection}

      case Conn.query(conn, aql, bind_vars) do
        {:ok, rows} -> continue_via(rows, opts, inner_body, conn, own_name, params)
        {:error, :not_found} -> {:ok, []}
        {:error, {:query_error, _}} = err -> err
      end
    end
  end

  defp continue_via(rows, opts, inner_body, conn, own_name, params) do
    rows
    |> decode_candidates()
    |> maybe_keep_shortest(opts.shortest)
    |> project_and_finalize(opts, inner_body, conn, own_name, params)
  end

  # Each candidate keeps the end vertex's own document tree-key
  # alongside its decoded row -- needed the moment `inner_body` recurses
  # into `PARENT`/`SIBLINGS`/`ANCESTORS` (real, confirmed the hard way:
  # a `VIA` hop landing on a vertex and then asking for its own document
  # `PARENT` needs to know *which collection* that vertex came from, and
  # `decode_doc/1` already strips `_id` -- the one field that says --
  # before this point, so the key has to be captured from the raw
  # document first).
  defp decode_candidates(rows) do
    Enum.map(rows, fn %{"end_vertex" => end_doc, "path_vertices" => path_docs} ->
      {doc_key(end_doc), decode_doc(end_doc), Enum.map(path_docs, &decode_doc/1)}
    end)
  end

  defp doc_key(doc) do
    [collection, _key] = doc |> Map.fetch!("_id") |> String.split("/", parts: 2)
    String.split(collection, @doc_separator)
  end

  # A direct, line-for-line port of `scry_docgraph`'s own reference
  # `keep_shortest/1` -- groups by end-vertex `"id"`, keeps every path
  # tied for minimum length. This module's own moduledoc has the full
  # "why this gives exact tie-parity with the reference, unlike
  # `scry_engine_neo4j`'s own analogous `SHORTEST 1`" reasoning.
  defp maybe_keep_shortest(candidates, false), do: candidates

  defp maybe_keep_shortest(candidates, true) do
    candidates
    |> Enum.group_by(fn {_key, end_doc, _path} -> end_doc["id"] end)
    |> Enum.flat_map(fn {_end_id, group} ->
      min_len = group |> Enum.map(fn {_key, _end, path} -> length(path) end) |> Enum.min()
      Enum.filter(group, fn {_key, _end, path} -> length(path) == min_len end)
    end)
  end

  defp fetch_id(row) do
    case Map.fetch(row, "id") do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unsupported, :node_missing_id}}
    end
  end

  defp project_and_finalize(candidates, opts, inner_body, conn, own_name, params) do
    with {:ok, ordered_candidates} <- filter_and_order_candidates(candidates, opts, params) do
      ordered_candidates
      |> Enum.map(fn {key, end_doc, path_rows} ->
        project_body(key, end_doc, inner_body, path_rows, conn, own_name, params)
      end)
      |> finalize_via_rows(opts)
    end
  end

  defp finalize_via_rows(projected, opts) do
    case Enum.split_with(projected, &match?({:error, _}, &1)) do
      {[], oks} ->
        rows = Enum.map(oks, fn {:ok, r} -> r end)
        rows = if opts.distinct, do: Enum.uniq(rows), else: rows
        rows = rows |> maybe_drop(opts.offset) |> maybe_take(opts.limit)
        {:ok, rows}

      {[first_error | _], _rows} ->
        first_error
    end
  end

  # `WHERE`/`ORDER BY` only, generic via `run_flat/3` against each
  # candidate end vertex's own raw properties -- this module's own
  # moduledoc has the full "why not translated to AQL" reasoning.
  # `DISTINCT`/`LIMIT`/`OFFSET` deliberately apply afterward, to the
  # *final projected* rows -- mirrors the reference's own
  # `filter_and_order_paths/4`.
  defp filter_and_order_candidates(candidates, opts, params) do
    indexed = Enum.with_index(candidates)
    lookup = Map.new(indexed, fn {candidate, idx} -> {idx, candidate} end)

    tagged_rows =
      Enum.map(indexed, fn {{_key, end_doc, _path_rows}, idx} ->
        Map.put(end_doc, @path_marker_field, idx)
      end)

    query = %Query{
      wheres: if(opts.where, do: [opts.where], else: []),
      order_bys: opts.order_bys,
      select: [{:field, [@path_marker_field]}]
    }

    with {:ok, enumerable} <- QueryOps.run_flat(tagged_rows, query, params) do
      ordered =
        enumerable
        |> Enum.to_list()
        |> Enum.map(fn %{@path_marker_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp maybe_drop(rows, nil), do: rows
  defp maybe_drop(rows, n), do: Enum.drop(rows, n)

  defp maybe_take(rows, nil), do: rows
  defp maybe_take(rows, n), do: Enum.take(rows, n)

  @sample_size 100

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback --
  samples up to #{@sample_size} documents from `source`'s own real
  ArangoDB document collection and reports every field name observed
  (`"id"` -- the renamed `_key` -- included), with a best-effort scalar
  type inferred from the first sampled value seen for it. `nullable:
  true` for every field except `"id"` (always present, ArangoDB's own
  `_key` requirement) -- the identical schemaless-store reasoning
  `scry_engine_mongodb_driver`/`scry_engine_couchdb` each already give.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [Scry.Core.EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(%Conn{} = conn, source) do
    aql = "FOR doc IN @@collection LIMIT #{@sample_size} RETURN doc"

    case Conn.query(conn, aql, %{"@collection" => source}) do
      {:ok, []} -> {:error, :not_found}
      {:ok, docs} -> {:ok, fields_from_sample(Enum.map(docs, &decode_doc/1))}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:query_error, reason}} -> {:error, {:introspection_error, reason}}
    end
  end

  defp fields_from_sample(docs) do
    docs
    |> Enum.reduce(%{}, fn doc, acc ->
      Map.merge(acc, doc, fn _k, existing, _new -> existing end)
    end)
    |> Enum.map(fn {name, value} ->
      %{name: name, nullable: name != "id", scalar: infer_scalar(value)}
    end)
  end

  defp infer_scalar(value) when is_binary(value), do: :string
  defp infer_scalar(value) when is_integer(value), do: :integer
  defp infer_scalar(value) when is_float(value), do: :float
  defp infer_scalar(value) when is_boolean(value), do: :boolean
  defp infer_scalar(value) when is_map(value) or is_list(value), do: :json
  defp infer_scalar(_other), do: :unknown
end
