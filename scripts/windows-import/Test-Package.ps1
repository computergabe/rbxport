param([Parameter(Mandatory=$true)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Use Windows PowerShell 5.1.' }
if (Test-Path -LiteralPath $FixtureRoot) { throw 'Choose a new fixture directory.' }
$root=[IO.Path]::GetFullPath($FixtureRoot)
$inbox=Join-Path $root 'Inbox'
$other=Join-Path $root 'Other'
$music=Join-Path $root 'Music Library'
$package=Join-Path $root 'Launcher'
$app=Join-Path $package 'RBXPORT-Music'
$reports=Join-Path $package 'reports'
$desktop=Join-Path $root 'Desktop'
foreach($path in @($root,$inbox,$other,$music,$app,$reports,$desktop)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
foreach($name in @('Music-To-Rekordbox.ps1','Music-Import-GUI.ps1','Music-Import.Core.psm1','Setup-Music-Import.ps1','Create-Desktop-Shortcut.ps1')) {
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
  if(args[0]=="--find-missing") {
   bool relocate=new List<string>(args).Contains("--relocate");
   File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"missing-args.txt"),string.Join("|",args));
   var lost=new {trackId="1",title="Lost Track",path="C:\\old\\Lost Track.wav",candidates=new[]{"C:\\new\\Lost Track.wav"},relocatedTo=relocate?"C:\\new\\Lost Track.wav":null};
   File.WriteAllText(report,json.Serialize(new {ok=true,missing=1,relocated=relocate?1:0,tracks=new[]{lost}})); return 0;
  }
  if(args[0]=="--write-tags") {
   // Records each request and appends fixed bytes, as a real tag write changes the file.
   var updates=json.Deserialize<List<Dictionary<string,object>>>(File.ReadAllText(args[1]));
   foreach(var update in updates) {
    File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"tag-writes.log"),json.Serialize(update)+"\n");
    using(var stream=new FileStream((string)update["path"],FileMode.Append)) stream.Write(new byte[]{84,65,71,83},0,4);
   }
   File.WriteAllText(report,json.Serialize(new {ok=true,written=updates.Count,errors=new string[0]})); return 0;
  }
  var paths=new List<string>(args); bool analyze=paths.Remove("--analyze"); paths.Remove("--reanalyze");
  int bpmAt=paths.IndexOf("--analyze-bpm"); if(bpmAt>=0) { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"bpm-range.txt"),paths[bpmAt+1]); paths.RemoveRange(bpmAt,2); }
  var tracks=new List<object>(); var analysis=new List<object>();
  for(int i=0;i<paths.Count-2;i+=2) { tracks.Add(new {id="fixture",path=paths[i+1]}); if(analyze) analysis.Add(new {trackId="fixture",title=Path.GetFileName(paths[i+1]),ok=!paths[i+1].Contains("undecodable"),error="Fixture decode failure"}); }
  File.WriteAllText(report,json.Serialize(new {ok=true,report=new {imported=tracks.Count,tracks=tracks,existing=new object[0],skipped=new string[0]},analysis=analysis})); return 0;
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
Assert (Test-Path -LiteralPath (Join-Path $music 'Unknown Artist\Dub Plates\missing-tags.wav')) 'Missing tags did not get the default album.'
Assert ((Get-Content -LiteralPath (Join-Path $app 'tag-writes.log') -Raw) -like '*"album":"Dub Plates"*') 'Default album was not written into the copy.'
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
$result=Invoke-MusicLibraryImport $exe @(Get-MusicPending $queue) $music $reports -Analyze -BpmRange '90-180'
Assert ($result.imported -eq $before) 'Import omitted tracks.'
Assert (@($result.analysis | Where-Object {$_.ok}).Count -eq $before) 'Analysis results were not reported.'
Assert ((Read-MusicSettings $configPath).analyze -eq $true) 'Analysis is not on by default.'
Assert ((Get-Content -LiteralPath (Join-Path $app 'bpm-range.txt') -Raw) -eq '90-180') 'BPM range was not passed to the app.'
Assert ((Read-MusicSettings $configPath).bpmRange -eq '70-180') 'Default BPM range differs.'
Assert (-not (Test-MusicBpmRange '180-90') -and -not (Test-MusicBpmRange '20-400') -and (Test-MusicBpmRange '90 - 180')) 'BPM range validation failed.'
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
$none=[pscustomobject]@{artist='';albumArtist='';album='';title='';trackNumber=0}
$named=Get-MusicNameTags 'x\01. Blosso - Radio.wav' 'Blosso - Blosso (2026)\01. Blosso - Radio.wav' ([pscustomobject]@{artist='';albumArtist='';album='';title='01. Blosso - Radio';trackNumber=0}) $config
Assert ($named.artist -eq 'Blosso' -and $named.title -eq 'Radio' -and $named.trackNumber -eq 1 -and $named.album -eq 'Blosso' -and $named.albumArtist -eq 'Blosso' -and $named.year -eq 2026) 'Filename and folder tags failed.'
$loose=Get-MusicNameTags 'x\immix- back 2 basics.wav' 'UNSIGNED DUBS\immix- back 2 basics.wav' $none $config
Assert ($loose.artist -eq 'immix' -and $loose.title -eq 'back 2 basics' -and $loose.album -eq 'UNSIGNED DUBS') 'Loose separator failed.'
$hyphen=Get-MusicNameTags 'x\Jay-Z - Encore.wav' 'Jay-Z - Encore.wav' $none $config
Assert ($hyphen.artist -eq 'Jay-Z' -and $hyphen.title -eq 'Encore' -and $hyphen.album -eq 'Dub Plates') 'Hyphenated artist or default album failed.'
$kept=Get-MusicNameTags 'x\Champion Dub FINAL.wav' 'Champion Dub FINAL.wav' ([pscustomobject]@{artist='AND2';albumArtist='';album='';title='Champion Dub';trackNumber=0}) $config
Assert (-not $kept.Contains('artist') -and -not $kept.Contains('title') -and $kept.album -eq 'Dub Plates') 'Existing tags were replaced.'
$config | Add-Member -NotePropertyName artistNames -NotePropertyValue @('IMMIX') -Force
$cased=Get-MusicNameTags 'x\immix - 5am.mp3' 'UNSIGNED DUBS\immix - 5am.mp3' $none $config
Assert ($cased.artist -ceq 'IMMIX' -and $cased.title -eq '5am') 'Artist spelling not applied to a parsed name.'
$within=Get-MusicNameTags 'x\greentea peng whatchu mean immix bootleg.wav' 'UNSIGNED DUBS\greentea peng whatchu mean immix bootleg.wav' $none $config
Assert ($within.artist -ceq 'IMMIX') 'Listed artist named in the file name not used.'
$recase=Get-MusicNameTags 'x\a.wav' 'a.wav' ([pscustomobject]@{artist='immix';albumArtist='';album='Kept';title='a';trackNumber=0}) $config
Assert ($recase.artist -ceq 'IMMIX' -and -not $recase.Contains('album')) 'Existing tag was not respelled.'
$partial=Get-MusicNameTags 'x\immixed feelings.wav' 'immixed feelings.wav' $none $config
Assert (-not $partial.Contains('artist')) 'Artist matched inside another word.'
$config.artistNames=@()
try { Assert-MusicPattern '%artist% - %bogus%'; throw 'Unknown field accepted.' } catch { Assert ($_.Exception.Message -like '*Unknown field*') 'Unknown pattern field not reported.' }
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
$picked=Join-Path $root 'Picked'; New-Item -ItemType Directory -Path $picked | Out-Null
$pickedTrack=Audio (Join-Path $picked 'picked.wav'); $notPicked=Audio (Join-Path $other 'not-picked.wav')
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Music-To-Rekordbox.ps1') -NoPause -Source $picked
Assert ($LASTEXITCODE -eq 0) "Unexpected exit for a picked folder: $LASTEXITCODE"
Assert (-not (Test-Path -LiteralPath $pickedTrack)) 'Picked folder was not imported.'
Assert (Test-Path -LiteralPath $notPicked) 'Saved inbox processed during a picked-folder run.'
Assert (@((Read-MusicSettings $configPath).sources) -notcontains $picked) 'Picked folder replaced saved settings.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Music-To-Rekordbox.ps1') -NoPause -Source $music
Assert ($LASTEXITCODE -eq 1) 'Picking the music library folder as a source was accepted.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Music-To-Rekordbox.ps1') -NoPause -CheckMissing
$missingArgs=Get-Content -LiteralPath (Join-Path $app 'missing-args.txt') -Raw
Assert ($missingArgs -like ('--find-missing|' + $music + '|*--missing-report|*')) "Missing-file search folders differ: $missingArgs"
$missingLog=Get-Content -LiteralPath (Join-Path $package 'Music-Import.log') -Raw
if(Get-Process | Where-Object {$_.ProcessName -match '^(rekordbox|rekordboxagent|rbxport)$'}) {
 Assert ($LASTEXITCODE -eq 1 -and $missingArgs -notlike '*--relocate*' -and $missingLog -like '*Found Lost Track at*') 'Missing-file report without relocation failed.'
} else {
 Assert ($LASTEXITCODE -eq 0 -and $missingArgs -like '*--relocate*' -and $missingLog -like '*Relocated: Lost Track*') 'Missing-file relocation failed.'
}
& (Join-Path $package 'Create-Desktop-Shortcut.ps1') -DesktopDirectory $desktop
$link=@(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk')[0]
$ascii=Join-Path $desktop 'inspect.lnk';Copy-Item -LiteralPath $link.FullName -Destination $ascii
$shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($ascii)
Assert ($shortcut.Arguments -like '*-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden*Music-Import-GUI.ps1*') 'Shortcut arguments differ.'
Assert ($shortcut.Arguments -notlike '*Watch*') 'Watch enabled.'
Write-Output 'Universal music fixtures passed: ZIP, standalone, tags, collisions, extras, copy/move, retry, layouts, offline storage, shortcut.'
exit 0
