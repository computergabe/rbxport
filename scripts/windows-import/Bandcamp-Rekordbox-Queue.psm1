Set-StrictMode -Version Latest

function Get-PendingAlbums {
    param([string]$QueuePath)
    if (-not (Test-Path -LiteralPath $QueuePath)) { return }
    $data = Get-Content -LiteralPath $QueuePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($data.version -ne 1) { throw 'The pending-import queue has an unsupported format.' }
    foreach ($album in $data.albums) {
        if ($album -isnot [string] -or [string]::IsNullOrWhiteSpace($album)) { throw 'The pending-import queue contains an invalid album path.' }
        $album
    }
}

function Save-PendingAlbums {
    param([string]$QueuePath, [string[]]$Albums)
    $temporary = $QueuePath + '.' + [guid]::NewGuid().ToString() + '.tmp'
    try {
        $json = @{ version = 1; albums = @($Albums) } | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $QueuePath) {
            # Windows PowerShell 5 converts a null backup argument to an empty
            # path. A real backup path works there and retains the prior queue.
            [System.IO.File]::Replace($temporary, $QueuePath, ($QueuePath + '.previous'))
        } else {
            [System.IO.File]::Move($temporary, $QueuePath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-CollectionAlbum {
    param([string]$Album, [string]$CollectionRoot)
    $root = [System.IO.Path]::GetFullPath($CollectionRoot).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Album).TrimEnd('\')
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith(($root + '_staging\'), [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.Equals(($root + '_staging'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Album is outside the final music collection: $Album"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Album folder is missing: $Album" }
    $full
}

function Add-PendingAlbum {
    param([string]$QueuePath, [string]$Album, [string]$CollectionRoot)
    $full = Assert-CollectionAlbum -Album $Album -CollectionRoot $CollectionRoot
    $albums = @(Get-PendingAlbums -QueuePath $QueuePath)
    if ($albums -notcontains $full) { Save-PendingAlbums -QueuePath $QueuePath -Albums @($albums + $full) }
}

function Remove-PendingAlbum {
    param([string]$QueuePath, [string]$Album)
    $albums = @(Get-PendingAlbums -QueuePath $QueuePath | Where-Object { $_ -ne $Album })
    Save-PendingAlbums -QueuePath $QueuePath -Albums $albums
}

function Invoke-PendingAlbumImport {
    param([string]$Executable, [string]$Album, [string]$CollectionRoot, [string]$ReportDirectory)
    $full = Assert-CollectionAlbum -Album $Album -CollectionRoot $CollectionRoot
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Custom RBXPORT app is missing: $Executable" }
    New-Item -ItemType Directory -Path $ReportDirectory -Force -ErrorAction Stop | Out-Null
    $reportPath = Join-Path $ReportDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString() + '.json')
    # Windows paths cannot contain quotes; trim trailing slashes before quoting.
    $arguments = '--import "' + $full + '" --import-report "' + $reportPath + '"'
    if ($arguments.Length -gt 30000) { throw 'Album path is too long for a Windows command line.' }
    $process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw "RBXPORT returned no result. Album remains queued. Reports: $ReportDirectory" }
    $result = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($process.ExitCode -ne 0 -or $result.ok -isnot [bool] -or $result.ok -ne $true) {
        $message = 'Some tracks were not imported.'
        if ($result.PSObject.Properties['error']) { $message = [string]$result.error }
        throw "$message Album remains queued. Report: $reportPath"
    }
    if (-not $result.PSObject.Properties['report']) { throw 'RBXPORT returned an incomplete report. Album remains queued.' }
    foreach ($field in @('imported', 'existing', 'skipped', 'tracks')) {
        if (-not $result.report.PSObject.Properties[$field]) { throw 'RBXPORT returned an incomplete report. Album remains queued.' }
    }
    if (@($result.report.skipped).Count -gt 0 -or [int]$result.report.imported -ne @($result.report.tracks).Count) {
        throw 'RBXPORT returned an inconsistent report. Album remains queued.'
    }
    $result.report
}

Export-ModuleMember -Function Get-PendingAlbums, Save-PendingAlbums, Assert-CollectionAlbum, Add-PendingAlbum, Remove-PendingAlbum, Invoke-PendingAlbumImport
