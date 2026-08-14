# scry_engine_arangodb

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [ArangoDB](https://arangodb.com/), via
[`arangox`](https://hex.pm/packages/arangox). Replaces `scry_docgraph`'s
own reference implementation (`Scry.DocGraph.Executor` -- one in-memory
`%{path => rows}` space serving both document-tree and graph-node roles
at once, plus a separate in-memory adjacency map) with genuine
collection-and-AQL-traversal-backed `DEEP`/`PARENT`/`SIBLINGS`/
`ANCESTORS` *and* `VIA`/`PATH` execution, each independently nestable
inside the other -- the document+graph composite kind's first real
adapter, closing the one remaining kind package with a real fused
executor and zero real-backend validation (`scry_docgraph`'s own
moduledoc names ArangoDB directly as the deferred candidate).

ArangoDB is a genuinely natural fit, not an arbitrary pick: a real
multi-model database with native document collections *and* native
graph traversal (edge collections, AQL's own `FOR v, e, p IN min..max
OUTBOUND/INBOUND ...` syntax) in one query language.

Source: <https://github.com/joetjen/scry_engine_arangodb>. Specs live
in the separate [`scry`](https://github.com/joetjen/scry) repository;
the behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.ArangoDB.Conn.open(database: "mydb")

{:ok, query} = Scry.Core.parse(~s(SELECT company.people { name, PARENT { name }, VIA knows { name } }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.ArangoDB, conn)
rows = Scry.Core.Cursor.to_list(cursor)
```

Creating databases/collections/documents/edges is entirely the
caller's own job -- this package is schema-agnostic and issues nothing
but AQL reads plus `GET /_api/collection` introspection.

### Local development / running the test suite

```sh
docker run -d --name scry-arangodb -p 8529:8529 -e ARANGO_NO_AUTH=1 arangodb:3.11
```

## Driver: `arangox`, not disqualified the way other roadmap drivers were

`arangox` is the community-preferred, most-downloaded ArangoDB client,
`DBConnection`-based (the same pooling library behind `postgrex`/
`myxql`/`ch`/`mongodb_driver`/`boltx`), not a compile-time macro-based
connection module the way `instream`/`snap` were (the specific shape
that already disqualified those two elsewhere in this family). ~17
months since its last release as of this landing -- real, but nowhere
near the multi-year abandonment already confirmed for `bolt_sips`/
`couchdb_connector`/`instream` -- a genuine, deliberate choice, not a
fallback. There's no roadmap-named package for this adapter at all
(`scry_docgraph`'s own docs explicitly deferred it), so this is a
fresh design, not a correction.

## Two real, confirmed driver findings

- **`arangox`'s own default client needs a dependency neither it nor
  this package requires automatically.** `Arangox.VelocyClient`
  (ArangoDB's native VelocyStream binary protocol) needs `:velocy` as
  a peer dependency -- confirmed directly, starting a connection with
  no `:client` override crashes with `UndefinedFunctionError`.
  `Conn.open/1` always passes `client: Arangox.MintClient` (plain HTTP
  via `:mint`, the same client `req` itself uses underneath).
- **A query-level failure doesn't come back as `{:error, _}` at all.**
  `Arangox.cursor/4` streams results lazily via `DBConnection.stream/4`,
  and a failure encountered *during* enumeration (a real one found:
  querying a collection that doesn't exist, AQL error `1203`) *raises*
  an `Arangox.Error`, propagating straight out of `Arangox.
  transaction/2`. `Conn.query/3` always wraps the whole transaction in
  `rescue`, normalizing both the raised and returned forms into this
  package's own two shapes.

## Document collection-per-tree-key, joined with `__`

The identical convention `scry_engine_mongodb_driver`/`scry_engine_
couchdb` already established for the pure `document` kind: one real
ArangoDB *document* collection per tree-position key, segments joined
with `__` -- ArangoDB disallows a literal `.` in collection names
(confirmed directly, the identical restriction `scry_engine_couchdb`
already found for CouchDB). `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` all
resolve via `GET /_api/collection` (ArangoDB's own `isSystem`/`type`
flags cleanly separate real document collections from both system
collections and this package's own edge collections -- no name-prefix
filtering needed) plus client-side filtering.

## Edge collections, one per `VIA` edge name, and `_key` doubles as the reference's own required `"id"`

One real ArangoDB *edge* collection per distinct `VIA` edge name,
prefixed `edge__` to keep its own name out of the document-tree
namespace. Unlike `scry_engine_mongodb_driver`/`scry_engine_couchdb`
(where the driver's own document-identity field is pure internal
noise, stripped), `scry_docgraph`'s own reference `Conn` explicitly
requires a graph-participating row to carry a real, user-visible
`"id"` field -- so this package renames ArangoDB's own `_key` to
`"id"` rather than stripping it, since they're the same real thing
here, confirmed by the reference's own contract.

## `VIA`'s own traversal: one AQL query per hop, `uniqueVertices: "path"`, and client-side `SHORTEST`

AQL's own variable-length traversal does not enforce simple-path
semantics by default either (the identical divergence
`scry_engine_neo4j` already found for Cypher) -- but ArangoDB has a
**native, plugin-free fix**: `OPTIONS { uniqueVertices: "path" }`,
confirmed directly against a real cyclic graph, no manual `WHERE
ALL(...)` filter construction needed. `opts.shortest` is *not*
translated into `SHORTEST_PATH`/`K_SHORTEST_PATHS` (both name a single
target, not "shortest to every reachable node") -- instead every
simple path is fetched and `keep_shortest/1`, a direct port of
`scry_docgraph`'s own reference function, groups by end-vertex `"id"`
and keeps every tied path client-side. **This gives exact tie-parity
with the reference**, unlike `scry_engine_neo4j`'s own `SHORTEST 1`
(which keeps only one path per end node, a real, stated divergence
documented there).

Every other `VIA` modifier -- `WHERE`/`ORDER BY`/`DISTINCT`/`LIMIT`/
`OFFSET` -- applies generically via `Scry.Core.QueryOps.run_flat/3`,
never translated into AQL.

## A missing document collection is an error; a missing edge collection is empty

A tree-key-derived document collection that doesn't exist is a clear
error (`{:query_error, {:no_such_source, source}}`), matching the
reference's own strict behavior -- confirmed directly, `FOR doc IN
<collection>` against a nonexistent collection is a real error, the
identical divergence-from-Neo4j/MongoDB `scry_engine_couchdb` already
documents. A `VIA` edge collection that was never created is
different, deliberately: it means no edge of that name exists
anywhere, matching the reference's own graceful empty adjacency.

## Parity testing against the reference

AGENTS.md's "Parity between multiple implementations" rule applies
directly: `test/scry/engine/arango_db/parity_test.exs` reuses
`scry_docgraph`'s own `Scry.DocGraphTest` fixture verbatim, parses
each query text once (`Scry.DocGraph.parse/1`), and runs it against
both a real ArangoDB container and the reference's own in-memory
`Conn`, asserting the results agree.

## Installation

```elixir
def deps do
  [
    {:scry_engine_arangodb, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_arangodb>.
