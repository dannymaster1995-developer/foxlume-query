# Developing Foxlume Query

This guide covers building, testing and finding your way around the code. For how to propose changes, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Build

Requirements: macOS 13 or later on Apple silicon, and Swift 6 from Xcode or the Command Line Tools (`xcode-select --install`).

```bash
scripts/fetch-duckdb.sh     # downloads DuckDB's official library (about 55 MB) into Vendor/duckdb
source scripts/env.sh       # defines fqswift and fqtest
fqswift build               # debug build of the app, the core library and the fqprobe CLI
fqtest                      # the whole test suite
scripts/build-app.sh        # release app in build/Foxlume Query.app (ad-hoc signed)
```

`fqswift` and `fqtest` wrap `swift` and keep every compiler and SwiftPM cache inside the repository's `.build` folder. `fqtest --filter <regex>` runs a subset; the filter matches test type names.

## Tests

- `Tests/FoxlumeQueryCoreTests`: Swift Testing suites for the core library (drivers, SQL, completion, storage, import and export, Explain, diagrams, TLS).
- `Tests/FoxlumeQueryAppTests`: checks of the editor, filter bar, workspace caches, saved queries, Open Quickly and grid selection against the real AppKit classes. They open small windows for a moment.

### Live database tests

Live suites run when a server answers on its port on 127.0.0.1, and skip otherwise:

| Server | Port | Started by |
|---|---|---|
| PostgreSQL | 55432 | `scripts/dbtest.sh` |
| MySQL | 53306 | `scripts/dbtest.sh` |
| MongoDB | 57017 | `scripts/dbtest.sh` |
| Redis | 56379 | `scripts/dbtest.sh` |
| PostgreSQL with TLS | 55442 | `scripts/dbtest-tls.sh start` |
| MySQL with TLS | 53316 | `scripts/dbtest-tls.sh start` |

The credentials are local test values (see `scripts/dbtest.sh` and the `scripts/seed-*` files). Never point the tests at a real server. `scripts/dbtest.sh start` seeds a fresh data folder once from the `scripts/seed-*` files (`reset` deletes the data and starts again); on PostgreSQL and MySQL that includes `perf_big`, two million generated rows (`id`, `payload` = md5 of the id, `at`; no key or index) for the export paging, Explain and plan diagram tests, which adds about four seconds per server to a fresh start. `scripts/tls-test-certs.sh` creates the test CA, server and client certificates; they are never committed.

The Backup and Restore live suites also need the client tools. MySQL's `mysqldump` and `mysql` come with the test server in `../.dbtest/mysql-bin`. The PostgreSQL test server is server-only, so put PostgreSQL client tools of the same major version or newer (`pg_dump`, `pg_restore`, `psql` and the libraries they link) in `../.dbtest/pg-client/bin`: `scripts/env.sh` then exports `FQ_PG_CLIENT_BIN` and the suites use those copies. Without that folder the suites use the tools discovery finds on the Mac (PATH, Homebrew, Postgres.app) and skip when there are none.

`scripts/redis-extra.sh start` adds Redis Sentinel, Cluster and TLS servers for their suites. With every server running, use `fqtest --no-parallel`: in parallel, the live suites occupy all of Swift Testing's threads and the timing checks of the cancel and interrupt tests fail.

## Making a change

