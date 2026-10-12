Set-StrictMode -Version Latest
$script:AudioExtensions = @('.mp3','.m4a','.aac','.flac','.wav','.aiff','.aif','.ogg','.opus')

function Write-MusicJson {
    param([string]$Path, $Value)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        # Rust's JSON reader expects UTF-8 without a byte-order mark.
        [System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temporary,$Path,($Path + '.previous')) }
        else { [System.IO.File]::Move($temporary,$Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Read-MusicSettings {
    param([string]$Path)
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($config.version -ne 1 -or @($config.sources).Count -eq 0) { throw 'Invalid music inbox configuration.' }
    foreach ($name in @('recursive','importToRekordbox')) {
        if ($config.$name -isnot [bool]) { throw "Invalid $name setting." }
    }
    if ($config.layout -notin @('ArtistAlbum','PreserveFolders','Flat') -or $config.originals -notin @('Move','Copy') -or $config.artistFolder -notin @('AlbumArtist','TrackArtist')) { throw 'Unsupported organization setting.' }
    foreach ($path in @($config.sources) + @($config.musicRoot)) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [System.IO.Path]::IsPathRooted($path)) { throw 'Choose full source and storage paths.' }
    }
    if (-not (Test-Path -LiteralPath $config.musicRoot -PathType Container)) { throw 'Your music storage folder is unavailable. Connect its drive before importing.' }
    $config
}

function Assert-MusicPath {
    param([string]$Path,[string]$Root)
    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside music storage: $Path" }
    $ancestor = $full
    while ($ancestor.Length -gt $prefix.TrimEnd('\').Length) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'A destination crosses a symbolic link or junction. Choose a direct storage path.' }
        $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)
    }
    $full
}

function Get-MusicPending {
    param([string]$Queue)
    if (-not (Test-Path -LiteralPath $Queue)) { return }
    $data = Get-Content -LiteralPath $Queue -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.version -ne 1) { throw 'Unsupported music import queue.' }
    foreach ($path in $data.files) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) { throw 'Invalid queued music path.' }
        $path
    }
}

function Add-MusicPending {
    param([string]$Queue,[string]$Path,[string]$Root)
    $full = Assert-MusicPath $Path $Root
    $files = @(Get-MusicPending $Queue)
    if ($files -notcontains $full) { Write-MusicJson $Queue @{version=1;files=@($files + $full)} }
}

