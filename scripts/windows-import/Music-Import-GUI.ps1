param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Music-Import.config.json'),
    [string]$Executable = (Join-Path $PSScriptRoot 'RBXPORT-Music\rbxport.exe')
)
# Window for Music-To-Rekordbox.ps1: edit the saved settings, run an import, and show its output.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot 'Music-Import.Core.psm1') -Force -DisableNameChecking
[System.Windows.Forms.Application]::EnableVisualStyles()

$launcher = Join-Path $PSScriptRoot 'Music-To-Rekordbox.ps1'
$layouts = [ordered]@{ArtistAlbum='Artist \ Album \ Track'; PreserveFolders='Keep inbox and ZIP folders'; Flat='All files in one folder'}
$originals = [ordered]@{Copy='Copy - keep the downloads'; Move='Move - delete downloads after verifying'}
$artists = [ordered]@{AlbumArtist='Album artist'; TrackArtist='Track artist'}
$script:dirty = $false
$script:run = $null

function New-Combo($Choices) {
    $combo = New-Object System.Windows.Forms.ComboBox -Property @{DropDownStyle='DropDownList'; Dock='Fill'}
    foreach ($label in $Choices.Values) { [void]$combo.Items.Add($label) }
    $combo.SelectedIndex = 0
    $combo
}
function Set-Combo($Combo, $Choices, [string]$Key) { $Combo.SelectedIndex = [Math]::Max(0, @($Choices.Keys).IndexOf($Key)) }
function Get-Combo($Combo, $Choices) { @($Choices.Keys)[$Combo.SelectedIndex] }
function Show-Problem([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($form, $Message, 'Music to Rekordbox', 'OK', 'Warning')
}

$form = New-Object System.Windows.Forms.Form -Property @{
    Text = 'Music ' + [char]0x2192 + ' Rekordbox'; Size = New-Object System.Drawing.Size(760, 640)
    MinimumSize = New-Object System.Drawing.Size(620, 520); StartPosition = 'CenterScreen'
    Font = New-Object System.Drawing.Font('Segoe UI', 9); AutoScaleMode = 'Dpi'
}
$icon = Join-Path $PSScriptRoot 'Music-Rekordbox.ico'
if (Test-Path -LiteralPath $icon) { $form.Icon = New-Object System.Drawing.Icon($icon) }

$grid = New-Object System.Windows.Forms.TableLayoutPanel -Property @{Dock='Fill'; ColumnCount=3; Padding=(New-Object System.Windows.Forms.Padding(12))}
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
$form.Controls.Add($grid)
function Add-Row([string]$Label, $Control, $Button, [string]$Height = 'AutoSize') {
    $row = $grid.RowCount++
    [void]$grid.RowStyles.Add($(if ($Height -eq 'AutoSize') { New-Object System.Windows.Forms.RowStyle('AutoSize') } else { New-Object System.Windows.Forms.RowStyle('Percent', [single]$Height) }))
    if ($Label) { $grid.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text=$Label; AutoSize=$true; Anchor='Left'; Margin=(New-Object System.Windows.Forms.Padding(0,6,8,0))}), 0, $row) }
    if ($Control) { $grid.Controls.Add($Control, 1, $row); if (-not $Label -and -not $Button) { $grid.SetColumnSpan($Control, 3); $grid.SetColumn($Control, 0) } }
    if ($Button) { $grid.Controls.Add($Button, 2, $row) }
}
function New-Button([string]$Text) { New-Object System.Windows.Forms.Button -Property @{Text=$Text; AutoSize=$true; Anchor='Top,Left'; MinimumSize=(New-Object System.Drawing.Size(90,0))} }

$inboxes = New-Object System.Windows.Forms.ListBox -Property @{Dock='Fill'; Height=58; IntegralHeight=$false; HorizontalScrollbar=$true}
$inboxButtons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{AutoSize=$true; FlowDirection='TopDown'; Margin=(New-Object System.Windows.Forms.Padding(0))}
$addInbox = New-Button 'Add...'; $removeInbox = New-Button 'Remove'
$inboxButtons.Controls.AddRange(@($addInbox, $removeInbox))
Add-Row 'Inbox folders' $inboxes $inboxButtons
$library = New-Object System.Windows.Forms.TextBox -Property @{Dock='Fill'; ReadOnly=$true}
$browseLibrary = New-Button 'Change...'
Add-Row 'Music library folder' $library $browseLibrary
$layout = New-Combo $layouts; Add-Row 'Arrange files as' $layout $null
$artist = New-Combo $artists; Add-Row 'Artist folder from' $artist $null
$original = New-Combo $originals; Add-Row 'Downloads' $original $null
$options = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{AutoSize=$true; Dock='Fill'; Margin=(New-Object System.Windows.Forms.Padding(0))}
$recursive = New-Object System.Windows.Forms.CheckBox -Property @{Text='Include inbox subfolders'; AutoSize=$true}
$register = New-Object System.Windows.Forms.CheckBox -Property @{Text='Add tracks to the rekordbox library'; AutoSize=$true; Checked=$true}
$analyze = New-Object System.Windows.Forms.CheckBox -Property @{Text='Analyze them (RBXport Electronic Music)'; AutoSize=$true; Checked=$true}
$options.Controls.AddRange(@($recursive, $register, $analyze))
Add-Row '' $options $null