1. Pick or add a task in [ROADMAP.md](../ROADMAP.md) and mention its ID (`FQ-###`) in the commit or pull request.
2. Add tests for the new behaviour; run the related suites with `fqtest --filter <Suite>` while you work and the whole suite before you finish.
3. Add a line under `## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md), in the Added, Changed or Fixed group.
4. Update the README when users would notice the change (Features, shortcuts, Install or FAQ).

## Releases

`VERSION` holds the current version; `scripts/build-app.sh` reads it. To release:

```bash
scripts/release.sh 0.2.0 --dry-run   # checks main is clean and shows the VERSION, CHANGELOG and README changes
scripts/release.sh 0.2.0             # commits "Release 0.2.0" and tags v0.2.0 (no push)
git push origin main && git push origin v0.2.0
```

The tag starts `.github/workflows/release.yml`: it runs the tests, builds the app, zips it with a SHA-256 checksum and publishes a GitHub release whose notes come from `scripts/release-notes.sh 0.2.0`. Versions follow [Semantic Versioning](https://semver.org); while the version starts with 0, new features raise the minor number and fixes the patch number.

## Command-line probe

`fqprobe` exercises a driver without the app:

```bash
.build/debug/fqprobe --kind postgresql --port 55432 --user postgres --password postgres --db foxlume query "SELECT now()"
.build/debug/fqprobe --kind mysql --port 53306 --user root --password root --db foxlume meta orders
```

Run it without arguments for every option, including SSH and TLS settings.

## Where the app keeps data

| Data | Location |
|---|---|
| Connections, settings, history, saved queries, filter presets, ER diagram layouts, grid column layouts, sidebar favourites and recents, open tabs, imported themes, SSH known hosts | `~/Library/Application Support/Foxlume Query/` |
| Database and SSH passwords, TLS key passphrases | macOS Keychain, service `com.foxlume.query.connection` |
| AI provider API keys | macOS Keychain, service `com.foxlume.query.ai` |

Portable mode: set `FOXLUME_DATA_DIR=/some/folder` and everything, passwords included, is kept in that folder (passwords in a file readable only by you). `scripts/run-portable.sh` starts the app this way.

## Project layout

```
Sources/
  CDuckDB/              DuckDB C API module (library in Vendor/duckdb)
  FoxlumeQueryCore/     UI-independent library
    Models/             connection settings, results, schema types
    Drivers/            DatabaseConnection protocol, DatabaseSession (serial queue, ping, reconnect, query timeout),
                        SessionSetup (startup commands and server timeout applied on every connect)
      Transport/        TCP sockets with in-place TLS upgrade, SSH tunnel, connect deadlines
      TLS/              Network.framework TLS stream, PEM and key decoding, client identities, certificate checks
      Postgres/ MySQL/ SQLite/ DuckDB/ MongoDB/ Redis/
    SQL/                dialects, statement splitting, table queries, change generation, formatter, maintenance commands,
                        server activity (session list, cancel and terminate, slow query statistics)
    Completion/         query editor completion engines
    Storage/            connections, Keychain, history, saved queries, filter presets, diagram and column layouts, settings
    Grid/               sorting, paste parsing, selection figures, cell filters, column name matching, cell editor types,
                        value viewer helpers (view modes, JSON tree and paths, image signatures, hex dump lines)
    Search/             Open Quickly matching and ranking
    Tabs/               tab strip layout: how many tabs fit and which stay in view
    Explain/            query plan model, parsers per engine, analysis, plan diagram layout
    Diagram/            ER diagram graph and layout
    Theme/              built-in themes, VS Code theme import, environment tint colors for windows
    Export/ Import/     result and table export (CSV, JSON, NDJSON, SQL, XLSX), CSV / JSON / XLSX import, SQL file runner,
                        ZIP reader and writer (stored, deflated, ZIP64) for XLSX
    AI/                 inline AI suggestions: Settings › AI and the per-connection policy, the prompt (text around the caret,
                        dialect, schema context), request building and response parsing for OpenAI-compatible and Anthropic
                        APIs, the URLSession client and error mapping, answer clean-up, and the InlineSuggestionSource protocol
                        with its chat API implementation (tests stub the network with a URLProtocol; no real provider is called)
    Backup/             Backup and Restore with the user's pg_dump, pg_restore, psql, mysqldump and mysql: tool discovery and
                        versions, command lines (TLS, SSH tunnel), private password and client key files, backup file
                        detection, process-group runner
  FoxlumeQuery/         the AppKit app
    Editor/             SQL editor, completion list, inline suggestion manager (debounce, cancellation, accept), grey text
                        and the Ask prompt of the per-connection AI policy
  fqprobe/              driver probe CLI
Tests/                  FoxlumeQueryCoreTests and FoxlumeQueryAppTests
scripts/                build, environment, test servers, test certificates, sample data
docs/                   this guide and the README images
```
