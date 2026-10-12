<p align="center">
  <a href="https://github.com/computergabe/rbxport">
    <img src="docs/assets/brand/combined/rbxport-logo-color-white.png" alt="rbxport" width="360">
  </a>
</p>

# rbxport — Music to Rekordbox for Windows

This public community fork of [chrisle/rbxport](https://github.com/chrisle/rbxport)
adds **on-demand music automation**. Choose your inbox folders and permanent
music folder, organize ZIPs and individual audio files, and register their
tracks in the active rekordbox library with a desktop button.
This is an independent Windows release, not an official upstream release.

## Download and set up

[Download the Windows x64 music release](https://github.com/computergabe/rbxport/releases/tag/windows-music-1.2.0)
or [read the setup and PowerShell guide](docs/user/windows-import.md).

1. Extract the package to a permanent writable folder.
2. Open the included RBXPORT app once. Disable Library Protection when you
   intend to allow imports, and disable automatic update checking to retain
   this custom build. Close the app.
3. Open PowerShell in the extracted folder and run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Music-Import.ps1
   ```

4. Choose your source folders or individual files, **WHERE SONGS LIVE** storage
   folder, layout, Copy or Move policy, and library-import preference.
5. Close rekordbox and its tray agent, then click **Music → Rekordbox**.
   Reopen rekordbox after it finishes.

The setup creates the button and saves your preferences for later clicks.
Downloads need no compiler tools. The release includes scripts, the app, an
icon, licenses, checksums, and corresponding source.

## Use your own music system

Select multiple inboxes, include subfolders if desired, and choose music
storage on an available local/external drive or accessible network share.
The storage folder can have any name; “WHERE SONGS LIVE” is the setup label.

- **Artist/Album/Filename:** reads embedded tags; prefers Album Artist with
  Track Artist fallback. Missing tags use Unknown Artist/Unknown Album.
- **Preserve folders:** keeps ZIP structure and loose files' relative paths.
- **Flat:** puts audio directly in the chosen storage folder.

Copy keeps original downloads and is the default. Move removes originals
only after verified storage and a durable retry queue. ZIP extras such as
artwork are preserved separately. Different files with the same destination
name receive a content-hash suffix; existing audio is not overwritten.
Recognized formats and file-handling details are in the guide.

The button runs once per click. It verifies extraction and SHA-256 copies,
then imports queued audio paths. Failed imports stay queued, and retries skip
paths already in the library. It honors Library Protection.

Music storage and the rekordbox database may be on different drives. The app
uses rekordbox's configured library location; choose the intended library in
rekordbox before closing it. **No rekordbox.xml is needed for this workflow.**
This is for new downloads; it does not relocate tracks already in a collection.
Existing working launchers and music are not automatically migrated.

## PowerShell and building from source

The app supports repeated `--import <path>` arguments with
`--import-report <new.json>`, and read-only audio metadata inspection with
`--inspect-list <paths.json> --inspect-report <new.json>`.

See the [PowerShell guide](docs/user/windows-import.md) for examples, reports,
recovery, Windows prerequisites, Tauri builds, and packaging instructions.
Use this fork's default branch or the `windows-music-1.2.0` release tag.

The full Windows workspace suite and Clippy checks pass locally, along with
frontend lint, unit, build, bundle-budget, Chromium UI, and disposable
PowerShell file-handling checks. Regression tests cover Windows folders,
short paths, junctions, drive letters, and file locking. GitHub hosts the
finished source and release; hosted builds are optional manual workflows.
Direct library import was verified on rekordbox 7.2.19. This is not a claim of
compatibility with every version or drive arrangement. Keep a library backup
before use.

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
