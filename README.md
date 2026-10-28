# pg-client-embedded

PostgreSQL client tools (`pg_dump`, `pg_restore`) packaged as per-platform npm packages. They are the companion to [`@embedded-postgres/*`](https://github.com/leinelissen/embedded-postgres), which ships only `initdb`, `pg_ctl` and `postgres`.

The tools are built from the official PostgreSQL release tarball, **the same version as the embedded server**. Your dump/restore client then comes from one pinned Postgres release, and nothing is needed on the PATH.

## Packages

| Package | OS | CPU |
|---|---|---|
| `@equin/pg-client-darwin-arm64` | macOS 13+ | ARM64 (Apple Silicon) |
| `@equin/pg-client-darwin-x64` | macOS 13+ | x64 (Intel) |
| `@equin/pg-client-linux-arm64` | Linux (glibc 2.35+) | ARM64 |
| `@equin/pg-client-linux-x64` | Linux (glibc 2.35+) | x64 |

Add all four as `optionalDependencies`. bun/npm installs only the one matching the platform. The binaries are at:

```
node_modules/@equin/pg-client-<platform>/native/bin/{pg_dump,pg_restore}
```

The packages have no install scripts.

## Versions

The package version is the PostgreSQL version: `18.3.0` = PostgreSQL 18.3, which matches `@embedded-postgres/*@18.3.0-beta.*`.

## Build details

- **Linked in:** libpq, plus zlib on Linux. On macOS zlib is the system `libz`. The only other dependency is the C library.
- **Left out:** no OpenSSL, GSSAPI, LDAP, ICU or readline. These tools talk to a local cluster over a Unix socket or localhost.
- **zlib is included**, so compressed `-Fc` archives work both ways. lz4 and zstd are left out.
- **CI proves every build before publishing:** the linked-library check in `scripts/build.sh`, then `scripts/smoke-test.sh`. The smoke test runs a real dump → restore round trip against the matching `@embedded-postgres` server, and checks the client and server versions are equal.

## Publishing a new release

**Automatic, nothing to do.** The *Build and Publish* workflow runs daily. Its `resolve` job takes the newest `@embedded-postgres/linux-x64` release (by version, e.g. `18.4.0-beta.17`), derives the PostgreSQL release from it (`18.4`) and the package version (`18.4.0`). If `@equin/pg-client-*@18.4.0` is not on npm yet, it builds and smoke-tests all 4 platforms against that server, publishes them, and pushes the tag `v18.4.0`. If it is already published, the run stops after `resolve`. Nothing in the repo pins a version: `scripts/build.sh` takes `PG_VERSION` from the environment (required) and fetches the release's checksum beside the tarball.

**Manual:** run the workflow (Actions → Build and Publish → Run workflow) with a version, e.g. `18.4.1` for a rebuild of PostgreSQL 18.4 or `17.10.0` for an older major. The PostgreSQL release is its `major.minor`, the server is the newest `@embedded-postgres` release of it (the run fails if there is none). Pushing a tag `v<version>` does the same.

A version already on npm is never published again: the run (and each package within it) is a no-op, so a failed run can simply be re-run. Pushes to `main` and pull requests resolve the newest server and build + smoke-test, but never publish.

GitHub disables scheduled workflows on a repository with no activity for 60 days; re-enable it with `gh workflow enable "Build and Publish" -R equinai/pg-client-embedded`.

Publishing needs an `NPM_TOKEN` repo secret with publish access to the `@equin` npm scope.

To build locally: `PG_VERSION=18.4 bash scripts/build.sh`.
