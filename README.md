[![Hex](https://img.shields.io/hexpm/v/skir_elixir_client)](https://hex.pm/packages/skir_elixir_client)
[![HexDocs](https://img.shields.io/badge/docs-HexDocs-blue)](https://hexdocs.pm/skir_elixir_client)
[![build](https://github.com/mishmish-dev/skir-elixir-client/actions/workflows/ci.yml/badge.svg)](https://github.com/mishmish-dev/skir-elixir-client/actions/workflows/ci.yml)

# skir_elixir_client

Native Elixir runtime for [skir-elixir-gen](https://www.npmjs.com/package/skir-elixir-gen).
Supports JSON and binary serialization, SkirRPC, and an optional Phoenix/Plug adapter.

## Installation

Requires Elixir 1.18+ and Erlang/OTP 27+.

Add to your application's `mix.exs`, then run `mix deps.get`:

```elixir
{:skir_elixir_client, "~> 0.2"}
```

## Quick example

Using the `User` module generated in the [generator guide](https://github.com/mishmish-dev/skir-elixir-gen#readme):

```elixir
alias Example.Protocol.UserSkir.User

user = User.new(id: 42, name: "Alice")
{:ok, json} = User.encode_json(user)
{:ok, ^user} = User.decode_json(json)
```

## Documentation

- [Runtime API reference](https://hexdocs.pm/skir_elixir_client)
- [Generator setup and generated-code guide](https://github.com/mishmish-dev/skir-elixir-gen#readme)
- [Codecs and schema evolution](docs/CODECS.md)
- [RPC guide](docs/SKIRRPC.md)
- [Development](README.dev.md)
