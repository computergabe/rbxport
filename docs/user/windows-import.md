# One-shot Windows import

## Download and set up the desktop button

Get the ZIP from the [Windows preview release](https://github.com/computergabe/rbxport/releases/tag/windows-import-preview.1).
This independent fork's package is for Windows x64 with Windows PowerShell 5.1
and the WebView2 runtime. The packaged app is unsigned. Building tools are
needed only when compiling from source, not when using the download.

Extract the entire ZIP into a permanent, writable folder such as
`C:\Users\YourName\Apps\RBXPORT-Bandcamp`. Do not run scripts inside the ZIP or
split its files between folders. Read `START-HERE.txt` and back up your library.

Open `RBXPORT-Bandcamp\rbxport.exe` once. In Preferences, turn off Library
Protection when you intend to allow edits and turn off automatic update
checking to retain this custom build. Close the app. The launcher honors the
protection setting and never disables it on your behalf.

Open PowerShell in the extracted folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Create-Desktop-Shortcut.ps1
```

This creates **Bandcamp → Rekordbox** on your actual Windows desktop, including
a redirected OneDrive desktop. It refuses to replace an existing shortcut.
Keep the package in this location; moving it requires recreating the shortcut.

For folders on another drive:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Create-Desktop-Shortcut.ps1 -Inbox "D:\Downloads\Bandcamp" -CollectionRoot "D:\Music\Rekordbox Collection"
```

Use full paths without a trailing backslash. The bundled extractor and launcher
use these same folders. Default folders are your user profile's
`Downloads\Bandcamp` and your actual Windows Music folder's
`Rekordbox Collection` subfolder.

Each time: put ZIPs in the inbox, close rekordbox and its tray agent plus other
RBXPORT instances, and click the button. Read the result, press Enter to close,
then reopen rekordbox. Its normal settings may start analysis automatically.
The button itself imports once and does not request analysis or watch folders.

## Native command for PowerShell scripts

This fork adds an import entry point to the custom-built application. The
standard installed RBXPORT 1.1.0 does not support these arguments.

Close rekordbox and any other RBXPORT windows. In this build's Preferences,
turn off Library Protection only when you intend to allow library edits.
The command respects that setting; it does not disable protection itself.

```powershell
$result = Join-Path $env:TEMP ('rbxport-import-' + [guid]::NewGuid() + '.json')
$process = Start-Process -FilePath 'C:\path\to\custom\rbxport.exe' -ArgumentList @(
    '--import', '"D:\Music\An Album"',
    '--import-report', ('"' + $result + '"')
) -WindowStyle Hidden -Wait -PassThru
if (-not (Test-Path -LiteralPath $result)) { throw 'RBXPORT did not produce a result.' }
$summary = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
if ($process.ExitCode -ne 0 -or -not $summary.ok) {
    $summary | ConvertTo-Json -Depth 8
    throw 'Import needs attention. Some tracks may already have imported; retrying skips existing paths.'
}
$summary.report
```

Repeat `--import <path>` for multiple album folders or individual audio files.
The report path must be new, with an existing parent folder. Existing reports
are never overwritten. Reports contain `ok` and either `report` (imported,
existing and skipped tracks) or `error`. A nonzero exit code means incomplete
import, refusal, or an error; an absent/empty report is also a failure.

The application waits up to two minutes for startup, imports once using its
existing import routine, writes the report, and exits. It does not watch
folders, delete audio, analyse tracks, or change ZIP extraction behavior.
Imports can partially succeed before an error. Retrying uses existing-path
detection, so retain the album paths until a successful result is recorded.

An interrupted process can leave `automation-import.lock` in RBXPORT's app
cache directory. Close every RBXPORT process before removing that marker to
retry. The command deliberately does not guess whether a leftover lock is safe
to remove.

Development checks must use disposable fixture libraries with
`RBXPORT_TEST=1`; never use the installed library as a test target. Focused
Windows tests and a real import into rekordbox 7.2.19 passed. The README records
the broader Windows test limitations. The Windows scripting interface currently
exposes import; macOS has a separate [AppleScript interface](applescript.md).

## Bandcamp desktop launcher

The Windows PowerShell extractor, launcher, and queue module are in
`scripts/windows-import/` and are supplied together in the download.
Place this fork's executable at
`RBXPORT-Bandcamp/rbxport.exe` beneath that same directory. The desktop shortcut
runs the launcher with `-NoProfile -ExecutionPolicy Bypass` and no `-Watch`.

The bundled extractor accepts `-SourceFolder`, `-DestinationFolder`, and an
optional `[scriptblock]$OnVerifiedAlbum` parameter. A replacement extractor must
accept those same folder parameters and call
`& $OnVerifiedAlbum $FinalFolder` (when provided) after successful final
verification and before deleting the ZIP. If the callback
fails, the extractor's catch must retain the ZIP. Keep the original script and
launcher backed up before making these changes.

The callback saves the album to `Bandcamp-Rekordbox.pending.json`. Albums leave
that queue only after a successful JSON report and exit code. A refused,
partial, missing, or malformed report retains the album for the next click;
retrying skips tracks already present in the library. The first upgraded run
also queues still-existing folders from previous successful extraction log
entries. Extraction and library-import counts are displayed separately.

Close rekordbox (including its tray agent) and other RBXPORT windows before
clicking the button. Library Protection must permit edits in this custom build's
Preferences; the launcher never disables it. Tracks are registered in the
collection without automatic beat-grid or key analysis. Open rekordbox after
the button finishes to use its normal analysis workflow.

The queue is replaced atomically with its previous version retained in
`Bandcamp-Rekordbox.pending.json.previous`. Per-album reports are kept under
`RBXPORT-Bandcamp/reports`. Neither the queue nor the library import deletes
music files or starts a persistent folder watcher.

The public extractor also rejects unsafe and duplicate ZIP paths before
extraction. Failed staging data remains under `_staging` for inspection along
with the original ZIP. Verification checks file presence and sizes; it is not
a cryptographic comparison of every file's contents.

## Local Windows builds

Use Visual Studio Developer PowerShell with the C++ tools, Windows SDK,
Rust MSVC toolchain, Strawberry Perl, Node, and the pinned pnpm 10.17.1.
Use a short Cargo output path; long checkout paths can exceed MSVC's file
path limit while compiling vendored OpenSSL.

```powershell
$env:CARGO_TARGET_DIR = Join-Path $env:LOCALAPPDATA 'RBXPORT-Build\target'
$env:OPENSSL_SRC_PERL = 'C:\Strawberry\perl\bin\perl.exe'
$env:Path = 'C:\Strawberry\perl\bin;' + $env:Path
$env:RBXPORT_TEST = '1'
pnpm install --frozen-lockfile
pnpm tauri build --no-bundle --ci
```

The executable is under `$env:CARGO_TARGET_DIR\release\rbxport.exe`.
Use the Tauri builder: a plain Cargo release build does not enable the
packaged frontend. Fixture checks must stay isolated from installed libraries.

## Package a build for other people

From the source checkout, supply the executable and the exact commit it was
built from. Choose a new output folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-import\Build-Package.ps1 -Executable "$env:CARGO_TARGET_DIR\release\rbxport.exe" -BinarySourceCommit (git rev-parse HEAD) -OutputDirectory "$env:TEMP\rbxport-windows-package"
```

The ZIP contains the desktop scripts, icon, app, guide, license text, and
`BUILD-INFO.json` with the executable hash and source commits. Publish its
corresponding source and ZIP checksum alongside the download. This fork's
GitHub preview releases are separate from the upstream deployment workflow;
use [Releases](https://github.com/computergabe/rbxport/releases) for downloads.
