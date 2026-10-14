<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="Foxlume Query app icon">

# Foxlume Query

**A fast, native macOS database client for PostgreSQL and MySQL.**<br>
Browse tables, write SQL with smart autocomplete, edit data safely and understand your queries, in an app built only with Swift and AppKit.

[![CI](https://github.com/dannymaster1995-developer/foxlume-query/actions/workflows/ci.yml/badge.svg)](https://github.com/dannymaster1995-developer/foxlume-query/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-6-F05138.svg)
![Status](https://img.shields.io/badge/status-alpha-orange.svg)

[Features](#features) · [Databases](#supported-databases) · [Install](#install) · [Shortcuts](#keyboard-shortcuts) · [FAQ](#faq) · [Contributing](#contributing)

<img src="docs/images/data-grid.png" alt="Foxlume Query showing a PostgreSQL table with multi-column sort and a cell selection summary" width="900">

</div>

## Why Foxlume Query?

- **Native and light.** A real Mac app (AppKit, no Electron, no Java). It starts fast and stays responsive on tables with millions of rows.
- **No drivers to install.** The PostgreSQL, MySQL, MongoDB and Redis protocols are built into the app in Swift.
- **Safe by default.** Edits are staged until you save, saves run in a transaction, and each connection has a Safe Mode, from "ask before writing" to Touch ID or fully read-only.
- **Free and open source** under the AGPL-3.0. Inspired by [TablePro](https://github.com/TableProApp/TablePro), and an open alternative to TablePlus, Sequel Ace and DBeaver for Mac users.

> [!NOTE]
> Foxlume Query is in **early alpha (0.1.0)**. There are no prebuilt downloads yet, so you [build it from source](#install) in a few minutes. Bug reports and ideas are very welcome.

## Features

### Write SQL faster

<img src="docs/images/autocomplete.png" alt="Context-aware SQL autocomplete suggesting the columns of a joined table" width="820">

- **Context-aware autocomplete.** It knows the clause you are in, the tables and aliases in scope, CTEs and subqueries. It suggests columns with their types and keys, functions with signatures, and keywords for your database's dialect.
- **Saved queries.** Save a query with ⌘D, organise saved queries in folders, and give one a keyword to insert it while you type.
- **Run what you need.** Run the statement under the cursor (⌘↩), everything (⇧⌘↩) or without the row limit (⌥⌘↩). Format SQL (⇧⌘L) and keep a searchable history.
- **Open Quickly (⇧⌘O).** One fuzzy search across tables, views, functions, databases, saved queries and history.

### Browse and edit data

- **A fast grid** with server-side paging, sorting on several columns (Shift-click) and filters: between, regex, IN, match case, and saved presets.
- **Spreadsheet-style editing:** select ranges, copy as TSV, paste from Excel or CSV, fill a column, see sum and average of the selection. Every change waits for ⌘S, and Preview SQL (⇧⌘P) shows exactly what will run.
- **Follow foreign keys** with one click, inspect a row in the Row Inspector (⌥⌘I), and find text in results or across the whole table.

### Understand your queries

<img src="docs/images/explain-diagram.png" alt="Explain Analyze plan shown as a diagram with the slowest step highlighted" width="820">

- **Explain (⌥⌘E) and Explain Analyze (⌃⌘E)** draw the query plan as a diagram or a tree. Slow steps are highlighted, and warnings such as large scans or wrong row estimates are shown with each step.
- Explain Analyze on PostgreSQL runs inside a transaction that is rolled back, so even an `UPDATE` changes nothing.

### Design your schema

<img src="docs/images/er-diagram-dark.png" alt="Entity-relationship diagram of the Chinook sample database" width="820">

- **ER diagrams** of a whole schema, with crow's-foot relationships, drag-to-arrange layouts that are remembered, and PNG or PDF export.
- **A structure editor** for PostgreSQL and MySQL: add or change columns, indexes, foreign keys and comments, review the generated `ALTER` statements, then save. **New Table** builds a `CREATE TABLE` with a live preview.
- **Functions, procedures, triggers and types** in the sidebar, with their source and "Edit in Query Tab".

### Import and export

- **Export Tables** to CSV, JSON, NDJSON or a SQL dump (structure, data or both, optionally gzipped), streamed from a consistent snapshot.
- **Import CSV** with encoding and delimiter detection, column mapping and a choice of what to do with bad rows.
- **Run SQL files** (`.sql`, `.sql.gz`) of any size.

### Connect securely

- **TLS 1.3**, with Verify CA / Verify Identity modes, a custom CA and client certificates (PEM or PKCS#12).
- **SSH tunnels**, connection URLs (`postgres://`, `mysql://`…) and passwords kept in the macOS Keychain.
- **Safe Mode** per connection: Silent, Alert, Safe Mode with Touch ID, or Read-Only. Production connections are clearly labelled.

<details>
<summary><b>More screenshots</b></summary>
<br>

| Open Quickly | Structure editor |
|---|---|
| <img src="docs/images/open-quickly.png" alt="Open Quickly fuzzy search over tables and history" width="420"> | <img src="docs/images/structure-editor.png" alt="Structure editor for a PostgreSQL table" width="420"> |

| ER diagram (light) | |
|---|---|
| <img src="docs/images/er-diagram-light.png" alt="ER diagram in light appearance" width="420"> | |

</details>

## Supported databases

| Database | Status | Notes |
|---|---|---|
| **PostgreSQL** | ✅ Supported | Tested with 18; SCRAM-SHA-256, MD5, TLS 1.3 |
| **MySQL** | ✅ Supported | Tested with 8.4; caching_sha2_password, TLS 1.3 |
| MariaDB | 🧪 Beta | Uses the MySQL driver |
| SQLite | 🧪 Beta | Uses the system SQLite |
| DuckDB | 🧪 Beta | Opens `.duckdb`, Parquet, CSV and JSON files |
| MongoDB | 🧪 Beta | `mongodb://` and `mongodb+srv://`, MQL shell |
| Redis | 🧪 Beta | ACL, TLS, Sentinel and Cluster; keys as a tree |

PostgreSQL and MySQL are the focus of the first releases. Beta engines work, but they have had less testing and some features are missing.

## Install

**Requirements:** macOS 13 or later on Apple silicon, and Swift 6 (Xcode, or just the Command Line Tools: `xcode-select --install`).

```bash
git clone https://github.com/dannymaster1995-developer/foxlume-query.git
cd foxlume-query
scripts/build-app.sh            # builds "build/Foxlume Query.app" (downloads DuckDB on first run)
open "build/Foxlume Query.app"
```

The app is signed ad hoc. After a rebuild, macOS may ask again for Keychain access; choose **Always Allow**.

Developing on Foxlume Query? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the test suite, local test servers and project layout.

## Keyboard shortcuts

The most used ones:

| Keys | Action |
|---|---|
| ⌘↩ / ⇧⌘↩ | Run statement / run all |
| ⇧⌘O | Open Quickly |
| ⌃Space | Show completions |
| ⌥⌘E / ⌃⌘E | Explain / Explain Analyze |
| ⌘S / ⇧⌘P | Save changes / preview their SQL |
| ⇧⌘L | Format SQL |
| ⌘D | Save the query |

<details>
<summary><b>All shortcuts</b></summary>
<br>

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
| ⌘D | Add the query (or the selection) to Saved Queries |
| ⇧⌘O | Open Quickly (⌘1 … ⌘5 pick its scope, ⌘↩ opens in a new tab) |
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
| ⌃⌥⌘F | Focus the sidebar filter |
| ⌘0 | Toggle sidebar |
| ⌘/ | Toggle comment |
| ⌥⌘C / ⌥⌘J | Copy with headers / copy as JSON |
| ⌘V | Paste cells or rows into the grid |
| Shift-click a header | Add a column to the sort |
| ⇧ arrows / ⇧⌘ arrows | Extend the cell selection by one cell / to the edge |
| ⇧Space / Esc | Widen the cell selection to whole rows / end it |
| ⌘= / ⌘- / ⌘C | Zoom in / zoom out / copy as image, in a plan or ER diagram |
| ⇧⌘E / ⌥⇧⌘E | Export results / export tables |
| ⇧⌘I | Import CSV into a table |

</details>

## FAQ

<details>
<summary><b>Is there a download?</b></summary>

Not yet. Foxlume Query is in alpha, so you build it from source with the commands in [Install](#install). It takes a few minutes and needs no Apple developer account.
</details>

<details>
<summary><b>Where are my connections and passwords stored?</b></summary>

Connections, settings, history and saved queries are in `~/Library/Application Support/Foxlume Query/`. Passwords and TLS key passphrases are in the macOS Keychain. For a portable setup, set `FOXLUME_DATA_DIR=/some/folder` (or use `scripts/run-portable.sh`), and everything, passwords included, is kept in that folder.
</details>

<details>
<summary><b>Can I use it with my production database?</b></summary>

Yes, carefully: it is alpha software. Give the connection a Production label and a Safe Mode (Alert, Safe Mode with Touch ID, or Read-Only), so every write asks first or is refused.
</details>

<details>
<summary><b>What is not there yet?</b></summary>

SQL Server and other engines, plan comparison, JSON and XLSX import, MongoDB X.509 authentication and certificate revocation checks. See the [CHANGELOG](CHANGELOG.md) for what is new.
</details>

## Contributing

Bug reports, ideas and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). To report a security issue, see [SECURITY.md](SECURITY.md).

## License

Foxlume Query is free software under the [GNU Affero General Public License v3.0 or later](LICENSE). It includes DuckDB (MIT License); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Its features and interface are inspired by [TablePro](https://github.com/TableProApp/TablePro). Foxlume Query is an independent project and is not affiliated with TablePro.
