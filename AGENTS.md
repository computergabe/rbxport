# AGENTS.md

Guidance for coding agents and contributors working on this fork
(computergabe/rbxport). Read the [README](README.md) and the
[developer reading path](README.md#developer-reading-path) for the upstream app.

## What this fork adds

A Windows "Music → Rekordbox" importer on top of upstream rbxport: it takes
downloaded ZIPs and audio from inbox folders, tags and sorts them into a music
library folder, registers them in the active rekordbox library and analyzes
them. Work happens on `feat/windows-import-command`; releases are tagged
`windows-music-<version>`.

| Area | Files |
| --- | --- |
| Window and launchers | `scripts/windows-import/Music-Import-GUI.ps1`, `Music-To-Rekordbox.ps1`, `Setup-Music-Import.ps1`, `Create-Desktop-Shortcut.ps1` |
| Organizer logic | `scripts/windows-import/Music-Import.Core.psm1` |
| Package and tests | `scripts/windows-import/Build-Package.ps1`, `Test-Package.ps1`, `Test-Native-Organizer.ps1` |
| Native commands | `src-tauri/src/import_cli.rs` (`--import`, `--analyze`, `--find-missing`), `music_tag.rs` (`--write-tags`), `music_inspect.rs` (`--inspect-list`), dispatched from `lib.rs` and `main.rs` |
| Analysis on import | `src-tauri/src/analysis.rs` (`analyse_imported`) |
| Library writes | `crates/rbl-db/src/write.rs` (`contentFile` fingerprints, path lookup) |
| Analysis files | `crates/rbl-anlz/src/encode.rs` (`share_tree_ppth`, section order) |

User docs: [docs/user/windows-import.md](docs/user/windows-import.md).
Why things are the way they are:
[docs/reference/windows-import-internals.md](docs/reference/windows-import-internals.md).
Read that before changing analysis, `PPTH`, `contentFile` or path matching.

## Rules learned the hard way

- rekordbox 7 ignores analysis whose files don't match their `contentFile`
  rows, and ignores the beat grid unless `PPTH` is `?/<file name>`.
- Match `FolderPath` case-insensitively on Windows.
- `FolderPath` can be a streaming link (`spotify:track:...`); never treat it
  as a missing file.
- Never write to the user's download. Tags go into the verified copy in the
  music library folder.
- Only touch the rekordbox database while rekordbox and its agent are closed,
  and honor Library Protection.
- Run Rust tests with `RB_LITE_TEST=1` so installed-library writes are refused.

## PowerShell notes

Scripts target Windows PowerShell 5.1 with `Set-StrictMode -Version Latest`.

- Read optional JSON properties with `Get-MusicField`; a missing property
  throws under StrictMode.
- `ConvertFrom-Json` turns `[]` into `@($null)`; filter out nulls.
- In a .NET method call a comma separates arguments: build strings into a
  variable first.
- Normalize child-process output to CRLF before putting it in a WinForms
  text box.
- `exit` inside `try` still runs `finally`.

## Checks before committing

Build from Visual Studio Developer PowerShell (x64 C++ tools) with Strawberry
Perl on `PATH` and `OPENSSL_SRC_PERL` pointing at it; see
[Local Windows builds](docs/user/windows-import.md#local-windows-builds).

- `pnpm tauri build --no-bundle --ci`
- `cargo test -p rbxport --release --features tauri/custom-protocol --lib <filter>`
  for each of `analysis`, `usb_import`, `import_cli`, `music_` and `grid`,
  with `RBXPORT_TEST=1` and `LC_ALL=C`.
- `cargo test -p rbl-db -p rbl-anlz` with `RB_LITE_TEST=1`.
- `cargo clippy -p rbxport --release --features tauri/custom-protocol --lib -- -D warnings`,
  and Clippy on `rbl-db` and `rbl-anlz`.
- `pnpm test` for frontend changes.
- `scripts/windows-import/Test-Package.ps1` for script changes; it uses a mock
  `rbxport.exe`, so add a mock branch for any new native argument.

## Releases

Bump the version in `Cargo.toml` (workspace), `package.json` and
`src-tauri/tauri.conf.json`, and the version text in `README.md` and
`scripts/windows-import/START-HERE.txt`. Build with `pnpm tauri build`, then
package with `Build-Package.ps1`, run the package tests from the extracted
ZIP, and publish the ZIP and checksums as a GitHub release
`windows-music-<version>`. Record the validation in the release notes, and
add the version to the history table in the internals reference.

Commit as the repository owner. Keep upstream authorship and GPL notices.
