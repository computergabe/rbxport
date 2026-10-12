param(
    [string]$SourceFolder = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\Bandcamp'),
    [string]$DestinationFolder = (Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Rekordbox Collection'),
    [scriptblock]$OnVerifiedAlbum
)
$ErrorActionPreference = 'Stop'
$StagingFolder     = Join-Path $DestinationFolder "_staging"
$LogFile           = Join-Path $DestinationFolder "Bandcamp-Import.log"

# ------------------------------------------------------------
# Create folders if necessary
# ------------------------------------------------------------

New-Item -ItemType Directory -Path $SourceFolder -Force | Out-Null
New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
New-Item -ItemType Directory -Path $StagingFolder -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Log {
    param(
        [string]$Message
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Timestamp] $Message"

    Write-Host $Line
    Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
}

function Wait-ForFileReady {
    param(
        [string]$Path
    )

    # This prevents us from trying to process a ZIP
    # while the browser is still downloading/writing it.

    for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
        try {
            $Stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None
            )

            $Stream.Close()
            return $true
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

function Get-ArchiveFileList {
    param(
        [string]$ZipPath
    )

    $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    try {
        $Files = @()
        $Seen = @{}
        $ArchiveRoot = [System.IO.Path]::GetFullPath($StagingFolder).TrimEnd('\') + '\'

        foreach ($Entry in $Archive.Entries) {

            # Directory entries have an empty Name.
            if ([string]::IsNullOrWhiteSpace($Entry.Name)) {
                continue
            }

            $RelativePath = $Entry.FullName.Replace(
                    '/',
                    [System.IO.Path]::DirectorySeparatorChar
                )
            $EntryPath = [System.IO.Path]::GetFullPath((Join-Path $ArchiveRoot $RelativePath))
            if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':') -or
                -not $EntryPath.StartsWith($ArchiveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe path detected inside ZIP: $RelativePath"
            }
            if ($Seen.ContainsKey($EntryPath)) { throw "Duplicate file path inside ZIP: $RelativePath" }
            $Seen[$EntryPath] = $true
            $Files += [PSCustomObject]@{
                RelativePath = $RelativePath
                Length = $Entry.Length
            }
        }

        return $Files
    }
    finally {
        $Archive.Dispose()
    }
}

function Test-ExtractedFiles {
    param(
        [string]$RootFolder,
        [array]$ExpectedFiles
    )

    $RootFullPath = [System.IO.Path]::GetFullPath($RootFolder)
    $RootPrefix = $RootFullPath.TrimEnd('\') + '\'

    foreach ($Expected in $ExpectedFiles) {

        $FilePath = Join-Path $RootFolder $Expected.RelativePath
        $FullPath = [System.IO.Path]::GetFullPath($FilePath)

        # Protect against malicious/broken ZIP paths such as ../../file
        if (-not $FullPath.StartsWith(
            $RootPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Unsafe path detected inside ZIP: $($Expected.RelativePath)"
        }

        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
            Write-Log "VERIFY FAILED - Missing: $($Expected.RelativePath)"
            return $false
        }

        $ActualFile = Get-Item -LiteralPath $FullPath

        if ($ActualFile.Length -ne $Expected.Length) {
            Write-Log "VERIFY FAILED - Size mismatch: $($Expected.RelativePath)"
            return $false
        }
    }

    return $true
}

function Process-Zip {
    param(
        [System.IO.FileInfo]$Zip
    )

    Write-Log "Found ZIP: $($Zip.Name)"

    if (-not (Wait-ForFileReady -Path $Zip.FullName)) {
        Write-Log "SKIPPED - File never became ready: $($Zip.Name)"
        return
    }

    $FolderName = [System.IO.Path]::GetFileNameWithoutExtension($Zip.Name)
    $FinalFolder = Join-Path $DestinationFolder $FolderName

    # Do not overwrite existing music.
    if (Test-Path -LiteralPath $FinalFolder) {
        Write-Log "SKIPPED - Destination already exists: $FinalFolder"
        Write-Log "ZIP retained for manual review: $($Zip.Name)"
        return
    }

    $TempFolder = Join-Path $StagingFolder ([Guid]::NewGuid().ToString())

    try {
        New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null

        Write-Log "Reading ZIP directory..."
        $ExpectedFiles = @(Get-ArchiveFileList -ZipPath $Zip.FullName)

        if ($ExpectedFiles.Count -eq 0) {
            throw "ZIP contains no files."
        }

        Write-Log "Extracting $($ExpectedFiles.Count) files..."

        Expand-Archive `
            -LiteralPath $Zip.FullName `
            -DestinationPath $TempFolder `
            -Force

        Write-Log "Verifying staging extraction..."

        if (-not (Test-ExtractedFiles `
            -RootFolder $TempFolder `
            -ExpectedFiles $ExpectedFiles)) {

            throw "Staging verification failed."
        }

        Write-Log "Staging verification PASSED."

        Write-Log "Moving into Rekordbox Collection..."

        $TempFull = [System.IO.Path]::GetFullPath($TempFolder)
        $StagingPrefix = [System.IO.Path]::GetFullPath($StagingFolder).TrimEnd('\') + '\'
        $FinalFull = [System.IO.Path]::GetFullPath($FinalFolder)
        $DestinationPrefix = [System.IO.Path]::GetFullPath($DestinationFolder).TrimEnd('\') + '\'
        if (-not $TempFull.StartsWith($StagingPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $FinalFull.StartsWith($DestinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Extraction folders are outside their intended roots.'
        }

        Move-Item `
            -LiteralPath $TempFolder `
            -Destination $FinalFolder

        Write-Log "Verifying final destination..."

        if (-not (Test-ExtractedFiles `
            -RootFolder $FinalFolder `
            -ExpectedFiles $ExpectedFiles)) {

            throw "Final destination verification failed."
        }

        Write-Log "Final verification PASSED."

        # Persist the verified album before deleting the source ZIP.
        if ($OnVerifiedAlbum) { & $OnVerifiedAlbum $FinalFolder }

        # Only delete ZIP after both verifications succeed.
        Remove-Item -LiteralPath $Zip.FullName -Force

        Write-Log "SUCCESS - ZIP deleted: $($Zip.Name)"
        Write-Log "Music stored at: $FinalFolder"
    }
    catch {
        Write-Log "ERROR processing $($Zip.Name): $($_.Exception.Message)"
        Write-Log "ZIP HAS NOT BEEN DELETED."

        # Retain failed staging data for inspection along with the original ZIP.
        if (Test-Path -LiteralPath $TempFolder) { Write-Log "Staging retained for review: $TempFolder" }
    }
}

function Process-AllZips {

    $Zips = Get-ChildItem `
        -LiteralPath $SourceFolder `
        -Filter "*.zip" `
        -File `
        -ErrorAction SilentlyContinue

    foreach ($Zip in $Zips) {
        Process-Zip -Zip $Zip
    }
}

# ============================================================
# RUN
# ============================================================

Write-Log "============================================================"
Write-Log "Bandcamp -> Rekordbox processor started."
Write-Log "Source:      $SourceFolder"
Write-Log "Destination: $DestinationFolder"

Process-AllZips

Write-Log "Processing complete."
