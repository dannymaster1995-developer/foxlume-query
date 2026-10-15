# Roadmap

What is done, what comes next, and what is planned for later. Each task has an ID (`FQ-###`) that commits and
pull requests can refer to. A task is ticked when it is merged with tests, a CHANGELOG entry and README updates.
Shipped changes are listed in [CHANGELOG.md](CHANGELOG.md); ideas and bugs are welcome as
[issues](https://github.com/dannymaster1995-developer/foxlume-query/issues).

## v0.1.0: first public release (current)

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
- [ ] FQ-018 Publish v0.1.0 on GitHub Releases with a downloadable app

## v0.2.0: everyday polish (next)

- [ ] FQ-101 Set Value: DEFAULT and NOW() in the cell menu
- [ ] FQ-102 MongoDB: Insert Document and Edit Document in Extended JSON
- [ ] FQ-103 Copy rows as an IN list or as UPDATE statements
- [ ] FQ-104 Columns: hide and show, jump to column, size to fit, remembered layout
- [ ] FQ-105 Cell editors: date picker, enum list, boolean toggle, foreign key value picker
- [ ] FQ-106 Value viewers: JSON tree, image preview, hex
- [ ] FQ-107 Editor: highlight the current statement, word wrap, run and move to the next statement (⌃⌘↩)
- [ ] FQ-108 Per-connection query timeout and startup commands
- [ ] FQ-109 Toolbar tinted with the connection's environment colour
- [ ] FQ-110 Recent and favourite tables in the sidebar

## Later

Grouped by area; order and scope can change.

**Databases**
- [ ] FQ-201 TiDB, CockroachDB, Redshift and OceanBase on the existing MySQL and PostgreSQL drivers
- [ ] FQ-202 ClickHouse driver
- [ ] FQ-203 SQL Server driver

**Connections**
- [ ] FQ-211 Nested connection groups, favourites and recent connections
- [ ] FQ-212 Copy Connection String, Move to Group, export a connection to a file
- [ ] FQ-213 Password sources: ask every time, ~/.pgpass, environment variable, command
- [ ] FQ-214 Shared SSH and credential profiles
- [ ] FQ-215 Import connections from other database apps

**Schema and server**
- [ ] FQ-221 Create and edit views
- [ ] FQ-222 Column reorder and table comments in the structure editor
- [ ] FQ-223 Rename and copy databases and schemas
- [ ] FQ-224 Maintenance commands (VACUUM, ANALYZE, OPTIMIZE)
- [ ] FQ-225 Users and roles

**Editor and results**
- [ ] FQ-231 Multi-cursor editing
- [ ] FQ-232 Query parameters (`:name`) with an input panel
- [ ] FQ-233 Database per query tab
- [ ] FQ-234 Drop a `.sql` file into the editor; notice when an open file changes on disk
- [ ] FQ-235 Completion of enum values; MongoDB query formatting
- [ ] FQ-236 Editor zoom (⌘= / ⌘-)
- [ ] FQ-237 Pinned and named result tabs; JSON view of results; time per statement
- [ ] FQ-238 History filters (errors, date); notification when a long query finishes

**Import, export, backup**
- [ ] FQ-241 XLSX export; JSON and XLSX import
- [ ] FQ-242 Backup and restore with pg_dump, mysqldump and mongodump

**App**
- [ ] FQ-251 Theme editor; editor font family, tab width and keyword case
- [ ] FQ-252 Date format and row height settings for the data grid
- [ ] FQ-253 Localization
- [ ] FQ-254 Developer ID signing, notarization and automatic updates
