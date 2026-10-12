# Music to Rekordbox: Windows setup and PowerShell automation

This independent community fork organizes downloaded music and registers it
in the active rekordbox library. It runs once per desktop click. There is no
background watcher.

## Download and first setup

Download the [Windows music release](https://github.com/computergabe/rbxport/releases/tag/windows-music-1.2.0).
The unsigned package needs Windows x64, Windows PowerShell 5.1, and WebView2.
Build tools are only needed to compile from source.

1. Extract the complete package to a permanent writable folder, for example
   `C:\Users\YourName\Apps\RBXPORT-Music`. Keep its files together.
2. Open `RBXPORT-Music\rbxport.exe` once. In Preferences, disable Library
   Protection when you want to permit imports, and disable automatic update
   checking to retain this custom build. Close RBXPORT afterward.
3. Open PowerShell in the extracted folder and run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Music-Import.ps1
   ```

4. Answer the setup prompts, review the settings, and save them. Setup creates
   **Music → Rekordbox** on your actual desktop, including a redirected desktop.
5. Finish downloading your music, close rekordbox and its tray agent plus other
   RBXPORT instances, and click the button. Read its result, press Enter to
   close, and reopen rekordbox.

The setup asks for:

| Choice | What it controls |
| --- | --- |
| Sources | One or more full inbox folder paths, or individual ZIP/audio file paths. Downloads, custom folders, external drives, and accessible network shares can be selected. |
| WHERE SONGS LIVE | Your permanent music storage folder. This label describes any folder you choose; it does not require that literal folder name. |
| Subfolders | Whether to scan nested inbox folders. The default is no. |
| Layout | Artist/Album/Filename, preserve source folders, or put files directly in the storage root. |
| Originals | Copy keeps downloads (default). Move removes a ZIP or standalone audio file only after verification and queue persistence. |
| Artist folders | Prefer Album Artist with Track Artist fallback (default), or always use Track Artist. |
| Library import | Register the organized files in rekordbox, or organize only and retain them in the pending queue. |

Sources must be outside the permanent storage folder. Use finished downloads.
Unsupported standalone file extensions are left alone. The recognized audio
extensions are MP3, M4A, AAC, FLAC, WAV, AIFF/AIF, OGG, and OPUS; successful
metadata reading and playback support still depend on the file and rekordbox
version. A ZIP with no recognized audio is retained.

Run setup again to change preferences. Settings are saved in
`Music-Import.config.json`; the previous version is retained. Setup refuses a
storage-root change while pending files point outside the new root. Finish the
queue before changing storage. An existing desktop shortcut is kept; rename
it first when replacing a button after moving the package.

For scripted setup without prompts:

```powershell
.\Setup-Music-Import.ps1 -NonInteractive -Sources @('D:\Music Inbox','E:\Downloads') -MusicRoot 'F:\My Music' -Originals Move -Layout ArtistAlbum -Recursive
```

Use `-OrganizeOnly` to skip library imports and `-NoShortcut` to omit a button.

## Organization and verification

Artist/Album layout reads embedded tags, rather than guessing from filenames.
For example, a tagged track becomes:

```text
F:\My Music\Artist Name\Album Name\original filename.flac
```

Missing tags use `Unknown Artist\Unknown Album`. Windows-invalid characters
are sanitized in artist/album folder names. Album Artist keeps compilations
together when that tag exists. The audio filename is preserved.

PreserveFolders keeps each ZIP's internal folder structure. Loose audio keeps
its path relative to the chosen source folder. Flat keeps only filenames.
Identical content at an intended destination is reused. Different content
with the same name receives a short content-hash suffix; it does not replace
the existing file.

ZIPs are extracted into staging first. Unsafe, duplicate, or invalid Windows
entry paths are rejected. Every extracted file is checked for presence and
size. Each copied file is compared using SHA-256, checked again in its final
location, and audio paths are durably queued before source removal. The
original source is checked for changes during processing.

ZIP artwork, text, and other non-audio files are preserved under
`_archive-extras/<ZIP-name>-<hash>/` inside music storage. They are not imported
as tracks. Failed ZIPs and failed staging are kept for inspection. After
successful handling, only that run's known staging files and empty directories
are removed.

Copy mode checks retained downloads again on later clicks; destination reuse
and existing library-path detection make retries safe. In Move mode,
consumed individually selected files are skipped on subsequent runs while
their parent folder remains available. New downloads require a source folder
or another setup run. Missing source folders and unavailable storage drives
stop a run before processing.

This is an inbox workflow for new downloads. Moving music already registered
in a library can break its existing paths; this tool does not migrate a
collection or rewrite the old paths. Existing users can keep their previous
working launcher and music locations. Installing this package does not change
those files.

## Where is my rekordbox library? Do I need rekordbox.xml?

Music storage and the library database are different things. Music can live
on one drive and the rekordbox database on another.

The native import command uses the library configured by rekordbox. It reads
`masterDbDirectory` from rekordbox's settings, then the agent's recorded
`db-path` when no settings location is present, then the default location.
An explicitly configured missing database is an error; it does not silently
import into a different database.

Open rekordbox with the library you intend to use first, then close it and its
tray agent before clicking the button. Keep an external library drive
connected. Setup does not edit rekordbox's database-location settings or ask
you to select an arbitrary encrypted database file.

**This workflow does not require rekordbox.xml.** It registers files directly
in the detected library through RBXPORT's import routine. Generating XML and
manually importing it would be a separate workflow; this launcher does not
generate or import XML.

Imported tracks appear in the Collection. The button does not request beat,
key, or grid analysis; rekordbox can use its normal analysis settings after
reopening. Native direct import was verified on rekordbox 7.2.19; other
versions and storage arrangements have not all been verified.

## Feedback, retries, and recovery

The window shows tracks prepared, source errors, library tracks added,
already registered tracks, and pending tracks. Problems return exit status 1;
complete runs return 0. Organize-only mode intentionally leaves files queued.

`Music-Import.pending.json` stores individual final audio paths. It is replaced
atomically, retaining `.previous`. A batch leaves the queue only after a
successful exit and a complete JSON import report. A partial, refused, missing,
or inconsistent report retains the batch. Retry skips paths already registered
in the library.

Read `Music-Import.log` and `reports/` for details. Resolve an error, then click
again. Verified final audio remains in music storage if library import fails,
including when Move mode already removed a verified download. The launcher
honors Library Protection and never disables it for you.

An interrupted native import can leave
`%LOCALAPPDATA%\com.rbxport.app\automation-import.lock`. Close all RBXPORT
processes before manually removing this marker. If a closed window has left a
background process, use Task Manager to end that RBXPORT process before retrying.
Do not clear the pending queue to resolve an import error.

## Native PowerShell import command

The custom app accepts repeated `--import <path>` arguments for folders or
individual files and a new JSON report path. The report's parent must exist.
The standard upstream app does not provide this fork's scripting arguments.

```powershell
$report = Join-Path $env:TEMP ('rbxport-' + [guid]::NewGuid() + '.json')
$arguments = '--import "F:\My Music\Artist\Album" --import-report "' + $report + '"'
$process = Start-Process -FilePath .\RBXPORT-Music\rbxport.exe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
if (-not (Test-Path -LiteralPath $report)) { throw 'No import report was produced.' }
$result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
if ($process.ExitCode -ne 0 -or -not $result.ok) { throw ($result | ConvertTo-Json -Depth 8) }
$result.report
```

Reports contain `ok` plus `report` (imported, tracks, existing, skipped), or
`error`. Existing report files are never overwritten. A nonzero exit, missing
report, or unsuccessful report means failure; some tracks may already have
imported and can safely be retried. The app waits up to two minutes for startup.

It refuses imports while rekordbox, its tray agent, or another RBXPORT instance
is running. It respects Library Protection and takes an exclusive import lock.
It does not extract ZIPs, move audio, start a watcher, or request analysis.

## Read-only metadata command

The organizer uses a separate command that reads audio tags without opening
a library or starting the app interface:

```powershell
$list = Join-Path $env:TEMP ('audio-' + [guid]::NewGuid() + '.json')
$report = Join-Path $env:TEMP ('tags-' + [guid]::NewGuid() + '.json')
$json = ConvertTo-Json -InputObject @('F:\Music Inbox\track.flac')
[IO.File]::WriteAllText($list, $json, (New-Object Text.UTF8Encoding($false)))
$arguments = '--inspect-list "' + $list + '" --inspect-report "' + $report + '"'
$process = Start-Process -FilePath .\RBXPORT-Music\rbxport.exe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
Get-Content -LiteralPath $report -Raw -Encoding UTF8
```

Input is a UTF-8 JSON array of full paths, without a byte-order mark. Output has `ok`, `files`, and `errors`;
files include path, artist, albumArtist, album, title, and trackNumber.
Invalid input can instead return `ok:false,error`. A failed file gives a
nonzero exit. Reports must be new. This command can run while rekordbox is
open because it only reads audio files.

## Local Windows builds

Use Visual Studio Developer PowerShell with the C++ tools, Windows SDK, Rust
MSVC toolchain, Strawberry Perl, Node, and the pinned pnpm 10.17.1. Use a short
Cargo output path to avoid MSVC path limits while building vendored OpenSSL.

```powershell
$env:CARGO_TARGET_DIR = Join-Path $env:LOCALAPPDATA 'RBXPORT-Build\target'
$env:OPENSSL_SRC_PERL = 'C:\Strawberry\perl\bin\perl.exe'
$env:Path = 'C:\Strawberry\perl\bin;' + $env:Path
$env:LC_ALL = 'C'
$env:LANG = 'C'
$env:LC_CTYPE = 'C'
$env:RBXPORT_TEST = '1'
pnpm install --frozen-lockfile
```

Before publishing, run the full local checks below, stopping to fix any command
that fails. Python must be available as `python3` for the browser test server.
Chromium represents the Windows WebView2 frontend; these are mock-backed UI
tests, separate from the native database tests.

```powershell
pnpm lint
pnpm build
pnpm test
pnpm budget
pnpm exec playwright install chromium
pnpm exec playwright test --project=chromium
cargo clippy --workspace --all-targets --release --features tauri/custom-protocol -- -D warnings
cargo test --workspace --release --features tauri/custom-protocol --no-fail-fast
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-import\Test-Package.ps1 -FixtureRoot (Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')))
```

After those checks pass, build the downloadable app locally and exercise its
metadata command through the real organizer with disposable files:

```powershell
pnpm tauri build --no-bundle --ci
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-import\Test-Native-Organizer.ps1 -Executable "$env:CARGO_TARGET_DIR\release\rbxport.exe" -FixtureRoot (Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')))
```

The app is at `$env:CARGO_TARGET_DIR\release\rbxport.exe`. Use the Tauri
builder to include the frontend. Development checks must use disposable
fixtures with `RBXPORT_TEST=1`, never the installed library.

Focused native import and metadata tests, import integration tests, and
Windows Clippy checks pass, together with the full Windows workspace suite.
Windows folder/junction detection and platform-specific path fixtures have
regression coverage. This release does not guarantee compatibility with every
rekordbox version, device, or storage arrangement.

GitHub hosts the finished source and download. This fork's hosted Windows
build/test workflows run only when manually requested, not on each push.

## Package your build

Supply the executable and the exact commit it was built from. Choose a new
output directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-import\Build-Package.ps1 -Executable "$env:CARGO_TARGET_DIR\release\rbxport.exe" -BinarySourceCommit (git rev-parse HEAD) -OutputDirectory "$env:TEMP\rbxport-music-package"
```

The ZIP includes scripts, icon, app, guide, licenses, and `BUILD-INFO.json`
with hashes and source commits. Publish corresponding source and checksums
alongside it. This fork uses its own GitHub releases, not the upstream
deployment workflow.

Check the scripts with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-import\Test-Package.ps1 -FixtureRoot "$env:TEMP\rbxport-music-fixtures"
```

Choose a new fixture directory each run. Fixtures exercise the real scripts
with a mock native app; native command tests cover library writes separately.
