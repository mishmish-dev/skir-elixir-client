# Client releases

This repository publishes the `skir_elixir_client` package to Hex (Mix application `:skir_elixir_client`). Its version
is independent of the generator's npm version.

Set the repository Actions secret `HEX_API_KEY` to a Hex API key authorized to
publish `skir_elixir_client`. The generator deploy key is read-only and cannot publish here.

1. Set the version in `mix.exs` and run `npm run test:all` and
   `mix docs --warnings-as-errors`. Source links use the matching `vX.Y.Z` tag.
2. Optionally dispatch Release: it runs CI on OTP 27/28/29 without publishing.
3. Publish a stable GitHub release tagged `vX.Y.Z`, matching `mix.exs`.

The release reruns standalone CI, compiles the tagged production runtime with
locked dependencies, verifies the documentation, then runs a Hex package dry-run,
publishes the package, and uploads the ExDoc documentation to
[HexDocs](https://hexdocs.pm/skir_elixir_client). ExDoc runs in the development
environment; the runtime archive is built in the production environment.
Ordinary CI uses `hex.build` and a fresh consumer install without credentials.
Drafts and prereleases do not publish. The package archive is public even while
this source repository is private. Never republish an existing version.

## Documentation for an existing release

To add or update documentation without republishing the package, check out the
released tag, fetch dependencies, and upload docs with the same Hex credential:

```sh
mix deps.get --check-locked
mix docs --warnings-as-errors
mix hex.publish docs --yes
```

The version in `mix.exs` selects the documentation version. Package and docs
publishing are separate steps, so a failed docs upload can be retried with this
command without attempting to publish the package again. The same `HEX_API_KEY`
secret is used by both release steps. Manual workflow dispatch runs checks only.
