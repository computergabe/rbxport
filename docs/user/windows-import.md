# One-shot Windows import

This fork adds an import entry point to the custom-built application. The
standard installed RBXPORT 1.1.0 does not support these arguments.

Close rekordbox and any other RBXPORT windows. In this build's Preferences,
turn off Library Protection only when you intend to allow library edits.
The command respects that setting; it does not disable protection itself.

```powershell
$result = Join-Path $env:TEMP ('rbxport-import-' + [guid]::NewGuid() + '.json')
$process = Start-Process -FilePath 'C:\path\to\custom\rbxport.exe' -ArgumentList @(
    '--import', '"C:\Users\compu\Music\Rekordbox Collection\An Album"',
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

Development checks must use disposable fixture libraries with
`RBXPORT_TEST=1`; never use the installed library as a test target. This feature
needs native Windows validation before it is connected to a production launcher.
