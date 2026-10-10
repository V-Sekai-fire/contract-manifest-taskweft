# contract-manifest-taskweft

The workspace's goal manifest: `default.xml` places every project on a side of the hexagon.

## What it is for

A workspace checkout is a `repo` client of this manifest. Gate scripts beside it check the manifest on every pull request, and `sync.exs` preflights every checkout, runs `repo sync` and verifies the result. RFD 2294 in `manuals-weftspun` says how to start out in the workspace.

## Build and run

From a workspace root:

```sh
elixir .repo/manifests/sync.exs .
```

## Licence

MIT. See [LICENSE](LICENSE).
