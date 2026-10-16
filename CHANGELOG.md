# Changelog

All notable changes to Foxlume Query are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First public version.

### Added

- Native drivers for PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, MongoDB and Redis, with TLS and SSH tunnels.
- Table, collection and key browsing with paging, filters, in-place editing, Preview SQL and transactional save.
- Rename, Truncate and Drop from the sidebar, with Truncate and Drop staged until Save.
- Structure editing and New Table for PostgreSQL and MySQL: columns, indexes, foreign keys and comments, saved as ALTER statements after a preview.
- Export of many tables to CSV, JSON, NDJSON or SQL dumps; CSV import with column mapping; running large `.sql` / `.sql.gz` files.
- Query editor with highlighting, context-aware completion for SQL (per dialect), MongoDB and Redis, formatting, history and `.sql` files.
- Saved queries with nested folders, per-connection or shared scope and completion keywords, from a query tab (⌘D) or the history.
- Explain (⌥⌘E) and Explain Analyze (⌃⌘E): plan tree with costs, rows, timings, expensive steps and warnings, a detail pane and the raw output. Explain Analyze rolls back on PostgreSQL and runs only reads elsewhere. EXPLAIN without ANALYZE now counts as a read for Safe Mode and read-only connections.
- Plan diagram: Explain results open in a Diagram mode (next to Tree and Raw) that draws the plan as boxes coloured by severity, with cost, rows and time per step; zoom by pinch, ⌘-scroll, ⌘= / ⌘- or Fit; the selection is shared with the tree and the detail pane; export as PNG or copy as an image.
- ER diagrams for PostgreSQL, MySQL, MariaDB, SQLite and DuckDB (Database › ER Diagram, the sidebar, or Show in ER Diagram on a table): tables with key markers and types, column-to-column foreign key lines with crow's foot cardinality, related tables grouped and tinted, drag to arrange with positions saved per connection and schema (`er-diagram-layouts.json`) and Reset Layout, Find Table, Keys Only, double-click to open a table, export as PNG or PDF and copy as an image. PostgreSQL and MySQL read a schema's columns, keys and foreign keys in three catalog queries.
- Open Quickly (⇧⌘O): fuzzy search over tables, views, databases, schemas, saved queries and history, across open connections, ranked by frecency. The sidebar filter moved to ⌃⌥⌘F.
- Data grid: multi-column sort (Shift-click a header; ORDER BY on the server, in memory for query results); filters with between, not between, regex, not in list, is empty, Match Case and Match All / Match Any; filter presets per table; Filter conditions from a cell's menu; cell range selection with copy as TSV, paste of TSV or CSV as staged edits or new rows, Fill Column and Fill Selected Cells, a Set Value submenu in the cell menu (NULL, Empty String, DEFAULT and Current Timestamp, written as CURRENT_TIMESTAMP) for the selected cells, count / sum / average / min / max of the selected cells, and two more Copy As formats in the cell menu: IN List (the clicked column's values of the selected rows or cells as `(1, 2, 3)` / `('a', 'b')`, without duplicates or NULLs) and SQL UPDATE (one statement per selected row of a table with a primary key, setting every other column from the values shown, edits included, and matching the key; composite keys supported). SQLite connections get a REGEXP function, and DuckDB text filters now match `%` and `_` literally.
- Procedures, functions, triggers and types (PostgreSQL), procedures, functions and triggers (MySQL, MariaDB), triggers (SQLite) and macros (DuckDB) in the sidebar and Open Quickly, with a read-only definition tab, Copy Definition, Edit in Query Tab, New Trigger… and Drop…. The Structure view gains Check Constraints and Triggers sections. Scripts with CREATE PROCEDURE / FUNCTION / TRIGGER / EVENT … BEGIN … END bodies now split correctly without DELIMITER.
- TLS certificates per connection: a CA certificate file, a client certificate and key (PEM, encrypted keys included) or a PKCS#12 file, with the key passphrase in the Keychain. New SSL mode Verify CA (chain only); Verify Full is now labelled Verify Identity. TLS now runs on Network.framework, so connections negotiate TLS 1.3 where the server supports it, and certificate errors are spelled out (unknown CA, host name mismatch, expired, client certificate refused, wrong passphrase). URLs accept `sslrootcert`, `sslcert`, `sslkey`, `sslpassword` (PostgreSQL) and `ssl-ca`, `ssl-cert`, `ssl-key` (MySQL); MongoDB connection strings accept `tlsCAFile`, `tlsCertificateKeyFile` and `tlsAllowInvalidHostnames`. Behind an SSH tunnel, TLS checks the real host name instead of 127.0.0.1.
- Safe Mode levels per connection, from Silent to Read-Only, with Touch ID for the strictest levels.
- Foreign key navigation, Row Inspector, find in results, server-side row caps, create and drop databases and schemas.
- Connection health checks with automatic reconnect.
- Light, Dark and System appearance; built-in and VS Code editor themes.

[Unreleased]: https://github.com/dannymaster1995-developer/foxlume-query/commits/main