function Get-MusicSources {
    param($Config,[string]$StateRoot)
    $music = [System.IO.Path]::GetFullPath($Config.musicRoot).TrimEnd('\') + '\'
    $state = [System.IO.Path]::GetFullPath($StateRoot).TrimEnd('\') + '\'
    $seen = @{}
    foreach ($source in $Config.sources) {
        if (-not (Test-Path -LiteralPath $source)) {
            # A selected individual file may have been consumed by a previous run.
            if ([System.IO.Path]::GetExtension($source).ToLowerInvariant() -in ($script:AudioExtensions + @('.zip')) -and (Test-Path -LiteralPath ([System.IO.Path]::GetDirectoryName($source)) -PathType Container)) { continue }
            throw "Source is unavailable: $source"
        }
        $item = Get-Item -LiteralPath $source
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Choose a direct source path instead of a symbolic link: $source" }
        if (-not $item.PSIsContainer) { $items = @($item) }
        else {
            $stack = New-Object 'System.Collections.Generic.Stack[string]'
            $stack.Push($item.FullName)
            $items = @()
            while ($stack.Count -gt 0) {
                foreach ($child in Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop) {
                    $full = $child.FullName
                    if (($full + '\').StartsWith($music,[StringComparison]::OrdinalIgnoreCase) -or ($full + '\').StartsWith($state,[StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($child.PSIsContainer) { if ($Config.recursive) { $stack.Push($full) } }
                    else { $items += $child }
                }
            }
        }
        foreach ($file in $items) {
            if ($file.FullName.StartsWith($music,[StringComparison]::OrdinalIgnoreCase) -or $file.FullName.StartsWith($state,[StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($file.Extension.ToLowerInvariant() -notin ($script:AudioExtensions + @('.zip')) -or $seen.ContainsKey($file.FullName)) { continue }
            $seen[$file.FullName] = $true
            [pscustomobject]@{path=$file.FullName;sourceRoot=($(if($item.PSIsContainer){$item.FullName}else{$item.DirectoryName}))}
        }
    }
}

function Read-MusicTags {
    param([string]$Executable,[string[]]$Paths,[string]$Reports)
    $id = [guid]::NewGuid().ToString('N')
    $inputPath = Join-Path $Reports ($id + '-files.json')
    $reportPath = Join-Path $Reports ($id + '-metadata.json')
    Write-MusicJson $inputPath @($Paths)
    $arguments = '--inspect-list "' + $inputPath + '" --inspect-report "' + $reportPath + '"'
    $process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'The app did not return a metadata report. Use the universal music preview build.' }
    $result = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or $result.ok -ne $true) { throw "Audio metadata could not be read. Original retained. Report: $reportPath" }
    $map = @{}
    foreach ($file in $result.files) { $map[$file.path] = $file }
    foreach ($path in $Paths) { if (-not $map.ContainsKey($path)) { throw 'Metadata report omitted a file.' } }
    $map
}

function Get-MusicSegment {
    param([string]$Value,[string]$Fallback)
    $value = ($Value -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Fallback }
    if ($value -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { $value = '_' + $value }
    if ($value.Length -gt 80) { $value = $value.Substring(0,80).TrimEnd('.') }
    $value
}

function Get-MusicDestination {
    param([string]$File,[string]$Relative,$Tags,$Config)
    if ($Config.layout -eq 'ArtistAlbum') {
        $artist = $Tags.artist
        if ($Config.artistFolder -eq 'AlbumArtist' -and -not [string]::IsNullOrWhiteSpace($Tags.albumArtist)) { $artist = $Tags.albumArtist }
        $folder = Join-Path (Get-MusicSegment $artist 'Unknown Artist') (Get-MusicSegment $Tags.album 'Unknown Album')
        $relativePath = Join-Path $folder ([System.IO.Path]::GetFileName($File))
    } elseif ($Config.layout -eq 'Flat') { $relativePath = [System.IO.Path]::GetFileName($File) }
    else { $relativePath = $Relative }
    Assert-MusicPath (Join-Path $Config.musicRoot $relativePath) $Config.musicRoot
}

function Copy-VerifiedMusic {
    param([string]$Source,[string]$Destination,[string]$Root)
    $destination = Assert-MusicPath $Destination $Root
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash -LiteralPath $destination).Hash -eq $hash) { return $destination }
        $directory = [System.IO.Path]::GetDirectoryName($destination)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($destination)
        $extension = [System.IO.Path]::GetExtension($destination)
        $destination = Assert-MusicPath (Join-Path $directory ($stem + ' (' + $hash.Substring(0,12).ToLowerInvariant() + ')' + $extension)) $Root
        if (Test-Path -LiteralPath $destination) {
            if ((Get-FileHash -LiteralPath $destination).Hash -eq $hash) { return $destination }
            throw 'A different file already occupies the collision-safe destination.'
        }
    }
    $parent = [System.IO.Path]::GetDirectoryName($destination)
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    $temporary = Join-Path $parent ('.music-copy-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::Copy($Source,$temporary,$false)
    if ((Get-FileHash -LiteralPath $temporary).Hash -ne $hash -or (Get-FileHash -LiteralPath $Source).Hash -ne $hash) { throw 'Copy verification failed or the source changed. Original retained.' }
    [System.IO.File]::Move($temporary,$destination)
    if ((Get-FileHash -LiteralPath $destination).Hash -ne $hash) { throw 'Final file verification failed. Original retained.' }
    $destination
}

function Save-MusicSource {
    param($Source,$Config,[string]$Executable,[string]$StateRoot,[string]$Queue,[string]$Reports)
    $path = $Source.path
    $originalHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    $archive = [System.IO.Path]::GetExtension($path).Equals('.zip',[StringComparison]::OrdinalIgnoreCase)
    $files = @(); $extras = @(); $stage = $null
    if ($archive) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stage = Join-Path (Join-Path $StateRoot '_staging') ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $prefix = [System.IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
        $seen = @{}; $expected = @()
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            foreach ($entry in $zip.Entries) {
                if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }
                $relative = $entry.FullName.Replace('/','\')
                foreach ($segment in $relative.Split('\')) {
                    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -match '[<>:"|?*\x00-\x1f]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'Unsafe Windows ZIP filename. Original retained.' }
                }
                $full = [System.IO.Path]::GetFullPath((Join-Path $stage $relative))
                if ([System.IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($full)) { throw 'Unsafe or duplicate ZIP path. Original retained.' }
                $seen[$full] = $true
                $expected += [pscustomobject]@{path=$full;relative=$relative;length=$entry.Length}
            }
        } finally { $zip.Dispose() }
        foreach ($entry in $expected) {
            if ([System.IO.Path]::GetExtension($entry.path).ToLowerInvariant() -in $script:AudioExtensions -and [System.IO.Path]::GetFileName($entry.path) -notlike '._*' -and $entry.relative -notmatch '(^|\\)__MACOSX(\\|$)') { $files += $entry }
            else { $extras += $entry }
        }
        if ($files.Count -eq 0) { throw 'ZIP contains no supported audio. Original retained.' }
        Expand-Archive -LiteralPath $path -DestinationPath $stage -ErrorAction Stop
        foreach ($entry in $expected) {
            if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf) -or (Get-Item -LiteralPath $entry.path).Length -ne $entry.length) { throw 'ZIP extraction verification failed. Original retained.' }
        }
    } else {
        $root = [System.IO.Path]::GetFullPath($Source.sourceRoot).TrimEnd('\') + '\'
        $relative = $path.Substring($root.Length)
        $files = @([pscustomobject]@{path=$path;relative=$relative;length=(Get-Item -LiteralPath $path).Length})
    }
    $tags = Read-MusicTags $Executable @($files | ForEach-Object {$_.path}) $Reports
    $saved = @()
    foreach ($file in $files) {
        $destination = Get-MusicDestination $file.path $file.relative $tags[$file.path] $Config
        $final = Copy-VerifiedMusic $file.path $destination $Config.musicRoot
        Add-MusicPending $Queue $final $Config.musicRoot
        $saved += $final
    }
    if ($extras.Count -gt 0) {
        $extraFolder = '_archive-extras\' + (Get-MusicSegment ([System.IO.Path]::GetFileNameWithoutExtension($path)) 'Archive') + '-' + $originalHash.Substring(0,12).ToLowerInvariant()
        foreach ($extra in $extras) {
            $destination = Join-Path $Config.musicRoot (Join-Path $extraFolder $extra.relative)
            Copy-VerifiedMusic $extra.path $destination $Config.musicRoot | Out-Null
        }
    }
    if ((Get-FileHash -LiteralPath $path).Hash -ne $originalHash) { throw 'Source changed during processing. It was retained.' }
    if ($Config.originals -eq 'Move') { Remove-Item -LiteralPath $path -ErrorAction Stop }
    if ($archive) {
        # Delete only the known staging files and then empty directories.
        # Every target is checked beneath this run's generated staging root.
        try {
            foreach ($entry in $expected) {
                if (-not $entry.path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected staging cleanup path.' }
                Remove-Item -LiteralPath $entry.path -ErrorAction Stop
            }
            $directories = [System.IO.Directory]::GetDirectories($stage,'*',[System.IO.SearchOption]::AllDirectories) | Sort-Object Length -Descending
            foreach ($directory in $directories) {
                if (-not $directory.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected staging directory.' }
                [System.IO.Directory]::Delete($directory,$false)
            }
            [System.IO.Directory]::Delete($stage,$false)
        } catch { Write-Warning "Verified music is safe; staging was retained for review: $stage" }
    }
    [pscustomobject]@{source=$path;tracks=$saved.Count;archive=$archive;originals=$Config.originals}
}

function Invoke-MusicLibraryImport {
    param([string]$Executable,[string[]]$Paths,[string]$Root,[string]$Reports)
    $arguments = ''
    foreach ($path in $Paths) {
        $full = Assert-MusicPath $path $Root
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Queued track is missing: $full" }
        $arguments += '--import "' + $full + '" '
    }
    $report = Join-Path $Reports ([guid]::NewGuid().ToString('N') + '-import.json')
    $arguments += '--import-report "' + $report + '"'
    if ($arguments.Length -gt 30000) { throw 'Import batch is too long.' }
    $process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $report)) { throw 'No library import report was produced.' }
    $result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or $result.ok -ne $true) {
        $message = 'Library import was incomplete.'
        if ($result.PSObject.Properties['error']) { $message = $result.error }
        throw "$message Files remain queued. Report: $report"
    }
    foreach ($field in @('imported','tracks','existing','skipped')) { if (-not $result.report.PSObject.Properties[$field]) { throw 'Incomplete library import report.' } }
    if (@($result.report.skipped).Count -ne 0 -or [int]$result.report.imported -ne @($result.report.tracks).Count) { throw 'Inconsistent library import report.' }
    if ([int]$result.report.imported + @($result.report.existing).Count -ne $Paths.Count) { throw 'Library report did not account for every queued file.' }
    $result.report
}

Export-ModuleMember -Function Write-MusicJson, Read-MusicSettings, Assert-MusicPath, Get-MusicPending, Add-MusicPending, Get-MusicSources, Read-MusicTags, Get-MusicSegment, Get-MusicDestination, Copy-VerifiedMusic, Save-MusicSource, Invoke-MusicLibraryImport
