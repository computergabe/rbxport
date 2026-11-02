param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Music-Import.config.json'),
    [string]$Executable = (Join-Path $PSScriptRoot 'RBXPORT-Music\rbxport.exe'),
    # Import from this folder or file once instead of the saved inboxes.
    [string]$Source,
    [switch]$PickFolder,
    # Find tracks whose file is gone and relocate them, instead of importing.
    [switch]$CheckMissing,
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
    if (-not $Source -and -not $PickFolder -and -not $CheckMissing -and -not $NoPause) {
        Write-Host ''
        Write-Host '  MUSIC  ->  REKORDBOX' -ForegroundColor Cyan
        Write-Host ('  Saved inbox: ' + (@($config.sources) -join ', '))
        Write-Host ''
        Write-Host '  [Enter]  Import from the saved inbox'
        Write-Host '  [F]      Pick a folder to import this time'
        Write-Host '  [M]      Find and fix missing files'
        Write-Host '  [S]      Change settings (inbox, music library folder, layout)'
        $choice = ([string](Read-Host '  Choose')).Trim()
        if ($choice -match '^f') { $PickFolder = $true }
        elseif ($choice -match '^m') { $CheckMissing = $true }
        elseif ($choice -match '^s') {
            & (Join-Path $PSScriptRoot 'Setup-Music-Import.ps1') -ConfigPath $ConfigPath -NoShortcut
            $config = Read-MusicSettings $ConfigPath
        }
    }
    if ($PickFolder) {
        $Source = Select-MusicFolder 'Choose a folder with ZIP or audio files to import into rekordbox.' (@($config.sources)[0])
        if (-not $Source) { throw 'No folder chosen. Nothing was imported.' }
    }
    if ($Source) {
        if (-not [System.IO.Path]::IsPathRooted($Source) -or -not (Test-Path -LiteralPath $Source)) { throw "Source is unavailable: $Source" }
        $Source = [System.IO.Path]::GetFullPath($Source)
        if (($Source.TrimEnd('\') + '\').StartsWith(($config.musicRoot.TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Pick a folder outside your music library folder.' }
        $config.sources = @($Source)
    }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'The universal RBXPORT app is missing.' }
    if ($CheckMissing) {
        New-Item -ItemType Directory -Path $reports -Force | Out-Null
        $folders = @($config.musicRoot) + @(@($config.sources) | ForEach-Object { if (Test-Path -LiteralPath $_ -PathType Leaf) { Split-Path -Parent $_ } else { $_ } })
        $open = [bool](Get-Process | Where-Object { $_.ProcessName -match '^(rekordbox|rekordboxagent|rbxport)$' })
        Write-Host ''
        Write-Host '  MISSING FILES' -ForegroundColor Cyan
        Log ('  Searching: ' + ($folders -join ', '))
        if ($open) { Log '  rekordbox or RBXPORT is open, so this lists missing files without relocating them.' }
        $result = Find-MusicMissing $Executable $folders $reports -Relocate:(-not $open)
        foreach ($track in @($result.tracks)) {
            if ($track.PSObject.Properties['relocatedTo']) { Log ('  Relocated: ' + $track.title + ' -> ' + $track.relocatedTo) }
            elseif ($track.PSObject.Properties['error']) { $failed = $true; Log ('  Could not relocate ' + $track.title + ': ' + $track.error) }
            elseif (@($track.candidates).Count -gt 1) { Log ('  Several files could be ' + $track.title + ': ' + (@($track.candidates) -join ' | ')) }
            elseif (@($track.candidates).Count -eq 1) { Log ('  Found ' + $track.title + ' at ' + @($track.candidates)[0] + ' (close rekordbox to relocate)') }
            else { Log ('  Not found: ' + $track.title + ' (' + $track.path + ')') }
        }
        $left = [int]$result.missing - [int]$result.relocated
        Write-Host ''
        if ([int]$result.missing -eq 0) { Write-Host '  NO MISSING FILES' -ForegroundColor Green }
        elseif ($left -eq 0) { Write-Host '  ALL MISSING FILES RELOCATED' -ForegroundColor Green }
        else { Write-Host '  SOME FILES ARE STILL MISSING' -ForegroundColor Yellow }
        Log ("  Missing: $($result.missing)   Relocated: $($result.relocated)   Still missing: $left")
        if ($left -gt 0) { $failed = $true }
        # Exit here, past the import below; finally still releases the lock.
        exit [int]$failed
    }
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
    Log ('  Music library folder: ' + $config.musicRoot)
    Log ('  Layout: ' + $config.layout + '   Originals: ' + $config.originals)
    $sources = @(Get-MusicSources $config $PSScriptRoot)
    $prepared = 0; $sourceErrors = 0
    foreach ($inboxItem in $sources) {
        Log ('  Preparing: ' + $inboxItem.path)
        try {
            $result = Save-MusicSource $inboxItem $config $Executable $PSScriptRoot $queue $reports
            $prepared += $result.tracks
            Log ('  Verified ' + $result.tracks + ' track(s); original policy: ' + $result.originals)
        } catch { $sourceErrors++; $failed=$true; Log ('  Source needs attention: ' + $_.Exception.Message) }
    }
    $added = 0; $existing = 0; $analysed = 0; $unanalysed = 0
    if ($config.importToRekordbox) {
        $pending = @(Get-MusicPending $queue)
        while ($pending.Count -gt 0) {
            $batch = @(); $length = 0
            foreach ($path in $pending) {
                if ($batch.Count -gt 0 -and $length + $path.Length + 15 -gt 20000) { break }
                $batch += $path; $length += $path.Length + 15
            }
            try {
                if ($config.analyze) { Log ('  Registering and analyzing ' + $batch.Count + ' track(s) in the current rekordbox library. Analysis takes a few seconds per track...') }
                else { Log ('  Registering ' + $batch.Count + ' track(s) in the current rekordbox library...') }
                $report = Invoke-MusicLibraryImport $Executable $batch $config.musicRoot $reports -Analyze:$config.analyze -BpmRange $config.bpmRange
                $added += [int]$report.imported; $existing += @($report.existing).Count
                foreach ($item in @($report.analysis)) {
                    if ($item.ok) { $analysed++ } else { $unanalysed++; Log ('  Not analyzed: ' + $item.title + ' - ' + $item.error) }
                }
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
    if ($config.importToRekordbox -and $config.analyze) { Log ("  Tracks analyzed (RBXport Electronic Music): $analysed   Not analyzed: $unanalysed") }
    if ($unanalysed -gt 0) { Write-Host '  Unanalyzed tracks are in rekordbox; analyze them there or in RBXPORT.' -ForegroundColor Yellow }
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
