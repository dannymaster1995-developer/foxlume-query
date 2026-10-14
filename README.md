# Foxlume Query

A native macOS database client written in Swift with AppKit and SwiftUI. No Electron, no JVM, no drivers to install:
every wire protocol is implemented in Swift inside the app.

> **Status: early alpha (0.1.0).** Foxlume Query is usable day to day, but it has not seen wide use yet. There are
> no prebuilt downloads; build it from source as described below. Bug reports are very welcome.

## Databases

PostgreSQL and MySQL are the focus of the first releases. The other engines work but are labelled **Beta** in the app:
they have had less testing and some features are missing.

| Engine | Status | Tested with | How it connects |
|---|---|---|---|
| PostgreSQL | Supported | 18 | Protocol v3 in Swift: SCRAM-SHA-256, MD5, TLS |
| MySQL | Supported | 8.4 | MySQL protocol in Swift: caching_sha2_password (fast path, RSA, TLS), mysql_native_password |
| MariaDB | Beta | not yet tested | Same driver as MySQL |
| SQLite | Beta | 3.51 (macOS) | The system `libsqlite3` |
| DuckDB | Beta | 1.5.6 | DuckDB's C library; opens `.duckdb` files and Parquet, CSV, TSV and JSON files directly |
| MongoDB | Beta | 8.2 | Wire protocol in Swift: SCRAM-SHA-1/256, TLS, `mongodb://` and `mongodb+srv://`; a JavaScriptCore shell runs MQL |
| Redis | Beta | 8.x | RESP2/RESP3 in Swift: ACL, TLS, Sentinel and Cluster; keys shown as a tree |

## Features

**Connections**
- Saved connections with groups, colors and environment labels (Local, Development, Staging, Production).
- Safe Mode per connection: Silent, Alert (confirm writes), Alert (Full) (confirm everything), Safe Mode and Safe Mode (Full) (confirm, then Touch ID or your password), or Read-Only.
- TLS modes Disabled, Preferred, Required and Verify Full. SSH tunnels through the system `ssh` (agent, key file or password).
- Open a connection from a URL (`postgres://`, `mysql://`, `mongodb://`, `redis://` …).
- Passwords are kept in the macOS Keychain.
- A periodic health check reconnects dropped connections in the background, and running something on a lost connection reconnects first.

**Browsing and editing**
- Sidebar of tables, views, collections or Redis keys, with a filter and a schema picker. Engine-internal databases are hidden by default.
- Paged grids (5 to 1,000 rows per page, all rows, or a custom size) with server-side sorting and filters by column and operator or by raw WHERE / MongoDB filter / Redis pattern.
- Multi-column sort: click a header to sort ascending, again for descending, a third time for no sort; Shift-click adds the column as the next key (numbered in the header). Table tabs sort on the server with one ORDER BY (a sort document on MongoDB); query results sort in memory. The header menu has Sort Ascending / Descending, Don't Sort, Select Column, Copy Column Name, Fill Column… and Filter with Column.
- Filters with =, ≠, >, ≥, <, ≤, contains, starts / ends with, matches regex, between, not between, in / not in list, is empty / not empty and is (not) NULL. Text operators ignore case unless Match Case (Aa) is on; rules combine with Match All or Match Any. Save the filters of a table as a named preset and apply or delete it later. A cell's context menu offers Filter conditions built from its value.
- Cell selection: click a cell, drag or Shift-click for a range, ⌘-click to add or remove cells, ⌘-click a header (or Select Column) for a whole column, Shift-arrows to extend. ⌘C copies the range as TSV (⌥⌘C with headers). ⌘V pastes TSV or CSV from the selected cell as staged edits (one undo step); a block as wide as the table is added as new rows. Fill Column… and Fill Selected Cells… set one value. The status bar shows count, sum, average, minimum and maximum of the selected cells.
- In-place editing with undo and redo, including Set NULL, DEFAULT and Current Timestamp. Save runs every change in one transaction, checks that each change touched exactly one row, and rolls back otherwise. Preview SQL (⇧⌘P) shows exactly what Save will run.
- Foreign key cells link to the referenced row; the Row Inspector (⌥⌘I) shows the selected row column by column with types.
- Find in results (⌘F) highlights matches in the loaded rows; Search All Rows searches the whole table on the server.
- MongoDB edits keep BSON types (Int64, Decimal128, ObjectId, dates), including nested values; fields can be removed.
- Rename tables and views right away; Truncate and Drop are staged until Save, with "Ignore foreign key checks" and "Cascade" options.
- Create and drop databases (PostgreSQL, MySQL) and schemas (PostgreSQL) from the Database menu.
- Structure view with columns, indexes, foreign keys and DDL. On PostgreSQL and MySQL it is an editor: add, change and drop columns (type, nullable, default, primary key, auto increment, comment), indexes, foreign keys and the table comment, preview the ALTER statements and save them. New Table builds a CREATE TABLE with a live SQL preview.
- Copy rows as TSV, CSV, JSON, INSERT statements or Markdown, or export a result to a file.

