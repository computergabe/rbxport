param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$FixtureRoot
)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $FixtureRoot){throw 'Choose a new fixture directory.'}
$root=[IO.Path]::GetFullPath($FixtureRoot)
$package=Join-Path $root 'Launcher'
$inbox=Join-Path $root 'Inbox'
$music=Join-Path $root 'Music'
$app=Join-Path $package 'RBXPORT-Music'
foreach($path in @($package,$inbox,$music,$app)){New-Item -ItemType Directory -Path $path -Force | Out-Null}
foreach($name in @('Music-To-Rekordbox.ps1','Music-Import.Core.psm1','Setup-Music-Import.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $package}
Copy-Item -LiteralPath $Executable -Destination (Join-Path $app 'rbxport.exe')
$wave=Join-Path $inbox ('fixture '+[char]0x65B0+'.wav')
$stream=New-Object IO.MemoryStream
$writer=New-Object IO.BinaryWriter($stream)
$writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
$writer.Write([int]292)
$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
$writer.Write([int]16)
$writer.Write([int16]1);$writer.Write([int16]1)
$writer.Write([int]44100);$writer.Write([int]88200)
$writer.Write([int16]2);$writer.Write([int16]16)
$writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
$writer.Write([int]256);$writer.Write((New-Object byte[] 256))
# Add standard WAV INFO artist/album tags.
$infoStream=New-Object IO.MemoryStream
$infoWriter=New-Object IO.BinaryWriter($infoStream)
$infoWriter.Write([Text.Encoding]::ASCII.GetBytes('INFO'))
foreach($tag in @(@('IART','Fixture Artist'),@('IPRD','Fixture Album'))){
 $value=[Text.Encoding]::ASCII.GetBytes($tag[1]+[char]0)
 $infoWriter.Write([Text.Encoding]::ASCII.GetBytes($tag[0]))
 $infoWriter.Write([int]$value.Length);$infoWriter.Write($value)
 if($value.Length % 2){$infoWriter.Write([byte]0)}
}
$infoWriter.Flush();$info=$infoStream.ToArray()
$writer.Write([Text.Encoding]::ASCII.GetBytes('LIST'))
$writer.Write([int]$info.Length);$writer.Write($info);$writer.Flush()
$bytes=$stream.ToArray()
[Array]::Copy([BitConverter]::GetBytes([int]($bytes.Length-8)),0,$bytes,4,4)
[IO.File]::WriteAllBytes($wave,$bytes)
$writer.Dispose();$stream.Dispose();$infoWriter.Dispose();$infoStream.Dispose()
$hash=(Get-FileHash -LiteralPath $wave).Hash
$payload=Join-Path $root 'Zip payload'
New-Item -ItemType Directory -Path $payload | Out-Null
Copy-Item -LiteralPath $wave -Destination $payload
$zip=Join-Path $inbox 'album.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip
& (Join-Path $package 'Setup-Music-Import.ps1') -NonInteractive -NoShortcut -OrganizeOnly -Sources @($inbox) -MusicRoot $music -Originals Move
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Music-To-Rekordbox.ps1') -NoPause
if($LASTEXITCODE -ne 0){throw 'Actual native organizer failed.'}
if((Test-Path -LiteralPath $wave) -or (Test-Path -LiteralPath $zip)){throw 'Verified originals retained.'}
$paths=@((Get-Content -LiteralPath (Join-Path $package 'Music-Import.pending.json') -Raw -Encoding UTF8 | ConvertFrom-Json).files)
if($paths.Count -ne 1){throw 'Identical ZIP/loose audio did not deduplicate.'}
foreach($path in $paths){
 if((Get-FileHash -LiteralPath $path).Hash -ne $hash){throw 'Audio changed.'}
 if($path -notlike '*Fixture Artist\Fixture Album\*'){throw 'Native tags did not organize folders.'}
}
Write-Output 'Actual app and PowerShell 5: tagged ZIP + loose WAV, Unicode, verified move, deduplication and durable queue passed; no library opened.'
exit 0