$actions = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{AutoSize=$true; Dock='Fill'; Margin=(New-Object System.Windows.Forms.Padding(0,10,0,6))}
$importInbox = New-Object System.Windows.Forms.Button -Property @{Text='Import from inbox'; AutoSize=$true; Font=(New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)); Padding=(New-Object System.Windows.Forms.Padding(8,2,8,2))}
$importFolder = New-Object System.Windows.Forms.Button -Property @{Text='Import a folder...'; AutoSize=$true; Padding=(New-Object System.Windows.Forms.Padding(8,2,8,2))}
$openLibrary = New-Object System.Windows.Forms.LinkLabel -Property @{Text='Open music library folder'; AutoSize=$true; Margin=(New-Object System.Windows.Forms.Padding(16,9,0,0))}
$openReports = New-Object System.Windows.Forms.LinkLabel -Property @{Text='Reports'; AutoSize=$true; Margin=(New-Object System.Windows.Forms.Padding(12,9,0,0))}
$actions.Controls.AddRange(@($importInbox, $importFolder, $openLibrary, $openReports))
Add-Row '' $actions $null
$progress = New-Object System.Windows.Forms.ProgressBar -Property @{Dock='Fill'; Style='Marquee'; MarqueeAnimationSpeed=0; Height=6}
Add-Row '' $progress $null
$output = New-Object System.Windows.Forms.TextBox -Property @{Dock='Fill'; Multiline=$true; ReadOnly=$true; ScrollBars='Both'; WordWrap=$false; Font=(New-Object System.Drawing.Font('Consolas', 9)); BackColor=[System.Drawing.SystemColors]::Window}
Add-Row '' $output $null '100'
$status = New-Object System.Windows.Forms.Label -Property @{AutoSize=$true; Dock='Fill'; Font=(New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)); Margin=(New-Object System.Windows.Forms.Padding(0,6,0,0))}
Add-Row '' $status $null

$settingControls = @($inboxes, $addInbox, $removeInbox, $browseLibrary, $layout, $artist, $original, $recursive, $register, $analyze, $importInbox, $importFolder)
function Set-Status([string]$Text, [string]$Color = 'ControlText') { $status.Text = $Text; $status.ForeColor = [System.Drawing.Color]::FromName($Color) }

# Load saved settings; a first run starts from defaults and saves on the first import.
$firstRun = -not (Test-Path -LiteralPath $ConfigPath)
if ($firstRun) {
    $library.Text = Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Rekordbox Music'
    Set-Status 'Add an inbox folder and choose your music library folder, then import.'
} else {
    try {
        $saved = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($path in @($saved.sources)) { [void]$inboxes.Items.Add([string]$path) }
        $library.Text = [string]$saved.musicRoot
        Set-Combo $layout $layouts $saved.layout; Set-Combo $artist $artists $saved.artistFolder; Set-Combo $original $originals $saved.originals
        $recursive.Checked = [bool]$saved.recursive; $register.Checked = [bool]$saved.importToRekordbox
        $analyze.Checked = -not ($saved.PSObject.Properties['analyze'] -and -not $saved.analyze)
        Set-Status 'Ready. Close rekordbox before importing.'
    } catch { Set-Status ('Saved settings could not be read: ' + $_.Exception.Message) 'Firebrick' }
}

function Save-Settings {
    # Setup-Music-Import.ps1 validates and writes the configuration, as the console setup does.
    $arguments = @{
        ConfigPath=$ConfigPath; Sources=@($inboxes.Items | ForEach-Object {[string]$_}); MusicRoot=$library.Text
        Layout=(Get-Combo $layout $layouts); Originals=(Get-Combo $original $originals); ArtistFolder=(Get-Combo $artist $artists)
        Recursive=$recursive.Checked; OrganizeOnly=(-not $register.Checked); SkipAnalysis=(-not $analyze.Checked); NonInteractive=$true; NoShortcut=$true
    }
    & (Join-Path $PSScriptRoot 'Setup-Music-Import.ps1') @arguments *> $null
    $script:dirty = $false
    if ($script:firstRun) {
        $script:firstRun = $false
        try { & (Join-Path $PSScriptRoot 'Create-Desktop-Shortcut.ps1') -ConfigPath $ConfigPath | Out-Null } catch {}
    }
}
$markDirty = { $script:dirty = $true }
foreach ($combo in @($layout, $artist, $original)) { $combo.add_SelectedIndexChanged($markDirty) }
foreach ($box in @($recursive, $register, $analyze)) { $box.add_CheckedChanged($markDirty) }
# Analysis happens while registering, so it needs the library import.
$register.add_CheckedChanged({ $analyze.Visible = $register.Checked })
$analyze.Visible = $register.Checked

