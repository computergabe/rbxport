param(
    [string]$ExtractorPath = (Join-Path $PSScriptRoot 'Bandcamp-Rekordbox.ps1'),
    [string]$CollectionRoot = (Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Rekordbox Collection'),
    [string]$Inbox = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\Bandcamp'),
    [string]$RbxportExecutable = (Join-Path $PSScriptRoot 'RBXPORT-Bandcamp\rbxport.exe'),
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Bandcamp → Rekordbox'
$queuePath = Join-Path $PSScriptRoot 'Bandcamp-Rekordbox.pending.json'
$log = Join-Path $CollectionRoot 'Bandcamp-Import.log'
$reports = Join-Path $PSScriptRoot 'RBXPORT-Bandcamp\reports'
$mutex = New-Object System.Threading.Mutex($false, 'Local\BandcampRekordboxDesktopLauncher')
$acquired = $false
$failed = $false
try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'An import is already running. Please finish that window first.' }
    Import-Module (Join-Path $PSScriptRoot 'Bandcamp-Rekordbox-Queue.psm1') -Force -DisableNameChecking
    Clear-Host
    Write-Host ''
    Write-Host '  BANDCAMP  →  REKORDBOX' -ForegroundColor Cyan
    Write-Host '  Your next set starts here.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  Inbox: $Inbox"
    Write-Host "  Music: $CollectionRoot"
    Write-Host '  Close rekordbox and other RBXPORT windows before library import.' -ForegroundColor DarkGray
    Write-Host ''
    if (-not (Test-Path -LiteralPath $ExtractorPath -PathType Leaf)) { throw "Extraction script is missing: $ExtractorPath" }
    # Recover older successful Bandcamp extractions on the first upgraded run.
    if (-not (Test-Path -LiteralPath $queuePath)) {
        $seed = @()
        if (Test-Path -LiteralPath $log) {
            foreach ($line in Get-Content -LiteralPath $log) {
                if ($line -match '\] Music stored at: (.+)$') {
                    $oldAlbum = $Matches[1]
                    if (Test-Path -LiteralPath $oldAlbum -PathType Container) {
                        $seed += Assert-CollectionAlbum -Album $oldAlbum -CollectionRoot $CollectionRoot
                    }
                }
            }
        }
        Save-PendingAlbums -QueuePath $queuePath -Albums @($seed | Select-Object -Unique)
    }
    $previousLines = 0
    if (Test-Path -LiteralPath $log) { $previousLines = @(Get-Content -LiteralPath $log).Count }
    # The callback persists the verified album before the extractor deletes its ZIP.
    # Run once: never pass -Watch.
    & $ExtractorPath -SourceFolder $Inbox -DestinationFolder $CollectionRoot -OnVerifiedAlbum {
        param($album)
        Add-PendingAlbum -QueuePath $queuePath -Album $album -CollectionRoot $CollectionRoot
    } -ErrorAction Stop
    $newLines = @()
    if (Test-Path -LiteralPath $log) { $newLines = @(Get-Content -LiteralPath $log | Select-Object -Skip $previousLines) }
    $extracted = @($newLines | Where-Object { $_ -match 'SUCCESS - ZIP deleted:' }).Count
    $extractionErrors = @($newLines | Where-Object { $_ -match 'ERROR processing|VERIFY FAILED' }).Count
    $zipSkipped = @($newLines | Where-Object { $_ -match 'SKIPPED -' }).Count
    $pending = @(Get-PendingAlbums -QueuePath $queuePath)
    $tracksImported = 0
    $alreadyPresent = 0
    foreach ($album in $pending) {
        Write-Host ''
        Write-Host "  Adding to library: $([System.IO.Path]::GetFileName($album))" -ForegroundColor Cyan
        try {
            $report = Invoke-PendingAlbumImport -Executable $RbxportExecutable -Album $album -CollectionRoot $CollectionRoot -ReportDirectory $reports
            $tracksImported += [int]$report.imported
            $alreadyPresent += @($report.existing).Count
            Remove-PendingAlbum -QueuePath $queuePath -Album $album
        } catch {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
            $failed = $true
            # A global refusal (protection/process lock) needs attention once.
            break
        }
    }
    $left = @(Get-PendingAlbums -QueuePath $queuePath).Count
    $zips = @(Get-ChildItem -LiteralPath $Inbox -Filter '*.zip' -File -ErrorAction Stop).Count
    Write-Host ''
    if ($left -gt 0 -or $extractionErrors -gt 0 -or $zips -gt 0) {
        Write-Host '  FINISHED — SOME ITEMS NEED ATTENTION' -ForegroundColor Yellow
        $failed = $true
    } elseif ($tracksImported -gt 0) {
        Write-Host '  MUSIC ADDED TO YOUR REKORDBOX LIBRARY' -ForegroundColor Green
    } else {
        Write-Host '  FINISHED — LIBRARY UP TO DATE' -ForegroundColor Green
    }
    Write-Host "  Albums extracted: $extracted   ZIPs skipped: $zipSkipped   Extraction errors: $extractionErrors"
    Write-Host "  Tracks added: $tracksImported   Already in library: $alreadyPresent"
    Write-Host "  Albums awaiting library import: $left   ZIPs remaining: $zips"
    if ($left -gt 0) { Write-Host '  Resolve the message above, then click this button again to retry.' -ForegroundColor Yellow }
    Write-Host "  Extraction log: $log" -ForegroundColor DarkGray
    Write-Host "  Library reports: $reports" -ForegroundColor DarkGray
} catch {
    $failed = $true
    Write-Host ''
    Write-Host '  IMPORT NEEDS ATTENTION' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Write-Host ''
    if (-not $NoPause) { Read-Host '  Press Enter to close' | Out-Null }
}
if ($failed) { exit 1 }