**Import and export** (SQL engines)
- Export Tables (⌥⇧⌘E): one or more tables and views to CSV, JSON, NDJSON or a SQL dump (structure, data or both, optionally gzipped), with a filter and row limit per table. Rows are streamed from a consistent snapshot on a separate connection.
- Import CSV into Table (⇧⌘I): encoding and delimiter detection, a preview, column mapping and NULL handling; on error, roll back, keep the rows so far, or skip bad rows and list them.
- Run SQL File: `.sql` and `.sql.gz` files of any size, statement by statement, with the same error choices.

**Query editor**
- Highlighting for SQL, MongoDB shell commands and Redis commands.
- Context-aware completion: the SQL analyzer knows the clause, the tables and aliases in scope, CTEs and subqueries, and offers tables, columns (with type and key details), functions with signatures, keywords and operators for the connection's dialect, quoting names where needed. Keyword case follows a setting. MongoDB completion knows collections, methods, operators and sampled document fields; Redis completion knows commands, options and key names. The filter bar's raw SQL box completes too.
- Run the statement under the caret (⌘↩), everything (⇧⌘↩) or without the row limit (⌥⌘↩); cancel with ⌘.; format SQL with ⇧⌘L. The row limit is applied by the server on PostgreSQL and MySQL, so large results never cross the network in full.
- Explain (⌥⌘E) and Explain Analyze (⌃⌘E) for the statement under the caret or the selection: the plan as a tree with
  each step's object, share of the work, cost, estimated and actual rows, time and loops, expensive steps marked,
  warnings (row estimates far off, large filtered scans, sorts and hashes spilled to disk), every property of the
  selected step, and the server's raw output. PostgreSQL and MySQL; SQLite, DuckDB, MariaDB and MongoDB in beta.
  Explain Analyze really runs the statement: on PostgreSQL inside a transaction that is rolled back, elsewhere only
  for statements that read data, and never for writes on read-only connections.
- Confirmation before UPDATE or DELETE without WHERE, and before writes on Production connections (both can be turned off in Settings).
- Open and save `.sql` files.
- Saved queries (⌘D, or the star in a query tab): a "Saved Queries" side of the sidebar with nested folders, kept for one connection or shared with all of them. Each can have a keyword: typing it in the editor offers the query, and `;;` in its SQL marks where the cursor lands. Saved queries never run on their own; Run goes through the normal run path, Safe Mode included.

**Everything else**
- System, Light or Dark appearance; 13 built-in editor themes (Dracula, One Dark, Nord, Solarized, Catppuccin …) and import of VS Code themes (`.json` or `.vsix`).
- Searchable query history (SQLite full-text search); any entry can be kept as a saved query.
- Open Quickly (⇧⌘O): one fuzzy search over tables and views (all schemas), databases, schemas, saved queries and recent history, with the tables, saved queries and history of the other open connections. Results rank by match and by how often and recently you opened them.
- Open tabs come back when you reopen a connection; ⇧⌘T reopens a closed tab.

**Not there yet:** SQL Server and many other engines, a graphical plan diagram, ER diagrams, JSON and XLSX import. TLS connections are limited to TLS 1.2 for now.

## Building from source

Requirements: macOS 13 or later on Apple silicon, and Swift 6 from either Xcode or the Command Line Tools
(`xcode-select --install`).

```bash
git clone https://github.com/dannymaster1995-developer/foxlume-query.git
cd foxlume-query
scripts/fetch-duckdb.sh            # downloads DuckDB's official library (about 55 MB) into Vendor/duckdb
scripts/build-app.sh               # builds "build/Foxlume Query.app" (release, ad-hoc signed)
open "build/Foxlume Query.app"
```

`scripts/env.sh` defines `fqswift` and `fqtest`, wrappers around `swift` that keep every compiler and SwiftPM cache
inside the repository's `.build` folder:

```bash
source scripts/env.sh
fqswift build                      # debug build of the app, the core library and the fqprobe CLI
fqtest                             # the test suite; tests that need a live database skip when it is not running
```

The app is signed ad hoc, so macOS may ask again for Keychain access after each rebuild; choose "Always Allow".

### Live database tests

Tests for PostgreSQL (port 55432), MySQL (53306), MongoDB (57017) and Redis (56379) run when a server answers on that
port on 127.0.0.1 and skip otherwise. The credentials they use are local test values (see `scripts/dbtest.sh` and the
`scripts/seed-*` files); never point the tests at a real server. Sample data for each engine is in `scripts/`.

### Command-line probe

