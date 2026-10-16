# Roadmap

What is done, what comes next, and what is planned for later. Each task has an ID (`FQ-###`) that commits and
pull requests can refer to. A task is ticked when it is merged with tests, a CHANGELOG entry and README updates.
Shipped changes are listed in [CHANGELOG.md](CHANGELOG.md); ideas and bugs are welcome as
[issues](https://github.com/dannymaster1995-developer/foxlume-query/issues).

The order: first PostgreSQL and MySQL complete and solid, with inline AI suggestions in the editor, then more
databases (most used first), then the AI assistant and MCP, then advanced connection setups.

## v0.1.0: PostgreSQL and MySQL, complete (current)

The first release. Everything a daily PostgreSQL or MySQL user expects from a database client works and is tested
against several server versions.

Done:
- [x] FQ-001 Native drivers: PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, MongoDB, Redis (Sentinel, Cluster)
- [x] FQ-002 SSH tunnels and TLS, with Safe Mode levels and Touch ID
- [x] FQ-003 Browse tables, collections and keys with paging, filters and in-place editing
- [x] FQ-004 Preview SQL and transactional save; Rename, Truncate and Drop from the sidebar
- [x] FQ-005 Structure editing and New Table for PostgreSQL and MySQL
- [x] FQ-006 Multi-table export (CSV, JSON, NDJSON, SQL), CSV import, running large SQL files
- [x] FQ-007 Query editor: highlighting, completion for SQL, MongoDB and Redis, formatting, history
- [x] FQ-008 Saved queries with folders and completion keywords
- [x] FQ-009 Explain and Explain Analyze, with a plan tree and a plan diagram
- [x] FQ-010 ER diagrams with saved layouts and PNG / PDF export
- [x] FQ-011 Open Quickly across connections
- [x] FQ-012 Data grid: multi-column sort, advanced filters and presets, cell ranges, paste, fill, selection figures
- [x] FQ-013 Functions, procedures, triggers and types in the sidebar
- [x] FQ-014 TLS certificates: custom CA, client certificates, PKCS#12, TLS 1.3
- [x] FQ-015 Row Inspector, foreign key navigation, find in results, Duplicate Row, Run Without Limit, Reopen Closed Tab
- [x] FQ-016 Connection health checks and automatic reconnect; themes, including VS Code theme import
- [x] FQ-017 Release process: VERSION file, Keep a Changelog, release script and workflow, ROADMAP

Data grid:
- [x] FQ-101 Set Value: DEFAULT and NOW() in the cell menu
- [x] FQ-102 Copy rows as an IN list or as UPDATE statements
- [x] FQ-103 Columns: hide and show, jump to column, size to fit, remembered layout
- [x] FQ-104 Cell editors: date and time picker, enum list, boolean toggle, foreign key value picker
- [x] FQ-105 Value viewers: JSON tree, image preview, hex

Editor and results:
- [x] FQ-106 Highlight the current statement, word wrap, run and move to the next statement (⌃⌘↩)
- [x] FQ-107 Per-connection query timeout and startup commands
- [x] FQ-122 Tab bar overflow: show the tabs that fit (the selected and most recently used stay visible) and a "+N" button listing the rest; opening tabs never widens the window

Schema and server:
- [x] FQ-108 Create and edit views
- [ ] FQ-109 Column reorder and table comments in the structure editor
- [ ] FQ-110 Rename schemas (PostgreSQL); rename and copy databases where the server allows it
- [ ] FQ-111 Maintenance: VACUUM and ANALYZE (PostgreSQL), OPTIMIZE, ANALYZE and CHECK TABLE (MySQL)
- [ ] FQ-112 Server activity: running sessions, cancel or kill a query, slow queries

Data in and out:
- [ ] FQ-113 XLSX export; JSON and XLSX import
- [ ] FQ-114 Backup and restore with pg_dump / pg_restore and mysqldump

Navigation and safety:
- [ ] FQ-115 Recent and favourite tables in the sidebar
- [ ] FQ-116 Toolbar tinted with the connection's environment colour

AI in the editor (off by default; nothing leaves the Mac unless the user turns it on):
- [ ] FQ-120 Inline suggestions: grey ghost text after the caret from an AI provider (OpenAI-compatible, including Ollama and other local models, and Claude), with the schema as context; Tab accepts, Esc dismisses; API keys in the Keychain
- [ ] FQ-121 GitHub Copilot as a source of inline suggestions: Sign in with GitHub in Settings, the Copilot language server downloaded on first use at a pinned version and checksum, telemetry off by default

Quality and release:
- [ ] FQ-117 Server version matrix on GitHub Actions (on release tags, weekly and on demand): PostgreSQL 13 to 18, MySQL 8.0 and 8.4, MariaDB 10.11 and 11.4
- [ ] FQ-118 UI autotest scripts that walk every PostgreSQL and MySQL feature against the local servers; the whole set runs before each release
- [ ] FQ-119 Publish v0.1.0 on GitHub Releases with a downloadable app

## v0.2.0: more databases, most used first

Bring the beta engines up to the same standard, then add new engines in order of use. Oracle is not planned.

- [ ] FQ-201 MariaDB, SQLite, DuckDB, MongoDB and Redis from Beta to supported, including MongoDB Insert and Edit Document in Extended JSON
- [ ] FQ-202 SQL Server
- [ ] FQ-203 PostgreSQL and MySQL compatible services: CockroachDB, Redshift, TiDB, OceanBase
- [ ] FQ-204 Elasticsearch and OpenSearch
- [ ] FQ-205 Snowflake
- [ ] FQ-206 Cassandra and ScyllaDB
- [ ] FQ-207 ClickHouse
- [ ] FQ-208 BigQuery
- [ ] FQ-209 DynamoDB
- [ ] FQ-210 libSQL / Turso and Cloudflare D1

## v0.3.0: AI and MCP

Off by default; nothing leaves the Mac unless the user turns it on and picks a provider.

- [ ] FQ-301 AI assistant: explain, fix and write queries with the schema as context; any provider, including local models (builds on the providers from FQ-120)
- [ ] FQ-302 Chat modes Ask, Edit and Agent; every statement still goes through Safe Mode
- [ ] FQ-303 MCP server on localhost for Claude Code, Cursor and other clients: read-only by default, never exposes passwords

## v0.4.0: advanced connections

- [ ] FQ-401 Nested connection groups, tags, favourites and recent connections
- [ ] FQ-402 Copy Connection String, Move to Group, export and import connections as files
- [ ] FQ-403 Password sources: ask every time, ~/.pgpass, environment variable, command
- [ ] FQ-404 Shared SSH and credential profiles
- [ ] FQ-405 Import connections from other database apps
- [ ] FQ-406 SOCKS5, Cloudflare Access, Cloud SQL Proxy, kubectl and AWS SSM tunnels
- [ ] FQ-407 Cloud sign-in: AWS IAM, Microsoft Entra ID, Google Cloud IAM
- [ ] FQ-408 Open Project Folder: connections from `.env`, `docker-compose.yml` and Prisma schemas
- [ ] FQ-409 SQLite files over SSH

## Later

Order and scope can change.

**Editor and results**
- [ ] FQ-501 Multi-cursor editing
- [ ] FQ-502 Query parameters (`:name`) with an input panel
- [ ] FQ-503 Database per query tab
- [ ] FQ-504 Drop a `.sql` file into the editor; notice when an open file changes on disk
- [ ] FQ-505 Completion of enum values; MongoDB query formatting
- [ ] FQ-506 Editor zoom (⌘= / ⌘-), code folding, Vim mode
- [ ] FQ-507 Pinned and named result tabs; JSON view of results; time per statement
- [ ] FQ-508 History filters (errors, date); notification when a long query finishes

**Data and server**
- [ ] FQ-511 Users and roles
- [ ] FQ-512 Copy data from one connection to another
- [ ] FQ-513 HTML and XML export; JSON Lines import

**App**
- [ ] FQ-521 Universal app for Intel and Apple silicon Macs
- [ ] FQ-522 Theme editor; editor font family, tab width and keyword case
- [ ] FQ-523 Date format and row height settings for the data grid
- [ ] FQ-524 Custom keyboard shortcuts and toolbar; native window tabs
- [ ] FQ-525 Localization; What's New and Getting Started screens
- [ ] FQ-526 Developer ID signing, notarization and automatic updates
