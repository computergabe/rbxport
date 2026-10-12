param(
    [string]$DesktopDirectory = [Environment]::GetFolderPath('DesktopDirectory'),
    [string]$Inbox = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\Bandcamp'),
    [string]$CollectionRoot = (Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Rekordbox Collection')
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Bandcamp-Rekordbox-Launcher.ps1'
$app = Join-Path $PSScriptRoot 'RBXPORT-Bandcamp\rbxport.exe'
foreach ($file in @($launcher, $app, (Join-Path $PSScriptRoot 'Bandcamp-Rekordbox.ps1'), (Join-Path $PSScriptRoot 'Bandcamp-Rekordbox-Queue.psm1'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Package file is missing: $file" }
}
if (-not (Test-Path -LiteralPath $DesktopDirectory -PathType Container)) { throw 'The desktop directory does not exist.' }
foreach ($path in @($launcher, $Inbox, $CollectionRoot)) {
    if ($path.Contains('"') -or $path.EndsWith('\')) { throw 'Use folder paths without quotes or a trailing backslash.' }
}
$name = 'Bandcamp ' + [char]0x2192 + ' Rekordbox.lnk'
$destination = Join-Path $DesktopDirectory $name
if (Test-Path -LiteralPath $destination) { throw "A shortcut already exists: $destination. Rename it before installing this one." }
# WScript cannot reliably save Unicode shortcut filenames; create ASCII first.
$temporary = Join-Path $DesktopDirectory ('Bandcamp-' + [guid]::NewGuid().ToString('N') + '.lnk')
try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($temporary)
    $link.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -Inbox "' + $Inbox + '" -CollectionRoot "' + $CollectionRoot + '"'
    $link.WorkingDirectory = $PSScriptRoot
    $link.Description = 'Verify Bandcamp ZIPs and add their tracks to the rekordbox library.'
    $icon = Join-Path $PSScriptRoot 'Bandcamp-Rekordbox.ico'
    if (Test-Path -LiteralPath $icon) { $link.IconLocation = $icon + ',0' } else { $link.IconLocation = $app + ',0' }
    $link.Save()
    [System.IO.File]::Move($temporary, $destination)
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
Write-Output "Created $destination"
Write-Output 'Keep this extracted package in place; the button runs it from here.'
Write-Output 'Open RBXPORT-Bandcamp\rbxport.exe once to configure Library Protection and automatic updates as described in the guide.'
