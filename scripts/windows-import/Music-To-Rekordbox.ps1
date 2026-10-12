param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Music-Import.config.json'),
    [string]$Executable = (Join-Path $PSScriptRoot 'RBXPORT-Music\rbxport.exe'),
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Music to Rekordbox'
$mutex = New-Object System.Threading.Mutex($false,'Local\RBXPORTUniversalMusicInbox')
$acquired = $false; $failed = $false
$queue = Join-Path $PSScriptRoot 'Music-Import.pending.json'
$reports = Join-Path $PSScriptRoot 'reports'
$log = Join-Path $PSScriptRoot 'Music-Import.log'
function Log([string]$Message) {
    Write-Host $Message
    Add-Content -LiteralPath $log -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message) -Encoding UTF8
}
try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Another Music to Rekordbox run is active.' }
    Import-Module (Join-Path $PSScriptRoot 'Music-Import.Core.psm1') -Force -DisableNameChecking
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if ($NoPause) { throw 'Run Setup-Music-Import.ps1 first.' }
        & (Join-Path $PSScriptRoot 'Setup-Music-Import.ps1') -ConfigPath $ConfigPath
    }
    $config = Read-MusicSettings $ConfigPath
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'The universal RBXPORT app is missing.' }
    if ($config.importToRekordbox -and (Get-Process | Where-Object { $_.ProcessName -match '^(rekordbox|rekordboxagent|rbxport)$' })) {
        throw 'Close rekordbox, its tray agent, and other RBXPORT instances before moving or importing music.'
    }
    New-Item -ItemType Directory -Path $reports -Force | Out-Null
    if (-not (Test-Path -LiteralPath $queue)) { Write-MusicJson $queue @{version=1;files=@()} }
    $pending = @(Get-MusicPending $queue)
    foreach ($path in $pending) { Assert-MusicPath $path $config.musicRoot | Out-Null }
    Clear-Host
    Write-Host ''
    Write-Host '  MUSIC  ->  REKORDBOX' -ForegroundColor Cyan
    Log ('  WHERE SONGS LIVE: ' + $config.musicRoot)
    Log ('  Layout: ' + $config.layout + '   Originals: ' + $config.originals)
    $sources = @(Get-MusicSources $config $PSScriptRoot)
    $prepared = 0; $sourceErrors = 0
    foreach ($source in $sources) {
        Log ('  Preparing: ' + $source.path)
        try {
            $result = Save-MusicSource $source $config $Executable $PSScriptRoot $queue $reports
            $prepared += $result.tracks
            Log ('  Verified ' + $result.tracks + ' track(s); original policy: ' + $result.originals)
        } catch { $sourceErrors++; $failed=$true; Log ('  Source needs attention: ' + $_.Exception.Message) }
    }
    $added = 0; $existing = 0
    if ($config.importToRekordbox) {
        $pending = @(Get-MusicPending $queue)
        while ($pending.Count -gt 0) {
            $batch = @(); $length = 0
            foreach ($path in $pending) {
                if ($batch.Count -gt 0 -and $length + $path.Length + 15 -gt 20000) { break }
                $batch += $path; $length += $path.Length + 15
            }
            try {
                Log ('  Registering ' + $batch.Count + ' track(s) in the current rekordbox library...')
                $report = Invoke-MusicLibraryImport $Executable $batch $config.musicRoot $reports
                $added += [int]$report.imported; $existing += @($report.existing).Count
                $pending = @($pending | Where-Object { $batch -notcontains $_ })
                Write-MusicJson $queue @{version=1;files=@($pending)}
            } catch { $failed=$true; Log ('  Library import needs attention: ' + $_.Exception.Message); break }
        }
    }
    $left = @(Get-MusicPending $queue).Count
    Write-Host ''
    if ($failed) { Write-Host '  FINISHED - SOME ITEMS NEED ATTENTION' -ForegroundColor Yellow }
    elseif (-not $config.importToRekordbox) { Write-Host '  MUSIC ORGANIZED - LIBRARY IMPORT DISABLED' -ForegroundColor Green }
    else { Write-Host '  FINISHED - MUSIC IS READY IN REKORDBOX' -ForegroundColor Green }
    Log ("  Tracks prepared: $prepared   Source errors: $sourceErrors")
    Log ("  Library tracks added: $added   Already registered: $existing   Queued: $left")
    Log ('  Reports: ' + $reports)
    if ($left -gt 0) { Write-Host '  Music is safely stored. Enable import or resolve the message above, then run again.' -ForegroundColor Yellow }
} catch { $failed=$true; Write-Host $_.Exception.Message -ForegroundColor Yellow }
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
}
if ($failed) { exit 1 }
exit 0
