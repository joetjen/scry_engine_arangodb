defmodule Scry.Engine.ArangoDB.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_engine_arangodb,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Engine.ArangoDB",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet -- this package implements
      # `Scry.Core.EngineBehaviour` and returns `Scry.Core.Query.t()`-
      # shaped data, so it's the real dependency, not test-only. Switch
      # to a `~> x.y` Hex requirement once scry_core is actually
      # published (impl_spec.md's own dependency-versions convention).
      {:scry_core, path: "../scry_core"},

      # === PARITY TESTING ===
      # `scry_docgraph`'s own reference `Scry.DocGraph.Executor` --
      # test-only, since AGENTS.md's "Parity between multiple
      # implementations" rule applies directly here: the reference
      # executor and this real adapter are two implementations of the
      # identical fused DEEP/PARENT/SIBLINGS/ANCESTORS + VIA/PATH
      # semantics, the same posture already established for `scry_graph`/
      # `scry_engine_neo4j` and `scry_document`/`scry_engine_mongodb_
      # driver`/`scry_engine_couchdb`.
      {:scry_docgraph, path: "../scry_docgraph", only: :test},

      # === ARANGODB DRIVER ===
      # `arangox` -- confirmed the community-preferred, most-downloaded
      # ArangoDB client, `DBConnection`-based (the same pooling library
      # behind `postgrex`/`myxql`/`ch`/`mongodb_driver`/`boltx`), not a
      # compile-time macro-based connection module the way `instream`/
      # `snap` were (the specific shape that already disqualified those
      # two elsewhere in this family). ~17 months since its last release
      # as of this landing -- real, but nowhere near the multi-year
      # abandonment already confirmed for `bolt_sips`/`couchdb_connector`/
      # `instream` -- a genuine, deliberate choice, not a fallback.
      {:arangox, "~> 0.7"},

      # `arangox`'s own *default* client (`Arangox.VelocyClient`, the
      # native VelocyStream binary protocol) needs `:velocy` as a peer
      # dependency neither this package nor `arangox` itself requires
      # automatically -- confirmed directly, starting a connection with
      # no client override crashes with `UndefinedFunctionError` inside
      # `Arangox.VelocyClient.connect/2`. `Arangox.MintClient` (plain
      # HTTP via `:mint`, the same client `req` itself uses underneath)
      # is arangox's own supported alternative -- `Scry.Engine.ArangoDB.
      # Conn`'s own moduledoc has the full finding.
      {:mint, "~> 1.5"},
      {:jason, "~> 1.4"},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "A real Scry.Core.EngineBehaviour implementation over ArangoDB, replacing scry_docgraph's " <>
      "own in-memory reference Executor with genuine collection-and-AQL-traversal-backed " <>
      "DEEP/PARENT/SIBLINGS/ANCESTORS + VIA/PATH execution -- the document+graph composite " <>
      "kind's first real adapter."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_engine_arangodb"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_engine_arangodb",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
