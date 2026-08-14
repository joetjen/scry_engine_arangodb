defmodule Scry.Engine.ArangoDB.Conn do
  @moduledoc """
  Wraps an `arangox` connection pid -- opened once via `open/1` and
  meant to be reused across many `Scry.Engine.ArangoDB.execute/3`
  calls, matching the connection/config struct every real adapter
  exposes (impl_spec.md §2). `arangox` is `DBConnection`-based, the
  same supervised-reconnecting-process shape `postgrex`/`myxql`/`ch`/
  `mongodb_driver`/`boltx` already have in this family.

  ## A real, confirmed client-selection finding

  `arangox`'s own *default* client (`Arangox.VelocyClient`, ArangoDB's
  native VelocyStream binary protocol) needs `:velocy` as a peer
  dependency neither `arangox` nor this package requires automatically
  -- confirmed directly: starting a connection with no `:client`
  override crashes with `UndefinedFunctionError` inside `Arangox.
  VelocyClient.connect/2`. `open/1` always passes `client: Arangox.
  MintClient` (plain HTTP via `:mint`, the same client `req` itself
  uses underneath, and already trusted elsewhere in this family) --
  arangox's own supported, documented alternative.

  ## A real, confirmed error-surfacing finding

  Unlike every HTTP-based adapter in this family so far, a query-level
  failure here doesn't come back as an ordinary `{:error, _}` return
  value at all -- confirmed directly: `Arangox.cursor/4` streams
  results lazily via `DBConnection.stream/4`, and a failure encountered
  *during* that stream's own enumeration (a real one found: querying a
  collection that doesn't exist, AQL error `1203`) *raises* an
  `Arangox.Error`, propagating straight out of `Arangox.transaction/2`
  rather than being returned. `query/3` always wraps the whole
  transaction in `rescue`, normalizing both that raised form and an
  ordinary `{:error, %Arangox.Error{}}` transaction-level return into
  this package's own two shapes: `{:error, :not_found}` specifically
  for AQL error `1203` (collection or view not found -- the one case
  `Scry.Engine.ArangoDB` itself needs to tell apart from every other
  failure), `{:error, {:query_error, reason}}` for anything else.
  """

  @type t :: %__MODULE__{pid: pid()}

  defstruct pid: nil

  @not_found_error_num 1203
  @default_opts [endpoints: "http://localhost:8529", client: Arangox.MintClient]

  @doc """
  Starts an `arangox` connection against `opts` (`Arangox.start_link/1`'s
  own options), merged over this module's own explicit local-Docker
  defaults (`endpoints: "http://localhost:8529"`) and always forcing
  `client: Arangox.MintClient` (this module's own moduledoc has the
  full "why the driver's own default client can't be used as-is"
  reasoning) unless the caller explicitly overrides it.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, pid} <- Arangox.start_link(Keyword.merge(@default_opts, opts)) do
      {:ok, %__MODULE__{pid: pid}}
    end
  end

  @doc "Stops the wrapped connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}), do: GenServer.stop(pid)

  @doc """
  Runs `aql` with `bind_vars` against `conn`, draining every batch of
  the resulting cursor into one plain list of result documents/values
  -- `Scry.Engine.ArangoDB.execute/3`'s own queries are always small
  enough (a single collection's own documents, or one `VIA` hop's own
  candidate paths) that eager draining, not a genuinely lazy `Stream`,
  is the right tradeoff, the same choice `scry_engine_ch` already
  states for its own eager-only query function.
  """
  @spec query(t(), String.t(), map()) ::
          {:ok, [term()]} | {:error, :not_found} | {:error, {:query_error, term()}}
  def query(%__MODULE__{pid: pid}, aql, bind_vars \\ %{}) do
    pid
    |> Arangox.transaction(fn c ->
      c
      |> Arangox.cursor(aql, bind_vars)
      |> Enum.reduce([], fn resp, acc -> acc ++ resp.body["result"] end)
    end)
    |> normalize()
  rescue
    e in Arangox.Error -> normalize({:error, e})
  end

  defp normalize({:ok, rows}), do: {:ok, rows}

  defp normalize({:error, %Arangox.Error{error_num: @not_found_error_num}}),
    do: {:error, :not_found}

  defp normalize({:error, reason}), do: {:error, {:query_error, reason}}

  @doc "Creates collection `name` (`:document` or `:edge`) if it doesn't already exist -- idempotent, since a `409` (already exists) is treated the same as a fresh `200`. Test/fixture use only, never called from `execute/3` itself."
  @spec create_collection(t(), String.t(), :document | :edge) ::
          :ok | {:error, {:query_error, term()}}
  def create_collection(%__MODULE__{pid: pid}, name, kind \\ :document) do
    type = if kind == :edge, do: 3, else: 2

    case Arangox.post(pid, "/_api/collection", %{name: name, type: type}) do
      {:ok, %Arangox.Response{}} -> :ok
      {:error, %Arangox.Error{status: 409}} -> :ok
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  @doc "Inserts `doc` (a plain map, `_key` included if the caller wants an explicit one) into `collection`. Test/fixture use only."
  @spec insert_document(t(), String.t(), map()) :: :ok | {:error, {:query_error, term()}}
  def insert_document(%__MODULE__{pid: pid}, collection, doc) do
    case Arangox.post(pid, "/_api/document/#{collection}", doc) do
      {:ok, %Arangox.Response{}} -> :ok
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  @doc "Every real collection name in the connected database (`/_api/collection`), ArangoDB's own system collections excluded, filtered to document (`:document`) or edge (`:edge`) collections only."
  @spec collection_names(t(), :document | :edge) ::
          {:ok, [String.t()]} | {:error, {:query_error, term()}}
  def collection_names(%__MODULE__{pid: pid}, kind) do
    type = if kind == :edge, do: 3, else: 2

    case Arangox.get(pid, "/_api/collection") do
      {:ok, %Arangox.Response{body: %{"result" => collections}}} ->
        names =
          collections
          |> Enum.filter(&(&1["isSystem"] == false and &1["type"] == type))
          |> Enum.map(& &1["name"])

        {:ok, names}

      {:error, reason} ->
        {:error, {:query_error, reason}}
    end
  end
end
