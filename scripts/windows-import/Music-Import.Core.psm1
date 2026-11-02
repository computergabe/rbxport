Set-StrictMode -Version Latest
$script:AudioExtensions = @('.mp3','.m4a','.aac','.flac','.wav','.aiff','.aif','.ogg','.opus')
$script:DefaultNamePatterns = @('%track%. %artist% - %title%','%artist% - %title%')
# Album folders: "Artist - Album (Year)", "Artist - Album", or just the album.
$script:FolderPatterns = @('%albumartist% - %album% (%year%)','%albumartist% - %album%')
$script:PatternFields = @('artist','title','album','albumartist','track','year','dummy')

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
    # Settings saved before these options existed get their defaults.
    if (-not $config.PSObject.Properties['analyze']) { $config | Add-Member -NotePropertyName analyze -NotePropertyValue $true }
    if (-not $config.PSObject.Properties['tagFromNames']) { $config | Add-Member -NotePropertyName tagFromNames -NotePropertyValue $true }
    if (-not $config.PSObject.Properties['filenamePatterns']) { $config | Add-Member -NotePropertyName filenamePatterns -NotePropertyValue $script:DefaultNamePatterns }
    if (-not $config.PSObject.Properties['defaultAlbum']) { $config | Add-Member -NotePropertyName defaultAlbum -NotePropertyValue 'Dub Plates' }
    if (-not $config.PSObject.Properties['artistNames']) { $config | Add-Member -NotePropertyName artistNames -NotePropertyValue @() }
    if (-not $config.PSObject.Properties['bpmRange']) { $config | Add-Member -NotePropertyName bpmRange -NotePropertyValue '70-180' }
    if ($config.bpmRange -isnot [string] -or -not (Test-MusicBpmRange $config.bpmRange)) { throw 'Invalid bpmRange setting; use min-max between 40 and 300, e.g. 90-180.' }
    foreach ($name in @('recursive','importToRekordbox','analyze','tagFromNames')) {
        if ($config.$name -isnot [bool]) { throw "Invalid $name setting." }
    }
    if ($config.defaultAlbum -isnot [string]) { throw 'Invalid defaultAlbum setting.' }
    foreach ($name in @($config.artistNames)) { if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { throw 'Invalid artistNames setting.' } }
    foreach ($pattern in @($config.filenamePatterns)) { Assert-MusicPattern $pattern }
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
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'The app did not return a metadata report. Use the RBXPORT app included in this music package.' }
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

function Test-MusicBpmRange {
    # "min-max" between 40 and 300: the analysis BPM range. A tempo outside it
    # is halved or doubled into it, as in rekordbox's Analysis Setting.
    param([string]$Range)
    if ($Range -notmatch '^\s*(\d{2,3})\s*-\s*(\d{2,3})\s*$') { return $false }
    [int]$Matches[1] -ge 40 -and [int]$Matches[2] -le 300 -and [int]$Matches[1] -lt [int]$Matches[2]
}

