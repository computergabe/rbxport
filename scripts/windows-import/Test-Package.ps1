param([Parameter(Mandatory=$true)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Use Windows PowerShell 5.1.' }
if (Test-Path -LiteralPath $FixtureRoot) { throw 'Choose a new fixture directory.' }
$root=[IO.Path]::GetFullPath($FixtureRoot)
$inbox=Join-Path $root 'Inbox'
$other=Join-Path $root 'Other'
$music=Join-Path $root 'WHERE SONGS LIVE'
$package=Join-Path $root 'Launcher'
$app=Join-Path $package 'RBXPORT-Music'
$reports=Join-Path $package 'reports'
$desktop=Join-Path $root 'Desktop'
foreach($path in @($root,$inbox,$other,$music,$app,$reports,$desktop)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
foreach($name in @('Music-To-Rekordbox.ps1','Music-Import.Core.psm1','Setup-Music-Import.ps1','Create-Desktop-Shortcut.ps1')) {
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $package
 $tokens=$null; $errors=$null
 [Management.Automation.Language.Parser]::ParseFile((Join-Path $package $name),[ref]$tokens,[ref]$errors) | Out-Null
 if($errors.Count) {throw ($errors.Message -join '; ')}
}
$mock=@'
using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
class MusicMock {
 static int Main(string[] args) {
  var json=new JavaScriptSerializer(); string report=args[args.Length-1];
  if(args[0]=="--inspect-list") {
   var files=new List<object>();
   foreach(string path in json.Deserialize<string[]>(File.ReadAllText(args[1]))) {
    if(path.Contains("bad-tags")) {File.WriteAllText(report,json.Serialize(new {ok=false,errors=new[]{"Unreadable audio"}})); return 1;}
    bool empty=path.Contains("missing-tags");
    files.Add(new {path=path,artist=empty?"":"Track Artist",albumArtist=empty?"":"Album Artist",album=empty?"":"Fixture Album"});
   }
   File.WriteAllText(report,json.Serialize(new {ok=true,files=files,errors=new string[0]})); return 0;
  }
  if(File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"refuse"))) {
   File.WriteAllText(report,json.Serialize(new {ok=false,error="Fixture library refusal"})); return 1;
  }
  var tracks=new List<object>(); for(int i=0;i<args.Length-2;i+=2) tracks.Add(new {id="fixture",path=args[i+1]});
  File.WriteAllText(report,json.Serialize(new {ok=true,report=new {imported=tracks.Count,tracks=tracks,existing=new object[0],skipped=new string[0]}})); return 0;
 }
}
'@
$exe=Join-Path $app 'rbxport.exe'
Add-Type -TypeDefinition $mock -ReferencedAssemblies 'System.Web.Extensions' -OutputAssembly $exe -OutputType ConsoleApplication
Import-Module (Join-Path $package 'Music-Import.Core.psm1') -Force -DisableNameChecking
function Assert($condition,[string]$message) {if(-not $condition){throw $message}}
function Audio([string]$path,[byte]$value=1) {[IO.File]::WriteAllBytes($path,[byte[]]($value,$value,3,4));$path}
function Run([int]$expected) {
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Music-To-Rekordbox.ps1') -NoPause
 Assert ($LASTEXITCODE -eq $expected) "Unexpected exit: $LASTEXITCODE"
}
$loose=Audio (Join-Path $other ('solo '+[char]0x65B0+'.wav'))
$payload=Join-Path $root 'payload'
New-Item -ItemType Directory -Path (Join-Path $payload 'nested') -Force | Out-Null
$track=Audio (Join-Path $payload 'nested\track.wav')
[IO.File]::WriteAllText((Join-Path $payload 'cover.txt'),'extras preserved')
$zip=Join-Path $inbox 'album.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip
& (Join-Path $package 'Setup-Music-Import.ps1') -Sources @($inbox,$loose) -MusicRoot $music -Originals Move -NonInteractive -NoShortcut -OrganizeOnly
Run 0
Assert (-not (Test-Path -LiteralPath $zip)) 'ZIP retained in Move mode.'
Assert (-not (Test-Path -LiteralPath $loose)) 'Standalone track retained in Move mode.'
$organized=Join-Path $music 'Album Artist\Fixture Album\track.wav'
Assert ((Get-FileHash -LiteralPath $organized).Hash -eq (Get-FileHash -LiteralPath $track).Hash) 'Audio changed.'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $music '_archive-extras') -Recurse -Filter cover.txt).Count -eq 1) 'Extras lost.'
$queue=Join-Path $package 'Music-Import.pending.json'
Assert (@(Get-MusicPending $queue).Count -eq 2) 'Tracks not queued.'
Run 0
Assert (@(Get-MusicPending $queue).Count -eq 2) 'Consumed individual source broke a repeat run.'
$configPath=Join-Path $package 'Music-Import.config.json'
$config=Read-MusicSettings $configPath
$config.sources=@($inbox,$other); Write-MusicJson $configPath $config
$collision=Audio (Join-Path $other 'track.wav') 2
$missing=Audio (Join-Path $other 'missing-tags.wav') 3
Run 0
Assert (@(Get-ChildItem -LiteralPath (Split-Path $organized) -Filter 'track*.wav').Count -eq 2) 'Collision overwritten.'
Assert (Test-Path -LiteralPath (Join-Path $music 'Unknown Artist\Unknown Album\missing-tags.wav')) 'Missing tags failed.'
Assert ((Get-FileHash -LiteralPath $organized).Hash -eq (Get-FileHash -LiteralPath $track).Hash) 'Original destination changed.'
$copy=Audio (Join-Path $other 'copy.wav')
$config.originals='Copy'; Write-MusicJson $configPath $config
Run 0
$before=@(Get-MusicPending $queue).Count
Run 0
Assert (Test-Path -LiteralPath $copy) 'Copy source deleted.'
Assert (@(Get-MusicPending $queue).Count -eq $before) 'Repeat duplicated queue.'
$refuse=Join-Path $app 'refuse'; New-Item -ItemType File -Path $refuse | Out-Null
try {Invoke-MusicLibraryImport $exe @(Get-MusicPending $queue) $music $reports | Out-Null; throw 'Refusal accepted.'}
catch {Assert ($_.Exception.Message -like '*Fixture library refusal*') 'Unexpected refusal error.'}
Assert (@(Get-MusicPending $queue).Count -eq $before) 'Refusal lost queue.'
Remove-Item -LiteralPath $refuse
$result=Invoke-MusicLibraryImport $exe @(Get-MusicPending $queue) $music $reports
Assert ($result.imported -eq $before) 'Import omitted tracks.'
Write-MusicJson $queue @{version=1;files=@()}
if(-not (Get-Process | Where-Object {$_.ProcessName -match '^(rekordbox|rekordboxagent|rbxport)$'})) {
 $config.importToRekordbox=$true; Write-MusicJson $configPath $config; Run 0
 Assert (@(Get-MusicPending $queue).Count -eq 0) 'Completed import remained queued.'
}
$config.importToRekordbox=$false; $config.originals='Move'; Write-MusicJson $configPath $config
$bad=Join-Path $inbox 'corrupt.zip'; [IO.File]::WriteAllText($bad,'not a ZIP')
$badTags=Audio (Join-Path $other 'bad-tags.wav')
Run 1
Assert ((Test-Path -LiteralPath $bad) -and (Test-Path -LiteralPath $badTags)) 'Failed originals deleted.'
Remove-Item -LiteralPath $bad
Remove-Item -LiteralPath $badTags
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unsafe=Join-Path $inbox 'unsafe.zip'
$archive=[IO.Compression.ZipFile]::Open($unsafe,[IO.Compression.ZipArchiveMode]::Create)
try {$entry=$archive.CreateEntry('../escape.wav');$stream=$entry.Open();$stream.WriteByte(1);$stream.Dispose()} finally {$archive.Dispose()}
Run 1
Assert (Test-Path -LiteralPath $unsafe) 'Unsafe ZIP deleted.'
Assert (-not (Test-Path -LiteralPath (Join-Path $root 'escape.wav'))) 'ZIP escaped.'
Remove-Item -LiteralPath $unsafe
$tags=[pscustomobject]@{artist='Track Artist';albumArtist='Album Artist';album='Fixture Album'}
$config.layout='PreserveFolders'
Assert ((Get-MusicDestination $track 'nested\track.wav' $tags $config) -eq (Join-Path $music 'nested\track.wav')) 'Preserve layout failed.'
$config.layout='Flat'
Assert ((Get-MusicDestination $track 'nested\track.wav' $tags $config) -eq (Join-Path $music 'track.wav')) 'Flat layout failed.'
$config.layout='ArtistAlbum';$config.artistFolder='TrackArtist'
Assert ((Get-MusicDestination $track 'track.wav' $tags $config) -eq (Join-Path $music 'Track Artist\Fixture Album\track.wav')) 'Track artist failed.'
$config.musicRoot=Join-Path $root 'Disconnected drive';Write-MusicJson $configPath $config
$offline=Audio (Join-Path $other 'offline.wav');Run 1
Assert (Test-Path -LiteralPath $offline) 'Offline storage lost source.'
$config.musicRoot=$music;Write-MusicJson $configPath $config
& (Join-Path $package 'Create-Desktop-Shortcut.ps1') -DesktopDirectory $desktop
$link=@(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk')[0]
$ascii=Join-Path $desktop 'inspect.lnk';Copy-Item -LiteralPath $link.FullName -Destination $ascii
$shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($ascii)
Assert ($shortcut.Arguments -like '*-NoProfile -ExecutionPolicy Bypass*Music-To-Rekordbox.ps1*') 'Shortcut arguments differ.'
Assert ($shortcut.Arguments -notlike '*Watch*') 'Watch enabled.'
Write-Output 'Universal music fixtures passed: ZIP, standalone, tags, collisions, extras, copy/move, retry, layouts, offline storage, shortcut.'
exit 0