`fqprobe` exercises a driver without the app:

```bash
.build/debug/fqprobe --kind postgresql --port 55432 --user postgres --password postgres --db foxlume query "SELECT now()"
.build/debug/fqprobe --kind mysql --port 53306 --user root --password root --db foxlume meta orders
```

## Where data is stored

| Data | Location |
|---|---|
| Connections, settings, history, saved queries, filter presets, open tabs, imported themes, SSH known hosts | `~/Library/Application Support/Foxlume Query/` |
| Database and SSH passwords | macOS Keychain, service `com.foxlume.query.connection` |

Portable mode: set `FOXLUME_DATA_DIR=/some/folder` and everything, passwords included, is kept in that folder
(passwords in a file readable only by you). `scripts/run-portable.sh` starts the app this way.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N / ⇧⌘K | New connection / open connection URL |
| ⌘T / ⌘W / ⇧⌘T | New query tab / close tab / reopen closed tab |
| ⌘1 … ⌘9, ⌘{ ⌘} | Switch tabs |
| ⌘↩ / ⇧⌘↩ / ⌥⌘↩ | Run statement / run all / run without limit |
| ⌘. | Cancel query |
| ⇧⌘L | Format SQL |
| ⌥⌘E / ⌃⌘E | Explain / Explain Analyze |
| ⌃Space | Show completions |
| ⌘S | Save (staged truncates and drops, grid edits, or the SQL file) |
| ⇧⌘P | Preview SQL |
| ⇧⌘N / ⇧⌘D / ⌘⌫ | Add / duplicate / delete rows |
| ⌥↩ | Edit cell value |
| ⇧⌘F | Filter rows |
| ⌘F / ⌘G / ⇧⌘G | Find in results / next / previous match |
| ⌥⌘I | Row Inspector |
| ⌘[ / ⌘] | Previous / next page |
| ⌥⌘↑ / ⌥⌘↓ | First / last page |
| ⌘R / ⇧⌘R | Reload data / reload table list |
| ⌘K | Switch database |
| ⌥⌘1 / ⌥⌘2 | Data / Structure |
| ⌘Y | Query history |
| ⇧⌘O | Open Quickly (⌘1 … ⌘5 pick its scope, ⌘↩ opens in a new tab) |
| ⌘D | Add the query (or the selection) to Saved Queries |
| ⌃⌥⌘F | Focus the sidebar filter |
| ⌘0 | Toggle sidebar |
| ⌘/ | Toggle comment |
| ⌥⌘C / ⌥⌘J | Copy with headers / copy as JSON |
| ⌘V | Paste cells or rows into the grid |
| Shift-click a header | Add a column to the sort |
| ⇧ arrows / ⇧⌘ arrows | Extend the cell selection by one cell / to the edge |
| ⇧Space / Esc | Widen the cell selection to whole rows / end it |
| ⇧⌘E / ⌥⇧⌘E | Export results / export tables |
| ⇧⌘I | Import CSV into a table |

## Project layout

```
Sources/
  CDuckDB/              DuckDB C API module (library in Vendor/duckdb)
  FoxlumeQueryCore/     UI-independent library
    Models/             connection settings, results, schema types
    Drivers/            DatabaseConnection protocol, DatabaseSession (serial queue, ping, reconnect)
      Transport/        TCP + TLS sockets, SSH tunnel, connect deadlines
      Postgres/ MySQL/ SQLite/ DuckDB/ MongoDB/ Redis/
    SQL/                dialects, statement splitting, query languages, table queries, change generation, formatter
    Completion/         query editor completion engines
    Storage/            connections, Keychain, history, saved queries, filter presets, settings
    Grid/               sort cycle and in-memory sort, paste parsing and placement, selection figures, cell filters
    Search/             Open Quickly matching, ranking and recency
    Explain/            query plan model, parsers per engine, analysis and the Explain runner
    Theme/              built-in themes, VS Code theme import
    Export/             result export, table export and SQL dumps
    Import/             CSV import, SQL file runner, text decoding
  FoxlumeQuery/         the AppKit app
  fqprobe/              driver probe CLI
Tests/FoxlumeQueryCoreTests/   Swift Testing suites for the core library
Tests/FoxlumeQueryAppTests/    editor, filter bar, workspace, saved query, Open Quickly and grid selection / paste checks against the real AppKit classes
scripts/                build, environment, test servers, sample data
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to work on the code and [SECURITY.md](SECURITY.md) for reporting
security issues.

## License

Foxlume Query is free software under the GNU Affero General Public License v3.0 or later; see [LICENSE](LICENSE).
It includes DuckDB (MIT License); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Its features and interface are inspired by [TablePro](https://github.com/TableProApp/TablePro). Foxlume Query is an
independent project and is not affiliated with TablePro.
