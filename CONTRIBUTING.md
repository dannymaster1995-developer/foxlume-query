# Contributing to Foxlume Query

Thanks for helping. Bug reports, fixes and new features are all welcome.

## Getting started

1. Build and test as described in the README: `scripts/fetch-duckdb.sh`, then `source scripts/env.sh`,
   `fqswift build` and `fqtest`.
2. Run the app from the debug build with your own data folder so you never touch real connections:
   `FOXLUME_DATA_DIR=/tmp/fq-dev .build/debug/FoxlumeQuery`.
3. Keep pull requests focused: one fix or feature per pull request, with tests.

## How the code is organized

- `FoxlumeQueryCore` has no UI code. Drivers, SQL helpers, completion engines and storage live there and are covered
  by `Tests/FoxlumeQueryCoreTests` (Swift Testing: `@Suite`, `@Test`, `#expect`).
- `FoxlumeQuery` is the AppKit app. `Tests/FoxlumeQueryAppTests` checks the editor, the filter bar and the workspace
  caches against the real AppKit classes; these tests open small windows for a moment.
- Each open connection has a `ConnectionWorkspace` that owns one `DatabaseSession`.
  A session runs every driver call on its own serial queue, so drivers may block and need no locking of their own.
- A driver implements the `DatabaseConnection` protocol (`Sources/FoxlumeQueryCore/Drivers/DatabaseConnection.swift`)
  and is created by `ConnectionFactory`. Engine-specific UI behavior is described by `EngineCapabilities` rather than by
  checks on the engine kind.

### Adding a database engine

1. Add a case to `DatabaseKind` and fill in its switches (default port, display name, file-based or not, schemas).
2. Write a `DatabaseConnection` in `Sources/FoxlumeQueryCore/Drivers/<Engine>/` and register it in `ConnectionFactory`.
3. Return the right `EngineCapabilities` (query language, nouns, what can be edited).
4. Add tests: unit tests for parsing and protocol code, and live tests that skip when the server's port is closed
   (see `MySQLTestServer` or `MongoTestServer` in the tests for the pattern).

## Tests

- Every change that can be tested has a test. When a test fails, fix the code, not the test.
- Tests must not write outside `TMPDIR` (use `Tests/FoxlumeQueryCoreTests/TestFiles.swift`), because
  `FileManager.temporaryDirectory` ignores `TMPDIR` on macOS.
- Live tests use local servers with test credentials only (`scripts/dbtest.sh` documents the ports and users;
  `scripts/dbtest-tls.sh` starts separate PostgreSQL and MySQL servers for the TLS certificate tests, with
  certificates from `scripts/tls-test-certs.sh`).
- UI changes can be checked with the scripted runner in `Sources/FoxlumeQuery/App/AutoTestRunner.swift` (debug builds
  only): set `FOXLUME_AUTOTEST_FILE` to a script of commands and `FOXLUME_DATA_DIR` to a scratch folder.

## Code style

- Match the surrounding code. Comments explain why, not what.
- Prefer early returns with `guard`, small functions and clear names. No force unwraps in new code.
- User-facing text is short and plain.

## License of contributions

By contributing you agree that your work is released under the project's license, the GNU AGPL v3.0 or later.