function Assert-MusicPattern {
    param([string]$Pattern)
    $fields = @([regex]::Matches($Pattern,'%([^%]*)%') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
    if ($fields.Count -eq 0) { throw "Filename pattern has no %fields%: $Pattern" }
    foreach ($field in $fields) { if ($field -notin $script:PatternFields) { throw "Unknown field %$field% in filename pattern: $Pattern" } }
}

function ConvertFrom-MusicPattern {
    # Mp3tag-style Filename -> Tag: %field% placeholders between literal text.
    # Spaces in the literal text must match first. A second, looser pass lets
    # a separator lose the space on one side, so "immix- back 2 basics" still
    # splits at the dash while "missing-tags" does not.
    param([string]$Text,[string]$Pattern)
    $Text = $Text.Trim()
    foreach ($loose in @($false,$true)) {
        $regex = '^'
        foreach ($part in [regex]::Split($Pattern,'(%[^%]*%)')) {
            if ($part -match '^%([^%]*)%$') {
                $field = $Matches[1].ToLowerInvariant()
                $regex += switch ($field) { 'track' {'(?<track>\d{1,3})'} 'year' {'(?<year>\d{4})'} default {"(?<$field>.+?)"} }
            } elseif ($part) {
                $literal = [regex]::Escape($part.Trim()) -replace '(\\ )+','\s+'
                $before = $part -match '^\s'; $after = $part -match '\s$'
                if ($loose -and $before -and $after) { $regex += "(?:\s+$literal\s*|\s*$literal\s+)" }
                else { $regex += $(if ($before) {'\s+'}) + $literal + $(if ($after) {'\s+'}) }
            }
        }
        $match = [regex]::Match($Text,$regex + '\s*$','IgnoreCase')
        if (-not $match.Success) { continue }
        $result = @{}
        foreach ($field in $script:PatternFields) {
            $group = $match.Groups[$field]
            if ($group.Success -and $field -ne 'dummy') { $result[$field] = $group.Value.Trim() }
        }
        if (@($result.Values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) { return $result }
    }
    $null
}

function Get-MusicField {
    # A report field, or $null when the report has none (strict mode).
    param($Object,[string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value }
}

function Get-MusicArtistSpelling {
    # An artist's preferred spelling from the artistNames setting, matched
    # without regard to case; any other name is returned unchanged.
    param([string]$Name,$Config)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    foreach ($known in @($Config.artistNames)) { if ($known -and $Name.Trim() -ieq $known.Trim()) { return $known.Trim() } }
    $Name
}

function Get-MusicNameTags {
    # The tags a file is missing, read from its file name and its folder's
    # name. Only empty fields are filled; existing tags are never replaced.
    # Returns the fields to write; -Effective merges them over the file's tags.
    param([string]$File,[string]$Relative,$Tags,$Config,[switch]$Effective)
    $fill = [ordered]@{}
    if ($Config.tagFromNames) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($File)
        $name = $null
        foreach ($pattern in @($Config.filenamePatterns)) { $name = ConvertFrom-MusicPattern $stem $pattern; if ($name) { break } }
        if (-not $name) { $name = @{} }
        $folder = @{}
        $directory = [System.IO.Path]::GetDirectoryName($Relative)
        if ($directory) {
            $leaf = [System.IO.Path]::GetFileName($directory)
            foreach ($pattern in $script:FolderPatterns) { $parsed = ConvertFrom-MusicPattern $leaf $pattern; if ($parsed) { $folder = $parsed; break } }
            if (-not $folder['album']) { $folder = @{album=$leaf.Trim()} }
        }
        # The reader falls back to the file name for a missing title.
        if ($name['title'] -and ([string]::IsNullOrWhiteSpace((Get-MusicField $Tags 'title')) -or (Get-MusicField $Tags 'title') -eq $stem)) { $fill.title = $name['title'] }
        if ($name['artist'] -and [string]::IsNullOrWhiteSpace((Get-MusicField $Tags 'artist'))) { $fill.artist = $name['artist'] }
        # A name that fits no pattern but names a listed artist, as in
        # "immix x rakjay ID new bass", is that artist's track.
        if (-not $fill.Contains('artist') -and [string]::IsNullOrWhiteSpace((Get-MusicField $Tags 'artist'))) {
            $named = @($Config.artistNames) | Where-Object { $_ -and $stem -match ('(?i)(^|\W)' + [regex]::Escape($_.Trim()) + '(\W|$)') } | Select-Object -First 1
            if ($named) { $fill.artist = $named.Trim() }
        }
        if ([string]::IsNullOrWhiteSpace((Get-MusicField $Tags 'album'))) {
            $album = @($name['album'],$folder['album'],$Config.defaultAlbum) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            if ($album) { $fill.album = $album }
        }
        if ([string]::IsNullOrWhiteSpace((Get-MusicField $Tags 'albumArtist'))) {
            $albumArtist = @($name['albumartist'],$folder['albumartist']) | Where-Object { $_ } | Select-Object -First 1
            if ($albumArtist) { $fill.albumArtist = $albumArtist }
        }
        if ([int](Get-MusicField $Tags 'trackNumber') -eq 0 -and $name['track']) { $fill.trackNumber = [int]$name['track'] }
        # Listed artists take their preferred spelling, existing tags included.
        foreach ($field in @('artist','albumArtist')) {
            $current = if ($fill.Contains($field)) { $fill[$field] } else { Get-MusicField $Tags $field }
            $spelled = Get-MusicArtistSpelling $current $Config
            if ($spelled -and $spelled -cne $current) { $fill[$field] = $spelled }
        }
        $year = @($name['year'],$folder['year']) | Where-Object { $_ } | Select-Object -First 1
        if ($year -and [int](Get-MusicField $Tags 'year') -eq 0) { $fill.year = [int]$year }
    }
    if (-not $Effective) { return $fill }
    $merged = [ordered]@{}
    foreach ($field in @('artist','albumArtist','album','title','trackNumber')) { $merged[$field] = Get-MusicField $Tags $field }
    foreach ($field in $fill.Keys) { $merged[$field] = $fill[$field] }
    [pscustomobject]$merged
}

function Write-MusicTags {
    param([string]$Executable,[string]$Path,$Tags,[string]$Reports)
    $id = [guid]::NewGuid().ToString('N')
    $inputPath = Join-Path $Reports ($id + '-tags.json')
    $reportPath = Join-Path $Reports ($id + '-tags-report.json')
    $entry = [ordered]@{path=$Path}
    foreach ($field in $Tags.Keys) { $entry[$field] = $Tags[$field] }
    Write-MusicJson $inputPath @($entry)
    $process = Start-Process -FilePath $Executable -ArgumentList ('--write-tags "' + $inputPath + '" --write-tags-report "' + $reportPath + '"') -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'The app did not return a tag report. Use the RBXPORT app included in this music package.' }
    $result = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or $result.ok -ne $true) { throw "Tags could not be written. Original retained. Report: $reportPath" }
    Remove-Item -LiteralPath $inputPath,$reportPath -ErrorAction SilentlyContinue
}