$addInbox.add_Click({
    $start = if ($inboxes.Items.Count) { [string]$inboxes.Items[0] } else { Join-Path $env:USERPROFILE 'Downloads' }
    $path = Select-MusicFolder 'Choose a folder where your music downloads (ZIPs or audio files) land.' $start
    if ($path -and -not $inboxes.Items.Contains($path)) { [void]$inboxes.Items.Add($path); $script:dirty = $true }
})
$removeInbox.add_Click({ if ($inboxes.SelectedIndex -ge 0) { $inboxes.Items.RemoveAt($inboxes.SelectedIndex); $script:dirty = $true } })
$browseLibrary.add_Click({
    $path = Select-MusicFolder 'Choose your music library folder - where your music is kept and rekordbox plays it from.' $library.Text
    if ($path) { $library.Text = $path; $script:dirty = $true }
})
$openLibrary.add_LinkClicked({ if (Test-Path -LiteralPath $library.Text -PathType Container) { Start-Process explorer.exe -ArgumentList ('"' + $library.Text + '"') } })
$openReports.add_LinkClicked({
    $reports = Join-Path $PSScriptRoot 'reports'
    if (Test-Path -LiteralPath $reports -PathType Container) { Start-Process explorer.exe -ArgumentList ('"' + $reports + '"') }
})

function Start-Import([string]$Source) {
    if ($inboxes.Items.Count -eq 0) { Show-Problem 'Add at least one inbox folder first.'; return }
    if ($register.Checked -and (Get-Process | Where-Object { $_.ProcessName -match '^(rekordbox|rekordboxagent|rbxport)$' })) {
        Show-Problem 'Close rekordbox, its tray agent, and RBXPORT first, then import again.'; return
    }
    try { if ($script:dirty -or $script:firstRun) { Save-Settings } } catch { Show-Problem ('Settings were not saved: ' + $_.Exception.Message); return }
    $quote = { "'" + ([string]$args[0]).Replace("'", "''") + "'" }
    $command = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; & ' + (& $quote $launcher) + ' -NoPause -ConfigPath ' + (& $quote $ConfigPath) + ' -Executable ' + (& $quote $Executable)
    if ($Source) { $command += ' -Source ' + (& $quote $Source) }
    $command += '; exit $LASTEXITCODE'
    $out = [System.IO.Path]::GetTempFileName(); $err = [System.IO.Path]::GetTempFileName()
    $process = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"' + $command + '"')) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $null = $process.Handle  # keeps ExitCode readable after the process ends
    $stream = New-Object System.IO.FileStream($out, 'Open', 'Read', 'ReadWrite,Delete')
    $script:run = @{process=$process; reader=(New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)); out=$out; err=$err}
    $output.Clear()
    foreach ($control in $settingControls) { $control.Enabled = $false }
    $progress.MarqueeAnimationSpeed = 30
    Set-Status 'Importing...'
    $timer.Start()
}
# The child writes bare LF line endings; the text box needs CRLF.
function Add-Output([string]$Text) {
    if (-not $Text) { return }
    $lines = ($Text -replace "`r", '') -replace "`n", "`r`n"
    $output.AppendText($lines)
}
function Complete-Import {
    $run = $script:run
    Add-Output $run.reader.ReadToEnd()
    $run.reader.Dispose()
    $problems = (Get-Content -LiteralPath $run.err -Raw -ErrorAction SilentlyContinue)
    if ($problems) { Add-Output ("`n" + $problems) }
    Remove-Item -LiteralPath $run.out, $run.err -ErrorAction SilentlyContinue
    $script:run = $null
    $progress.MarqueeAnimationSpeed = 0
    foreach ($control in $settingControls) { $control.Enabled = $true }
    if ($run.process.ExitCode -ne 0) { Set-Status 'Finished, but some items need attention. See the messages above.' 'DarkOrange' }
    elseif ($register.Checked) { Set-Status 'Finished. Open rekordbox to see the new tracks.' 'ForestGreen' }
    else { Set-Status 'Finished. Music is organized in your library folder.' 'ForestGreen' }
}
$timer = New-Object System.Windows.Forms.Timer -Property @{Interval=250}
$timer.add_Tick({
    if (-not $script:run) { $timer.Stop(); return }
    $exited = $script:run.process.HasExited
    Add-Output $script:run.reader.ReadToEnd()
    if ($exited) { $timer.Stop(); Complete-Import }
})
$importInbox.add_Click({ Start-Import $null })
$importFolder.add_Click({
    $start = if ($inboxes.Items.Count) { [string]$inboxes.Items[0] } else { Join-Path $env:USERPROFILE 'Downloads' }
    $path = Select-MusicFolder 'Choose a folder with ZIP or audio files to import into rekordbox.' $start
    if ($path) { Start-Import $path }
})
$form.add_FormClosing({
    param($sender, $e)
    if ($script:run) { $e.Cancel = $true; Show-Problem 'An import is still running. Wait for it to finish before closing.'; return }
    if ($script:dirty -and $inboxes.Items.Count) { try { Save-Settings } catch { Show-Problem ('Settings were not saved: ' + $_.Exception.Message) } }
})
$form.add_Shown({ $importInbox.Focus() })
[void]$form.ShowDialog()
$form.Dispose()
