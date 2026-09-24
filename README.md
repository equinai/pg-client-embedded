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

1. Bump `PG_VERSION` and `PG_SHA256` in `scripts/build.sh` (checksum from `https://ftp.postgresql.org/pub/source/v<ver>/postgresql-<ver>.tar.bz2.sha256`).
2. Bump `EMBEDDED_POSTGRES_VERSION` in the workflow to the server release with the same Postgres version.
3. Commit and push. CI builds and smoke-tests without publishing.
4. Tag and push: `git tag v<ver>.0 && git push origin v<ver>.0`. CI publishes all 4 packages.

Publishing needs an `NPM_TOKEN` repo secret with publish access to the `@equin` npm scope.
