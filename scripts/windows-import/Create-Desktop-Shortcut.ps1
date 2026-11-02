param(
    [string]$DesktopDirectory = [Environment]::GetFolderPath('DesktopDirectory'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Music-Import.config.json'),
    # Overwrite an existing button, e.g. one that still opens the console launcher.
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Music-Import-GUI.ps1'
$app = Join-Path $PSScriptRoot 'RBXPORT-Music\rbxport.exe'
foreach ($file in @($launcher,(Join-Path $PSScriptRoot 'Music-To-Rekordbox.ps1'),$app,$ConfigPath,(Join-Path $PSScriptRoot 'Music-Import.Core.psm1'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Package file is missing: $file" }
}
if (-not (Test-Path -LiteralPath $DesktopDirectory -PathType Container)) { throw 'Desktop folder is unavailable.' }
foreach ($path in @($launcher,$ConfigPath)) { if ($path.Contains('"')) { throw 'A path contains a quote.' } }
$destination = Join-Path $DesktopDirectory ('Music ' + [char]0x2192 + ' Rekordbox.lnk')
if ((Test-Path -LiteralPath $destination) -and -not $Replace) {
    Write-Output "Shortcut already exists; settings were saved. To replace the button, rename it first: $destination"
    return
}
$temporary = Join-Path $DesktopDirectory ('Music-' + [guid]::NewGuid().ToString('N') + '.lnk')
try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($temporary)
    $link.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" -ConfigPath "' + $ConfigPath + '"'
    $link.WorkingDirectory = $PSScriptRoot
    $link.Description = 'Verify and organize downloaded music, then import it into rekordbox.'
    $icon = Join-Path $PSScriptRoot 'Music-Rekordbox.ico'
    if (Test-Path -LiteralPath $icon) { $link.IconLocation = $icon + ',0' } else { $link.IconLocation = $app + ',0' }
    $link.Save()
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }
    [System.IO.File]::Move($temporary,$destination)
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
Write-Output "Created $destination. Keep the extracted package in its permanent location."