function Copy-VerifiedMusic {
    param([string]$Source,[string]$Destination,[string]$Root,$Tags,[string]$Executable,[string]$Reports)
    if ($Tags -and $Tags.Count -gt 0) { return Copy-TaggedMusic $Source $Destination $Root $Tags $Executable $Reports }
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

function Copy-TaggedMusic {
    # The verified copy with tags written into it before it takes its final
    # name. The original is never modified. Duplicates are recognised by the
    # tagged result, so a repeated run finds its earlier copy.
    param([string]$Source,[string]$Destination,[string]$Root,$Tags,[string]$Executable,[string]$Reports)
    $destination = Assert-MusicPath $Destination $Root
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
    $parent = [System.IO.Path]::GetDirectoryName($destination)
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    $temporary = Join-Path $parent ('.music-copy-' + [guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($destination))
    try {
        [System.IO.File]::Copy($Source,$temporary,$false)
        if ((Get-FileHash -LiteralPath $temporary).Hash -ne $hash -or (Get-FileHash -LiteralPath $Source).Hash -ne $hash) { throw 'Copy verification failed or the source changed. Original retained.' }
        Write-MusicTags $Executable $temporary $Tags $Reports
        $tagged = (Get-FileHash -LiteralPath $temporary).Hash
        if (Test-Path -LiteralPath $destination) {
            if ((Get-FileHash -LiteralPath $destination).Hash -eq $tagged) { return $destination }
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($destination)
            $extension = [System.IO.Path]::GetExtension($destination)
            $destination = Assert-MusicPath (Join-Path $parent ($stem + ' (' + $hash.Substring(0,12).ToLowerInvariant() + ')' + $extension)) $Root
            if (Test-Path -LiteralPath $destination) {
                if ((Get-FileHash -LiteralPath $destination).Hash -eq $tagged) { return $destination }
                throw 'A different file already occupies the collision-safe destination.'
            }
        }
        [System.IO.File]::Move($temporary,$destination)
        if ((Get-FileHash -LiteralPath $destination).Hash -ne $tagged) { throw 'Final file verification failed. Original retained.' }
        $destination
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue } }
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
        $fill = Get-MusicNameTags $file.path $file.relative $tags[$file.path] $Config
        $effective = Get-MusicNameTags $file.path $file.relative $tags[$file.path] $Config -Effective
        $destination = Get-MusicDestination $file.path $file.relative $effective $Config
        $final = Copy-VerifiedMusic $file.path $destination $Config.musicRoot $fill $Executable $Reports
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
    param([string]$Executable,[string[]]$Paths,[string]$Root,[string]$Reports,[switch]$Analyze,[string]$BpmRange,[switch]$Reanalyze)
    $arguments = ''
    foreach ($path in $Paths) {
        $full = Assert-MusicPath $path $Root
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Queued track is missing: $full" }
        $arguments += '--import "' + $full + '" '
    }
    $report = Join-Path $Reports ([guid]::NewGuid().ToString('N') + '-import.json')
    if ($Analyze) {
        $arguments += '--analyze '
        if ($BpmRange) { $arguments += '--analyze-bpm ' + ($BpmRange -replace '\s','') + ' ' }
        if ($Reanalyze) { $arguments += '--reanalyze ' }
    }
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
    # One entry per analysed track; a failed analysis leaves the track imported.
    $analysis = if ($result.PSObject.Properties['analysis']) { @($result.analysis) } else { @() }
    $result.report | Add-Member -NotePropertyName analysis -NotePropertyValue $analysis -PassThru
}

function Find-MusicMissing {
    # rekordbox's Display All Missing Files and Auto Relocate, headless: lists
    # tracks whose file is gone, searches the folders for the same file name,
    # and with -Relocate points each track at its one clear match.
    param([string]$Executable,[string[]]$Folders,[string]$Reports,[switch]$Relocate)
    $folders = @($Folders | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
    if ($folders.Count -eq 0) { throw 'No folder to search is available.' }
    $report = Join-Path $Reports ([guid]::NewGuid().ToString('N') + '-missing.json')
    $arguments = ''
    foreach ($folder in $folders) { $arguments += '--find-missing "' + $folder + '" ' }
    if ($Relocate) { $arguments += '--relocate ' }
    $arguments += '--missing-report "' + $report + '"'
    $process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $report)) { throw 'No missing-file report was produced.' }
    $result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or $result.ok -ne $true) {
        $message = 'The missing-file check failed.'
        if ($result.PSObject.Properties['error']) { $message = $result.error }
        throw "$message Report: $report"
    }
    $result
}

function Select-MusicFolder {
    param([string]$Description,[string]$Start)
    # Windows folder picker; returns $null when cancelled.
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form -Property @{TopMost=$true;ShowInTaskbar=$false}
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        if ($Start -and (Test-Path -LiteralPath $Start -PathType Container)) { $dialog.SelectedPath = $Start }
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        $null
    } finally { $dialog.Dispose(); $owner.Dispose() }
}

Export-ModuleMember -Function Write-MusicJson, Read-MusicSettings, Test-MusicBpmRange, Assert-MusicPattern, ConvertFrom-MusicPattern, Get-MusicArtistSpelling, Get-MusicNameTags, Write-MusicTags, Assert-MusicPath, Get-MusicPending, Add-MusicPending, Get-MusicSources, Read-MusicTags, Get-MusicSegment, Get-MusicDestination, Copy-VerifiedMusic, Save-MusicSource, Invoke-MusicLibraryImport, Find-MusicMissing, Select-MusicFolder
