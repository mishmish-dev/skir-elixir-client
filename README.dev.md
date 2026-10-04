# Developing skir-elixir-client

This repository owns the native Elixir runtime and its Hex publication.
The Mix application is `:skir_elixir_client`; the Hex package is `skir_elixir_client`.
The companion `skir-elixir-gen` repository owns code generation and npm
publication. Generator and runtime versions are independent.

## Local checks

```sh
mix local.hex --force
mix local.rebar --force
mix deps.get --check-locked
npm ci --ignore-scripts
npm run test:all
mix docs --warnings-as-errors
```

Open `doc/index.html` for a local documentation preview. ExDoc is a development
dependency only and is not required by applications using the runtime.
Building documentation requires Elixir 1.15+; CI uses Elixir 1.20.4 with OTP
27, 28, and 29. CI builds the documentation and uploads it as a preview artifact.

The 44 ExUnit tests cover codecs, validation, RPC services and clients,
reflection, Studio, and Plug. The raw TypeScript RPC oracle checks 16 server
cases and GET/POST client wire behavior. CI builds a Hex archive and tests it
in a fresh Mix consumer. Node dependencies are development-only tools and are
not required by the runtime or included in Hex.

Generated-code tests, all 101 upstream goldens, serialization interoperability,
and live generated-client HTTP integration tests belong to `skir-elixir-gen`.
No generator checkout is needed to run this repository's tests. There is no
coverage gate for the standalone runtime suite.

## Documentation

The README and [RPC guide](docs/SKIRRPC.md) are included in HexDocs alongside
public module/function documentation. Internal codec modules have
`@moduledoc false`. Keep API examples aligned with the companion generator.

For a local consumer, use `{:skir_elixir_client, path: "../skir-elixir-client"}` instead of
the Hex dependency. This is useful when testing runtime changes with the generator.

See [release instructions](docs/RELEASING.md) for package and documentation
publishing, and [the RPC parity audit](docs/SKIRRPC_PARITY.md) for compatibility
scope and verification details.
