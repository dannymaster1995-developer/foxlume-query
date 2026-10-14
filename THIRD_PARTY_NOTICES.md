# Third-party notices

Foxlume Query is licensed under the GNU Affero General Public License v3.0 or later (see `LICENSE`).
It includes or builds on the following third-party work.

## DuckDB

The app links DuckDB's official prebuilt C library (`Vendor/duckdb/duckdb.h`, and `libduckdb.dylib`, which
`scripts/fetch-duckdb.sh` downloads from https://github.com/duckdb/duckdb/releases, version v1.5.6).

DuckDB is released under the MIT License, Copyright 2018-2025 Stichting DuckDB Foundation. The full text is in
`Vendor/duckdb/LICENSE`. DuckDB itself bundles further open-source components; their licenses are listed at
https://github.com/duckdb/duckdb/tree/main/third_party.

## Color themes

The built-in editor themes reproduce the published color palettes of these themes. All names belong to their
authors; Foxlume Query is not affiliated with them.

| Theme | Author | Project |
|---|---|---|
| Dracula | Zeno Rocha and contributors | https://draculatheme.com (MIT) |
| One Dark, One Light | GitHub / Atom | https://github.com/atom/atom (MIT) |
| Nord | Arctic Ice Studio and Sven Greb | https://www.nordtheme.com (MIT) |
| Solarized Dark, Solarized Light | Ethan Schoonover | https://ethanschoonover.com/solarized (MIT) |
| GitHub Light, GitHub Dark | GitHub | https://primer.style (MIT) |
| Monokai | Wimer Hazenberg | https://monokai.nl (original color scheme) |
| Catppuccin Mocha, Catppuccin Latte | Catppuccin | https://catppuccin.com (MIT) |

## TablePro

Foxlume Query's feature set and user interface are inspired by TablePro
(https://github.com/TableProApp/TablePro), which is licensed under the GNU AGPL v3. Foxlume Query is an
independent project and is not affiliated with or endorsed by TablePro.
