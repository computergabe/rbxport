<p align="center">
  <a href="https://github.com/computergabe/rbxport">
    <img src="docs/assets/brand/combined/rbxport-logo-color-white.png" alt="rbxport" width="360">
  </a>
</p>

# rbxport — Windows PowerShell import fork

This public community fork of [chrisle/rbxport](https://github.com/chrisle/rbxport)
adds **on-demand Windows automation**: extract Bandcamp ZIPs, verify the files,
and register their tracks in the rekordbox library with one desktop button.
It is an independent preview build, not an official upstream release.

## Download and use the Windows preview

[Download the Windows x64 package](https://github.com/computergabe/rbxport/releases/tag/windows-import-preview.1)
or [read the full PowerShell guide](docs/user/windows-import.md).
The release includes the app, scripts, shortcut setup, license text, checksums,
and corresponding source. Download users do not need Rust or C++ build tools.

1. Extract the package into a permanent, writable folder; keep its files together.
2. Open `RBXPORT-Bandcamp/rbxport.exe`. In Preferences, disable **Library
   Protection** when you intend to permit imports, and disable automatic update
   checking to keep this custom build. Close RBXPORT afterward.
3. Open PowerShell in the extracted package folder and create the desktop button:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Create-Desktop-Shortcut.ps1
   ```

4. Put ZIPs in your `Downloads\Bandcamp` folder, close rekordbox and its tray
   agent, then click **Bandcamp → Rekordbox**. Reopen rekordbox after it finishes.

The button runs once per click. It verifies file presence and sizes in staging
and the final `Music\Rekordbox Collection` folder, saves a retry queue, and only
then deletes each ZIP. It never overwrites an existing album folder. Failed
library imports remain queued, and retries skip tracks already registered at
the same path. The launcher never changes Library Protection itself.

### PowerShell automation without the Bandcamp launcher

The custom executable accepts one or more `--import` arguments and a **new**
JSON report path. It imports once and exits with status 0 for complete success
or a nonzero status for failure. Existing report files are never overwritten.

```powershell
$report = Join-Path $env:TEMP ('rbxport-' + [guid]::NewGuid() + '.json')
$album = 'D:\Music\An Album'
$arguments = '--import "' + $album.TrimEnd('\') + '" --import-report "' + $report + '"'
$process = Start-Process -FilePath .\RBXPORT-Bandcamp\rbxport.exe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
if (-not (Test-Path -LiteralPath $report)) { throw 'No import report was produced.' }
$result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
if ($process.ExitCode -ne 0 -or -not $result.ok) { throw ($result | ConvertTo-Json -Depth 8) }
$result.report
```

This command refuses imports while rekordbox or another RBXPORT instance is
running and honors Library Protection. It does not watch folders or request
track analysis. Rekordbox can analyze the imported tracks after reopening.

### Build from source and validation

Use this fork's `feat/windows-import-command` branch or the preview release tag.
The [local Windows build instructions](docs/user/windows-import.md#local-windows-builds)
cover Rust, MSVC, the Windows SDK, Perl, Node, and pnpm. Build with the Tauri
builder so the executable includes its interface.

The preview's native command tests, import integration test, Windows code
checks, and packaged error/exit check passed. A real run registered 245 tracks
and they appeared in rekordbox 7.2.19, including 14 tracks from five new ZIPs.
This is a single-machine result, not a claim of compatibility with every
rekordbox version. The full Windows workspace suite has 11 unresolved tests
with Unix-style path expectations; the development PR remains draft.
Keep a library backup before using the preview.

## About the original project

rbxport is a music library management app inspired by rekordbox. It keeps its
feature set deliberately small, aiming for a faster, simpler user experience.

Its scope is limited to library management, USB exporting, and PRO DJ LINK.

## Project vision

The core vision of rbxport is **fewer features**.

Because rbxport is open source, you are free to fork it and build a version of
rekordbox customized by the community. The core project does not aim to be that.
A project that keeps adding features eventually becomes what rekordbox already is: full-featured
DJ software. rbxport stays small on purpose. Any contribution that adds a feature
is weighed carefully against this vision, and a good feature can still be
declined.

Two commitments define what "small" must not cost:

- **Compatibility.** rbxport aims to be fully compatible with the current
  version of rekordbox and all the hardware that rekordbox supports.
- **Performance.** rbxport maintains its speed through a performance budget,
  defined in `perf-budgets.json` and enforced by `pnpm budget` and CI. See
  [Development conventions](docs/development/conventions.md).

If you want to propose a feature, read
[Feature proposals](CONTRIBUTING.md#feature-proposals) in the contributing guide
first.

## Tech stack

| Layer | Technology |
| --- | --- |
| Desktop app | Tauri 2. |
| Frontend | React and TypeScript, with TanStack Virtual for track browsing. |
| Backend | Rust, with independent `rbl-*` crates for library, audio, export, and LINK logic. |
| Database | SQLCipher for rekordbox libraries and OneLibrary USB exports. |
| Build tooling | Vite, pnpm, and Cargo. |
| Testing | Vitest, Playwright, and Rust tests with temporary library fixtures. |

See [Architecture](docs/development/architecture.md) for the repository layout
and how the frontend, desktop shell, and Rust crates fit together.

## Start here

For a first look at the interface, use the browser with a mock library:

```sh
pnpm install
pnpm dev:web
```

This requires Node 24 and pnpm 10.17.1. It does not open an installed rekordbox
library or require a Rust build. For desktop prerequisites and safe library
setup, read [Getting started](docs/development/getting-started.md).

## Developer reading path

Read these in order to understand the project and make your first change:

1. [Getting started](docs/development/getting-started.md): prerequisites, run modes, and library safety.
2. [Architecture](docs/development/architecture.md): repository map, crate responsibilities, IPC, and edit flow.
3. [Development conventions](docs/development/conventions.md): code style, performance, translation, and evidence rules.
4. [Testing](docs/development/testing.md): checks, test setup, and what each result proves.
5. [Contributing](CONTRIBUTING.md): issues, branches, implementation, validation, and review.
6. [Debugging](docs/development/debugging.md): logs, diagnostics, environment variables, and cleanup.
7. [Releases](docs/development/releases.md): versions, CI, packaging, and publication.

The [documentation index](docs/README.md) also links to user guides and detailed
analysis, USB-format, and hardware references.

## Common commands

| Command | Purpose |
| --- | --- |
| `pnpm dev:web` | Browser UI with the mock backend. |
| `pnpm dev` | Desktop app; can open your installed library. Read the safety guide first. |
| `pnpm lint` | Frontend lint rules. |
| `pnpm build` | TypeScript check and production frontend bundle. |
| `pnpm test` | Vitest tests. |
| `pnpm e2e` | Playwright browser tests against the mock backend. |
| `RB_LITE_TEST=1 cargo test --workspace` | Rust tests with installed-library writes refused. |

## License and trademarks

rbxport is GPL-2.0-or-later. See [LICENSE](LICENSE) and
[Licensing](LICENSING.md) for bundled components and distribution terms.
Third-party product names belong to their respective owners. rbxport is an
independent project and is not affiliated with, endorsed by, or sponsored by
their owners.

## Disclaimer

rbxport is provided "as is", without warranty to the extent permitted by
applicable law. Use it at your own risk and keep backups of your music library
and USB drives. Unless required by
applicable law or agreed to in writing, the authors and contributors are not
liable for damages arising from using or being unable to use rbxport,
including lost or corrupted data, equipment damage, or financial losses.
See [LICENSE](LICENSE) for the full warranty and liability terms.

rbxport is an independent project and is not affiliated with, endorsed by,
or sponsored by AlphaTheta or Pioneer DJ. References to rekordbox,
PRO DJ LINK, and other products describe compatibility only. All trademarks
and product names belong to their respective owners.

## Special thanks

evanpurkhiser, Maddix, Morgan Page, nichi, profbx, Sean Tyas, shiz, syl, trancejesus, xorbxbx, and
AlphaTheta.
