param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Music-Import.config.json'),
    [string[]]$Sources,
    [string]$MusicRoot,
    [ValidateSet('ArtistAlbum','PreserveFolders','Flat')][string]$Layout = 'ArtistAlbum',
    [ValidateSet('Move','Copy')][string]$Originals = 'Copy',
    [ValidateSet('AlbumArtist','TrackArtist')][string]$ArtistFolder = 'AlbumArtist',
    [switch]$Recursive,
    [switch]$OrganizeOnly,
    [switch]$NonInteractive,
    [switch]$NoShortcut
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Music-Import.Core.psm1') -Force -DisableNameChecking
function Pick([string]$Prompt,[string]$Default) {
    $answer = Read-Host ($Prompt + ' [' + $Default + ']')
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    $answer.Trim().Trim('"')
}
if (-not $NonInteractive) {
    Write-Host 'Music to Rekordbox - personal setup' -ForegroundColor Cyan
    Write-Host 'Runs only when you click the button. Choose folders or individual ZIP/audio files.'
    $Sources = @()
    do {
        $source = Read-Host 'Full inbox folder or file path (Enter when finished)'
        if (-not [string]::IsNullOrWhiteSpace($source)) { $Sources += $source.Trim().Trim('"') }
    } while (-not [string]::IsNullOrWhiteSpace($source))
    $MusicRoot = Pick 'WHERE SONGS LIVE - permanent music folder' (Join-Path ([Environment]::GetFolderPath('MyMusic')) 'WHERE SONGS LIVE')
    $Recursive = (Pick 'Include inbox subfolders? Y/N' 'N') -match '^y'
    $choice = Pick 'Layout: 1 Artist/Album/Filename, 2 Preserve inbox/ZIP folders, 3 Flat' '1'
    $Layout = switch ($choice) { '1' {'ArtistAlbum'} '2' {'PreserveFolders'} '3' {'Flat'} default {throw 'Choose layout 1, 2, or 3.'} }
    $Originals = Pick 'Originals: Copy keeps downloads; Move deletes after verification. Copy/Move' 'Copy'
    $ArtistFolder = Pick 'Artist folders: AlbumArtist or TrackArtist' 'AlbumArtist'
    $OrganizeOnly = (Pick 'Also register tracks in the current rekordbox library? Y/N' 'Y') -notmatch '^y'
}
if (@($Sources).Count -eq 0 -or [string]::IsNullOrWhiteSpace($MusicRoot)) { throw 'Choose at least one source and a permanent music folder.' }
if ($Originals -notin @('Copy','Move') -or $ArtistFolder -notin @('AlbumArtist','TrackArtist')) { throw 'Invalid originals or artist folder choice.' }
foreach ($path in @($Sources) + @($MusicRoot)) {
    if (-not [System.IO.Path]::IsPathRooted($path)) { throw 'Use full paths, including the drive or network share.' }
}
$MusicRoot = [System.IO.Path]::GetFullPath($MusicRoot)
$Sources = @($Sources | ForEach-Object {[System.IO.Path]::GetFullPath($_)})
foreach ($source in $Sources) {
    if (-not (Test-Path -LiteralPath $source)) { throw "Source is unavailable: $source" }
    if (($source.TrimEnd('\') + '\').StartsWith(($MusicRoot.TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'An inbox must be outside your permanent music folder.' }
}
foreach ($pending in @(Get-MusicPending (Join-Path $PSScriptRoot 'Music-Import.pending.json'))) { Assert-MusicPath $pending $MusicRoot | Out-Null }
$config = [ordered]@{version=1;sources=@($Sources);musicRoot=$MusicRoot;recursive=[bool]$Recursive;layout=$Layout;originals=$Originals;artistFolder=$ArtistFolder;importToRekordbox=(-not [bool]$OrganizeOnly)}
Write-Host ('WHERE SONGS LIVE: ' + $MusicRoot)
Write-Host ('Sources: ' + ($Sources -join ', '))
Write-Host ("Layout: $Layout; originals: $Originals; library import: " + $config.importToRekordbox)
if (-not $NonInteractive -and (Pick 'Save these settings? Y/N' 'Y') -notmatch '^y') { throw 'Setup cancelled.' }
New-Item -ItemType Directory -Path $MusicRoot -Force | Out-Null
Write-MusicJson $ConfigPath $config
Read-MusicSettings $ConfigPath | Out-Null
if (-not $NoShortcut) { & (Join-Path $PSScriptRoot 'Create-Desktop-Shortcut.ps1') -ConfigPath $ConfigPath }
Write-Host 'Settings saved. Close rekordbox and its tray agent before importing.' -ForegroundColor Green
Write-Host 'Choose the active library in rekordbox first. Music storage and the library database may live on different drives.'
