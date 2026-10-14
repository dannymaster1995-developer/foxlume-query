# Changelog

## 0.1.0 (unreleased)

First public version.

- Native drivers for PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, MongoDB and Redis, with TLS and SSH tunnels.
- Table, collection and key browsing with paging, filters, in-place editing, Preview SQL and transactional save.
- Rename, Truncate and Drop from the sidebar, with Truncate and Drop staged until Save.
- Structure editing and New Table for PostgreSQL and MySQL: columns, indexes, foreign keys and comments, saved as ALTER statements after a preview.
- Export of many tables to CSV, JSON, NDJSON or SQL dumps; CSV import with column mapping; running large `.sql` / `.sql.gz` files.
- Query editor with highlighting, context-aware completion for SQL (per dialect), MongoDB and Redis, formatting, history and `.sql` files.
- Saved queries with nested folders, per-connection or shared scope and completion keywords, from a query tab (⌘D) or the history.
- Open Quickly (⇧⌘O): fuzzy search over tables, views, databases, schemas, saved queries and history, across open connections, ranked by frecency. The sidebar filter moved to ⌃⌥⌘F.
- Safe Mode levels per connection, from Silent to Read-Only, with Touch ID for the strictest levels.
- Foreign key navigation, Row Inspector, find in results, server-side row caps, create and drop databases and schemas.
- Connection health checks with automatic reconnect.
- Light, Dark and System appearance; built-in and VS Code editor themes.
