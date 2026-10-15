param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$BinarySourceCommit,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Choose a new package output directory.' }
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'The compiled app is missing.' }
if ((Get-Item -LiteralPath $Executable).Length -lt 10000000) { throw 'The compiled app is unexpectedly small.' }
& git -C $repo cat-file -e ($BinarySourceCommit + '^{commit}')
if ($LASTEXITCODE -ne 0) { throw 'Binary source commit is unavailable in this checkout.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$appFolder = Join-Path $output 'RBXPORT-Music'
New-Item -ItemType Directory -Path $appFolder | Out-Null
Copy-Item -LiteralPath $Executable -Destination (Join-Path $appFolder 'rbxport.exe')
foreach ($name in @('Music-To-Rekordbox.ps1','Music-Import.Core.psm1','Setup-Music-Import.ps1','Create-Desktop-Shortcut.ps1','START-HERE.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $output
}
Copy-Item -LiteralPath (Join-Path $repo 'src-tauri\icons\icon.ico') -Destination (Join-Path $output 'Music-Rekordbox.ico')
foreach ($name in @('LICENSE','LICENSING.md')) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $output }
Copy-Item -LiteralPath (Join-Path $repo 'crates\rbl-deck\vendor\rubberband\COPYING') -Destination (Join-Path $output 'GPL-2.0.txt')
Copy-Item -LiteralPath (Join-Path $repo 'docs\user\windows-import.md') -Destination (Join-Path $output 'POWERSHELL-GUIDE.md')
$scriptsCommit = & git -C $repo rev-parse HEAD
$info = [ordered]@{
    binarySourceCommit = $BinarySourceCommit
    packageSourceCommit = $scriptsCommit
    sourceRepository = 'https://github.com/computergabe/rbxport'
    binarySourceArchive = 'https://github.com/computergabe/rbxport/archive/' + $BinarySourceCommit + '.zip'
    executableSHA256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
    platform = 'Windows x64'
}
[System.IO.File]::WriteAllText((Join-Path $output 'BUILD-INFO.json'),($info | ConvertTo-Json),(New-Object System.Text.UTF8Encoding($true)))
$zip = $output + '.zip'
if (Test-Path -LiteralPath $zip) { throw 'The package ZIP already exists.' }
Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip
Get-FileHash -LiteralPath $zip -Algorithm SHA256
