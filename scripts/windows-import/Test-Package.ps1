param([Parameter(Mandatory=$true)][string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run this fixture check with Windows PowerShell 5.' }
if (Test-Path -LiteralPath $FixtureRoot) { throw 'Choose a new fixture directory.' }
$root = [System.IO.Path]::GetFullPath($FixtureRoot)
$inbox = Join-Path $root 'Inbox'
$music = Join-Path $root 'Music Collection'
$desktop = Join-Path $root 'Desktop'
$appFolder = Join-Path $root 'RBXPORT-Bandcamp'
foreach ($path in @($root,$inbox,$music,$desktop,$appFolder)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
foreach ($name in @('Bandcamp-Rekordbox.ps1','Bandcamp-Rekordbox-Launcher.ps1','Bandcamp-Rekordbox-Queue.psm1','Create-Desktop-Shortcut.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $root
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors.Message -join '; ') }
}
$mock = @'
using System;
using System.IO;
using System.Web.Script.Serialization;
class MockImport {
  static int Main(string[] args) {
    string album=args[1], report=args[3], root=AppDomain.CurrentDomain.BaseDirectory;
    var json=new JavaScriptSerializer();
    if (album.Contains("refuse") && !File.Exists(Path.Combine(root,"allow"))) {
      File.WriteAllText(report,json.Serialize(new {ok=false,error="Fixture refusal"})); return 1;
    }
    File.WriteAllText(report,json.Serialize(new {ok=true,report=new {
      imported=1,tracks=new object[]{new {id="fixture"}},existing=new object[0],skipped=new string[0]
    }})); return 0;
  }
}
'@
Add-Type -TypeDefinition $mock -ReferencedAssemblies 'System.Web.Extensions' -OutputAssembly (Join-Path $appFolder 'rbxport.exe') -OutputType ConsoleApplication
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function MakeZip($name) {
    $payload = Join-Path $root ('payload-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $payload | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $payload 'track.wav'),[byte[]](0..255))
    $zip = Join-Path $inbox ($name + '.zip')
    Compress-Archive -LiteralPath (Join-Path $payload 'track.wav') -DestinationPath $zip
    $zip
}
function RunLauncher($expected) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Bandcamp-Rekordbox-Launcher.ps1') -Inbox $inbox -CollectionRoot $music -NoPause
    Assert ($LASTEXITCODE -eq $expected) "Unexpected launcher exit status: $LASTEXITCODE"
}
$queue = Join-Path $root 'Bandcamp-Rekordbox.pending.json'
$album = 'Public album ' + [char]0x2014 + ' ' + [char]0x65B0
$zip = MakeZip $album
RunLauncher 0
Assert (-not (Test-Path -LiteralPath $zip)) 'Verified ZIP was retained.'
Assert ((Get-Item -LiteralPath (Join-Path $music ($album + '\track.wav'))).Length -eq 256) 'Custom-folder extraction differs.'
Assert (@((Get-Content -LiteralPath $queue -Raw -Encoding UTF8 | ConvertFrom-Json).albums).Count -eq 0) 'Completed album remains queued.'
$zip = MakeZip 'refuse album'
RunLauncher 1
Assert (-not (Test-Path -LiteralPath $zip)) 'Verified ZIP was retained after library refusal.'
Assert (@((Get-Content -LiteralPath $queue -Raw -Encoding UTF8 | ConvertFrom-Json).albums).Count -eq 1) 'Refused album was lost.'
New-Item -ItemType File -Path (Join-Path $appFolder 'allow') | Out-Null
RunLauncher 0
Assert (@((Get-Content -LiteralPath $queue -Raw -Encoding UTF8 | ConvertFrom-Json).albums).Count -eq 0) 'Retry did not clear the queue.'
$bad = Join-Path $inbox 'corrupt.zip'
[System.IO.File]::WriteAllText($bad,'not a ZIP')
RunLauncher 1
Assert (Test-Path -LiteralPath $bad) 'Corrupt ZIP was deleted.'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function MakeRawZip($name, [string[]]$entries) {
    $path = Join-Path $inbox ($name + '.zip')
    $archive = [System.IO.Compression.ZipFile]::Open($path,[System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $entries) {
            $stream = $archive.CreateEntry($entry).Open()
            try { $stream.WriteByte(7) } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    $path
}
$unsafe = MakeRawZip 'unsafe' @('../escape.wav')
$duplicate = MakeRawZip 'duplicate' @('track.wav','TRACK.wav')
RunLauncher 1
Assert (Test-Path -LiteralPath $unsafe) 'Unsafe ZIP was deleted.'
Assert (Test-Path -LiteralPath $duplicate) 'Duplicate-path ZIP was deleted.'
Assert (-not (Test-Path -LiteralPath (Join-Path $music '_staging\escape.wav'))) 'Unsafe ZIP escaped its staging folder.'
$callbackInbox = Join-Path $root 'Callback Inbox'
$callbackMusic = Join-Path $root 'Callback Music'
New-Item -ItemType Directory -Path $callbackInbox | Out-Null
$callbackZip = MakeZip 'callback failure'
Move-Item -LiteralPath $callbackZip -Destination $callbackInbox
& (Join-Path $root 'Bandcamp-Rekordbox.ps1') -SourceFolder $callbackInbox -DestinationFolder $callbackMusic -OnVerifiedAlbum { throw 'Fixture queue persistence failure' }
Assert (Test-Path -LiteralPath (Join-Path $callbackInbox 'callback failure.zip')) 'Callback failure deleted its ZIP.'
& (Join-Path $root 'Create-Desktop-Shortcut.ps1') -DesktopDirectory $desktop -Inbox $inbox -CollectionRoot $music
$shortcut = Get-ChildItem -LiteralPath $desktop -Filter '*.lnk'
Assert (@($shortcut).Count -eq 1) 'Shortcut was not created.'
$inspection = Join-Path $root 'inspect.lnk'
Copy-Item -LiteralPath $shortcut.FullName -Destination $inspection
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($inspection)
Assert ($link.Arguments.Contains('-Inbox "' + $inbox + '"')) 'Shortcut did not retain the custom inbox.'
Assert ($link.Arguments.Contains('-CollectionRoot "' + $music + '"')) 'Shortcut did not retain the custom collection.'
Assert (-not $link.Arguments.Contains('-Watch')) 'Shortcut enables watch mode.'
try {
    & (Join-Path $root 'Create-Desktop-Shortcut.ps1') -DesktopDirectory $desktop -Inbox $inbox -CollectionRoot $music
    throw 'Shortcut replacement unexpectedly succeeded.'
} catch { Assert ($_.Exception.Message -like 'A shortcut already exists:*') 'Unexpected shortcut replacement result.' }
Write-Output 'PASS: custom paths, Unicode extraction, verification, corrupt/unsafe/duplicate ZIP retention, callback failure, refusal/retry queue, desktop shortcut, and no replacement/watch mode.'
# CI's PowerShell wrapper otherwise reuses the intentional failed child status.
exit 0
