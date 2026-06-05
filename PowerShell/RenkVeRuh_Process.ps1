# =============================================================================
#  RenkVeRuh_Process.ps1
#
#  FOLDER STRUCTURE:
#    D:\RenkVeRuh\WhatsAppRAW\  -- dump all raw WhatsApp files here
#    D:\RenkVeRuh\Directory\    -- cleaned, renamed, indexed media (source of truth)
#    D:\RenkVeRuh\BlobMedia\    -- downloaded Azure Blob content (for comparison)
#    D:\RenkVeRuh\Manifest\     -- all logs, CSVs, reports (never media)
#    D:\RenkVeRuh\PowerShell\   -- this script
#
#  PHASE 0 -- Differential: compares Directory vs BlobMedia and reports
#             what needs uploading vs what is already in sync.
#             Uses SHA-256 checksum (with a persistent cache) for accurate
#             comparison -- SIZE_MISMATCH is replaced by CHECKSUM_MISMATCH.
#
#  PHASE 1 -- Snapshot: scans WhatsAppRAW and Directory, builds a manifest
#             of every file and what action is needed. Nothing is touched.
#
#  PHASE 2 -- Apply: copies new WhatsApp files from WhatsAppRAW into
#             Directory with correct sequential names, verifies each copy
#             with a post-copy checksum, generates .jpg thumbnails for any
#             .mp4 missing one. Already correct files in Directory are never
#             touched.
#
#  PHASE 3 -- Final differential: re-runs Directory vs BlobMedia after all
#             copies and thumbnail generation to produce the definitive
#             upload list. Uses checksums.
#
#  CHECKSUM CACHE (Manifest\RenkVeRuh_ChecksumDB.csv):
#    Stores SHA-256 hashes keyed by FileName+Size+LastWriteUtc.
#    Re-used across runs so unchanged files are never re-hashed.
# =============================================================================

$whatsappRaw  = "D:\RenkVeRuh\WhatsAppRAW"
$directory    = "D:\RenkVeRuh\Directory"
$blobMedia    = "D:\RenkVeRuh\BlobMedia"
$manifestDir  = "D:\RenkVeRuh\Manifest"
$timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runStamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$manifestFile = Join-Path $manifestDir "RenkVeRuh_Manifest_$runStamp.csv"
$diffFile     = Join-Path $manifestDir "RenkVeRuh_Diff_$runStamp.csv"
$logFile      = Join-Path $manifestDir "RenkVeRuh_Log_$runStamp.txt"
$checksumDB   = Join-Path $manifestDir "RenkVeRuh_ChecksumDB.csv"

# --- Ensure output folders exist ---
foreach ($folder in @($directory, $manifestDir)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

# --- Write-Log: console + log file ---
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $logFile -Value $Message
}

Write-Log ""
Write-Log "========================================" "Cyan"
Write-Log "  RenkVeRuh Media Processor" "Cyan"
Write-Log "  $timestamp" "Cyan"
Write-Log "========================================" "Cyan"
Write-Log "  WhatsAppRAW : $whatsappRaw" "Cyan"
Write-Log "  Directory   : $directory" "Cyan"
Write-Log "  BlobMedia   : $blobMedia" "Cyan"
Write-Log "  Manifest    : $manifestDir" "Cyan"
Write-Log ""

# --- Verify WhatsAppRAW exists ---
if (-not (Test-Path $whatsappRaw)) {
    Write-Log "ERROR: WhatsAppRAW folder not found: $whatsappRaw" "Red"
    pause; exit
}

# =============================================================================
# CHECKSUM CACHE
#   Persistent CSV in Manifest\RenkVeRuh_ChecksumDB.csv
#   Key = "FileName|SizeBytes|LastWriteUtcTicks"  Value = SHA-256 hex string
#   Avoids re-hashing files that have not changed since the last run.
# =============================================================================

# Load existing cache into a hashtable
$checksumCache = @{}
if (Test-Path $checksumDB) {
    try {
        Import-Csv -Path $checksumDB -Encoding UTF8 | ForEach-Object {
            if ($_.CacheKey -and $_.SHA256) {
                $checksumCache[$_.CacheKey] = $_.SHA256
            }
        }
        Write-Log ("  Checksum cache loaded: " + $checksumCache.Count + " entr(ies) from $checksumDB") "DarkGray"
    } catch {
        Write-Log "  WARNING: Could not load checksum cache -- starting fresh." "DarkYellow"
    }
} else {
    Write-Log "  Checksum cache not found -- will be created at $checksumDB" "DarkGray"
}
Write-Log ""

# Build a cache key for a FileInfo object
function Get-CacheKey {
    param([System.IO.FileInfo]$FileInfo)
    return ("{0}|{1}|{2}" -f $FileInfo.Name, $FileInfo.Length, $FileInfo.LastWriteTimeUtc.Ticks)
}

# Compute or retrieve SHA-256 for a file; updates the in-memory cache
function Get-FileChecksum {
    param([System.IO.FileInfo]$FileInfo)

    $key = Get-CacheKey -FileInfo $FileInfo
    if ($checksumCache.ContainsKey($key)) {
        return $checksumCache[$key]
    }

    try {
        $sha256  = [System.Security.Cryptography.SHA256]::Create()
        $stream  = [System.IO.File]::OpenRead($FileInfo.FullName)
        $hashBytes = $sha256.ComputeHash($stream)
        $stream.Close()
        $sha256.Dispose()
        $hex = [System.BitConverter]::ToString($hashBytes) -replace '-',''
        $checksumCache[$key] = $hex
        return $hex
    } catch {
        Write-Log ("  WARNING: Could not hash file: " + $FileInfo.FullName + " -- " + $_) "DarkYellow"
        return $null
    }
}

# Save the in-memory cache back to the CSV (full rewrite -- keeps it tidy)
function Save-ChecksumCache {
    try {
        $rows = $checksumCache.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{ CacheKey = $_.Key; SHA256 = $_.Value }
        }
        $rows | Export-Csv -Path $checksumDB -NoTypeInformation -Encoding UTF8
    } catch {
        Write-Log ("  WARNING: Could not save checksum cache: " + $_) "DarkYellow"
    }
}

# =============================================================================
# PHASE 0 -- DIFFERENTIAL: Directory vs BlobMedia
#            Reports what needs uploading. Uses SHA-256 checksums.
#            No files touched.
# =============================================================================
Write-Log "[ Phase 0 ] Differential analysis: Directory vs BlobMedia (checksum)..." "Cyan"
Write-Log ""

if (-not (Test-Path $blobMedia)) {
    Write-Log "  WARNING: BlobMedia folder not found: $blobMedia" "DarkYellow"
    Write-Log "  Skipping differential analysis." "DarkYellow"
    Write-Log ""
} else {
    $dirFiles  = Get-ChildItem -Path $directory -File |
        Where-Object { $_.Extension -match '^\.(mp4|jpg|jpeg)$' } | Sort-Object Name
    $blobFiles = Get-ChildItem -Path $blobMedia -File |
        Where-Object { $_.Extension -match '^\.(mp4|jpg|jpeg)$' } | Sort-Object Name

    $blobIndex = @{}
    foreach ($f in $blobFiles) { $blobIndex[$f.Name] = $f }
    $dirIndex = @{}
    foreach ($f in $dirFiles)  { $dirIndex[$f.Name]  = $f }

    $diffManifest = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Log "  Hashing Directory files for Phase 0..." "DarkGray"
    foreach ($f in $dirFiles) {
        $dirHash = Get-FileChecksum -FileInfo $f

        if ($blobIndex.ContainsKey($f.Name)) {
            $blobFile = $blobIndex[$f.Name]
            $blobHash = Get-FileChecksum -FileInfo $blobFile

            if ($dirHash -and $blobHash -and $dirHash -eq $blobHash) {
                $status = "IN_SYNC"
            } elseif ($f.Length -ne $blobFile.Length) {
                $status = "SIZE_MISMATCH"
            } else {
                # Same size but different content -- checksum catches silent corruption
                $status = "CHECKSUM_MISMATCH"
            }
        } else {
            $status  = "UPLOAD_NEEDED"
            $blobHash = "N/A"
        }

        $diffManifest.Add([PSCustomObject]@{
            FileName        = $f.Name
            Status          = $status
            DirectorySize   = $f.Length
            BlobSize        = if ($blobIndex.ContainsKey($f.Name)) { $blobIndex[$f.Name].Length } else { "N/A" }
            DirectorySHA256 = $dirHash
            BlobSHA256      = if ($blobIndex.ContainsKey($f.Name)) { (Get-FileChecksum -FileInfo $blobIndex[$f.Name]) } else { "N/A" }
            Extension       = $f.Extension
        })
    }

    foreach ($f in $blobFiles) {
        if (-not $dirIndex.ContainsKey($f.Name)) {
            $diffManifest.Add([PSCustomObject]@{
                FileName        = $f.Name
                Status          = "BLOB_ONLY"
                DirectorySize   = "N/A"
                BlobSize        = $f.Length
                DirectorySHA256 = "N/A"
                BlobSHA256      = (Get-FileChecksum -FileInfo $f)
                Extension       = $f.Extension
            })
        }
    }

    $diffManifest | Sort-Object Status, FileName | Export-Csv -Path $diffFile -NoTypeInformation -Encoding UTF8
    Save-ChecksumCache

    $inSync          = @($diffManifest | Where-Object { $_.Status -eq "IN_SYNC" })
    $uploadNeeded    = @($diffManifest | Where-Object { $_.Status -eq "UPLOAD_NEEDED" })
    $sizeMismatch    = @($diffManifest | Where-Object { $_.Status -eq "SIZE_MISMATCH" })
    $chksumMismatch  = @($diffManifest | Where-Object { $_.Status -eq "CHECKSUM_MISMATCH" })
    $blobOnly        = @($diffManifest | Where-Object { $_.Status -eq "BLOB_ONLY" })

    Write-Log "  Diff report saved: $diffFile" "Green"
    Write-Log ""
    Write-Log "  Differential Summary:" "White"
    Write-Log ("    In sync (skip upload)          : " + $inSync.Count) "DarkGray"
    Write-Log ("    Needs uploading                : " + $uploadNeeded.Count) "Yellow"
    Write-Log ("    Size mismatch (re-upload)      : " + $sizeMismatch.Count) "DarkYellow"
    Write-Log ("    Checksum mismatch (re-upload)  : " + $chksumMismatch.Count) "Red"
    Write-Log ("    Blob only (orphaned Azure)     : " + $blobOnly.Count) "Magenta"
    Write-Log ""

    if ($uploadNeeded.Count -gt 0) {
        Write-Log "  -- FILES TO UPLOAD --" "Yellow"
        foreach ($item in ($uploadNeeded | Sort-Object FileName)) {
            Write-Log ("    [UPLOAD]           " + $item.FileName) "Yellow"
        }
        Write-Log ""
    }

    if ($sizeMismatch.Count -gt 0) {
        Write-Log "  -- SIZE MISMATCH (re-upload recommended) --" "DarkYellow"
        foreach ($item in ($sizeMismatch | Sort-Object FileName)) {
            $localKB = [math]::Round($item.DirectorySize / 1KB, 1)
            $blobKB  = [math]::Round($item.BlobSize / 1KB, 1)
            Write-Log ("    [SIZE MISMATCH]    " + $item.FileName + "  local: " + $localKB + " KB  blob: " + $blobKB + " KB") "DarkYellow"
        }
        Write-Log ""
    }

    if ($chksumMismatch.Count -gt 0) {
        Write-Log "  -- CHECKSUM MISMATCH (same size, different content -- re-upload!) --" "Red"
        foreach ($item in ($chksumMismatch | Sort-Object FileName)) {
            Write-Log ("    [CHKSUM MISMATCH]  " + $item.FileName) "Red"
            Write-Log ("      Directory SHA256 : " + $item.DirectorySHA256) "DarkRed"
            Write-Log ("      Blob      SHA256 : " + $item.BlobSHA256) "DarkRed"
        }
        Write-Log ""
    }

    if ($blobOnly.Count -gt 0) {
        Write-Log "  -- BLOB ONLY (in Azure but not in Directory) --" "Magenta"
        foreach ($item in ($blobOnly | Sort-Object FileName)) {
            Write-Log ("    [BLOB ONLY]        " + $item.FileName) "Magenta"
        }
        Write-Log ""
    }

    if ($uploadNeeded.Count -eq 0 -and $sizeMismatch.Count -eq 0 -and $chksumMismatch.Count -eq 0) {
        Write-Log "  All Directory files are already in Azure Blob (checksum verified). Nothing to upload." "Green"
        Write-Log ""
    }
}

# =============================================================================
# PHASE 1 -- SNAPSHOT: scan WhatsAppRAW for new files, scan Directory for
#            existing correctly-named files. Build full manifest. No files touched.
# =============================================================================
Write-Log "[ Phase 1 ] Scanning WhatsAppRAW and Directory..." "Cyan"
Write-Log ""

# --- Files already in Directory (correctly named) ---
$existingMp4  = Get-ChildItem -Path "$directory\*.mp4"   -File | Sort-Object Name
$existingJpeg = Get-ChildItem -Path "$directory\*.jpeg"  -File | Sort-Object Name

# --- Raw incoming files from WhatsAppRAW ---
$rawMp4   = Get-ChildItem -Path "$whatsappRaw\*.mp4"   -File | Sort-Object LastWriteTime
$rawJpeg  = Get-ChildItem -Path "$whatsappRaw\*.jpeg"  -File | Sort-Object LastWriteTime

$manifest = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- Categorise existing Directory MP4 files ---
foreach ($f in $existingMp4) {
    $thumbPath    = Join-Path $directory "$($f.BaseName).jpg"
    $thumbExists  = Test-Path $thumbPath
    $thumbCurrent = $thumbExists -and ((Get-Item $thumbPath).LastWriteTime -ge $f.LastWriteTime)

    if ($f.Name -match '^Exhibit\d{3}\.mp4$') {
        $action = if ($thumbCurrent) { "OK_EXHIBIT" } else { "THUMB_NEEDED" }
    } elseif ($f.Name -match '^Video\d{3}\.mp4$') {
        $action = if ($thumbCurrent) { "OK" } else { "THUMB_NEEDED" }
    } else {
        $action = "UNKNOWN_MP4"
    }

    $manifest.Add([PSCustomObject]@{
        Source       = "DIRECTORY"
        FileName     = $f.Name
        FileType     = "MP4"
        Action       = $action
        ThumbExists  = $thumbExists
        ThumbCurrent = $thumbCurrent
        FullPath     = $f.FullName
        NewName      = ""
    })
}

# --- Categorise existing Directory JPEG files ---
foreach ($f in $existingJpeg) {
    $action = if ($f.Name -match '^Image\d{3}\.jpeg$') { "OK" } else { "UNKNOWN_JPEG" }
    $manifest.Add([PSCustomObject]@{
        Source       = "DIRECTORY"
        FileName     = $f.Name
        FileType     = "JPEG"
        Action       = $action
        ThumbExists  = "N/A"
        ThumbCurrent = "N/A"
        FullPath     = $f.FullName
        NewName      = ""
    })
}

# --- Categorise incoming WhatsAppRAW MP4 files ---
foreach ($f in $rawMp4) {
    if ($f.Name -match '^WhatsApp Video') {
        $action = "COPY_VIDEO"
    } elseif ($f.Name -match '^Exhibit') {
        $action = "COPY_EXHIBIT"
    } else {
        $action = "UNKNOWN_RAW_MP4"
    }
    $manifest.Add([PSCustomObject]@{
        Source       = "WHATSAPPRAW"
        FileName     = $f.Name
        FileType     = "MP4"
        Action       = $action
        ThumbExists  = $false
        ThumbCurrent = $false
        FullPath     = $f.FullName
        NewName      = ""
    })
}

# --- Categorise incoming WhatsAppRAW JPEG files ---
foreach ($f in $rawJpeg) {
    $action = if ($f.Name -match '^WhatsApp Image') { "COPY_IMAGE" } else { "UNKNOWN_RAW_JPEG" }
    $manifest.Add([PSCustomObject]@{
        Source       = "WHATSAPPRAW"
        FileName     = $f.Name
        FileType     = "JPEG"
        Action       = $action
        ThumbExists  = "N/A"
        ThumbCurrent = "N/A"
        FullPath     = $f.FullName
        NewName      = ""
    })
}

# =============================================================================
# INDEX PLANNING
# Step A: detect gaps in Directory numbering, mark files as FIX_REINDEX
#         and assign corrected names. After fixing, sequence is 001..N with
#         no gaps, so new RAW files safely append from N+1 onwards.
# Step B: assign new destination names to incoming RAW files from N+1.
# All planning only -- no files touched until Phase 2.
# =============================================================================

# --- Detect gaps and plan corrected names for a given prefix/ext ---
# Returns the highest contiguous index after planned reindex (= total file count)
function Plan-GapFix {
    param([string]$Prefix, [string]$Ext)

    $dirItems = @($manifest |
        Where-Object { $_.Source -eq "DIRECTORY" -and $_.FileName -match "^${Prefix}\d{3}${Ext}$" } |
        Sort-Object FileName)

    if ($dirItems.Count -eq 0) { return 0 }

    $actualIndexes = @($dirItems | ForEach-Object {
        if ($_.FileName -match "^${Prefix}(\d{3})${Ext}$") { [int]$Matches[1] }
    })

    $hasGaps = $false
    for ($i = 0; $i -lt $actualIndexes.Count; $i++) {
        if ($actualIndexes[$i] -ne ($i + 1)) { $hasGaps = $true; break }
    }

    if ($hasGaps) {
        Write-Log ("  GAP DETECTED in " + $Prefix + $Ext + " sequence -- planning reindex of " + $dirItems.Count + " file(s)") "DarkYellow"
        $counter = 1
        foreach ($item in $dirItems) {
            $corrected = "{0}{1:D3}{2}" -f $Prefix, $counter, $Ext
            if ($item.FileName -ne $corrected) {
                $item.Action  = "FIX_REINDEX"
                $item.NewName = $corrected
                Write-Log ("    [GAP FIX PLANNED] " + $item.FileName + " -> " + $corrected) "DarkYellow"
            }
            $counter++
        }
    }

    # After reindex, highest index = total count (contiguous from 1)
    return $dirItems.Count
}

Write-Log "  Checking Directory for numbering gaps..." "White"
$highestExhibit = Plan-GapFix -Prefix "Exhibit" -Ext ".mp4"
$highestVideo   = Plan-GapFix -Prefix "Video"   -Ext ".mp4"
$highestImage   = Plan-GapFix -Prefix "Image"   -Ext ".jpeg"

$gapFixCount = ($manifest | Where-Object { $_.Action -eq "FIX_REINDEX" }).Count
if ($gapFixCount -eq 0) {
    Write-Log "  No gaps found -- Directory numbering is clean." "DarkGray"
}
Write-Log ""

# --- Assign destination names to incoming RAW files, strictly after highest index ---

# Incoming Exhibits sorted by filename
$incomingExhibits = @($manifest | Where-Object { $_.Action -eq "COPY_EXHIBIT" } | Sort-Object FileName)
$exhibitNext = $highestExhibit + 1
foreach ($item in $incomingExhibits) {
    $item.NewName = "Exhibit{0:D3}.mp4" -f $exhibitNext
    $exhibitNext++
}

# Incoming Videos sorted oldest-first by file write time
$incomingVideos = @($manifest | Where-Object { $_.Action -eq "COPY_VIDEO" } |
    Sort-Object { (Get-Item $_.FullPath).LastWriteTime })
$videoNext = $highestVideo + 1
foreach ($item in $incomingVideos) {
    $item.NewName = "Video{0:D3}.mp4" -f $videoNext
    $videoNext++
}

# Incoming Images sorted oldest-first by file write time
$incomingImages = @($manifest | Where-Object { $_.Action -eq "COPY_IMAGE" } |
    Sort-Object { (Get-Item $_.FullPath).LastWriteTime })
$imageNext = $highestImage + 1
foreach ($item in $incomingImages) {
    $item.NewName = "Image{0:D3}.jpeg" -f $imageNext
    $imageNext++
}

# --- Write manifest CSV ---
$manifest | Export-Csv -Path $manifestFile -NoTypeInformation -Encoding UTF8

# --- Print summary ---
$okCount      = ($manifest | Where-Object { $_.Action -like "OK*" }).Count
$copyCount    = ($manifest | Where-Object { $_.Action -like "COPY_*" }).Count
$thumbCount   = ($manifest | Where-Object { $_.Action -eq "THUMB_NEEDED" }).Count
$gapCount     = ($manifest | Where-Object { $_.Action -eq "FIX_REINDEX" }).Count
$unknownCount = ($manifest | Where-Object { $_.Action -like "UNKNOWN*" }).Count

Write-Log "  Manifest written: $manifestFile" "Green"
Write-Log ""
Write-Log "  Summary:" "White"
Write-Log ("    Directory files OK (skip)  : " + $okCount) "DarkGray"
Write-Log ("    Gap fixes needed           : " + $gapCount) "DarkYellow"
Write-Log ("    New files to copy in       : " + $copyCount) "Yellow"
Write-Log ("    Thumbnails needed          : " + $thumbCount) "Yellow"
Write-Log ("    Unrecognised (skipped)     : " + $unknownCount) "DarkYellow"
Write-Log ""

Write-Log "  File-by-file plan:" "White"
foreach ($item in $manifest) {
    $color = switch ($item.Action) {
        { $_ -like "OK*" }       { "DarkGray" }
        { $_ -like "COPY_*" }    { "Yellow" }
        "THUMB_NEEDED"           { "Cyan" }
        default                  { "DarkYellow" }
    }
    $newNameDisplay  = if ($item.NewName) { " -> $($item.NewName)" } else { "" }
    $sourceDisplay   = if ($item.Source -eq "WHATSAPPRAW") { " [RAW]" } else { "" }
    $thumbDisplay    = if ($item.FileType -eq "MP4" -and $item.Source -eq "DIRECTORY") {
        if ($item.ThumbCurrent) { " [thumb OK]" } elseif ($item.ThumbExists) { " [thumb stale]" } else { " [no thumb]" }
    } else { "" }
    Write-Log ("    [{0,-18}] {1}{2}{3}{4}" -f $item.Action, $item.FileName, $newNameDisplay, $sourceDisplay, $thumbDisplay) $color
}
Write-Log ""

if ($copyCount -eq 0 -and $thumbCount -eq 0 -and $gapCount -eq 0) {
    Write-Log "  Nothing to do -- WhatsAppRAW is empty and Directory is fully up to date." "Green"
    Write-Log ""
    Write-Log "========================================" "Cyan"
    Write-Log "  Done. No changes made." "Green"
    Write-Log "========================================" "Cyan"
    Write-Log ""
    pause; exit
}

# =============================================================================
# PHASE 2 -- APPLY
#   Step A: fix any gaps in Directory with two-pass in-place rename
#   Step B: copy new RAW files into Directory with assigned names,
#           verify each copy with a post-copy SHA-256 checksum
#   Step C: generate thumbnails for any MP4 missing one
#   WhatsAppRAW originals are NEVER deleted.
# =============================================================================
Write-Log "[ Phase 2 ] Applying changes..." "Cyan"
Write-Log ""

$fixSuccess   = 0
$fixFailed    = 0
$copySuccess  = 0
$copyFailed   = 0
$copyCorrupt  = 0
$thumbSuccess = 0
$thumbFailed  = 0

# --- Step A: fix gaps in Directory via two-pass rename ---
function Apply-GapFix {
    param([string]$Prefix, [string]$Ext, [string]$TmpPrefix)

    $toFix = @($manifest |
        Where-Object { $_.Action -eq "FIX_REINDEX" -and $_.FileName -match "^${Prefix}" } |
        Sort-Object FileName)

    if ($toFix.Count -eq 0) { return }

    Write-Log ("  Fixing gaps in " + $Prefix + " sequence (" + $toFix.Count + " file(s))...") "DarkYellow"

    # Pass 1: rename to temp names
    $i = 1
    foreach ($item in $toFix) {
        $tmpName = "${TmpPrefix}{0:D5}${Ext}" -f $i
        try {
            Rename-Item -Path $item.FullPath -NewName $tmpName -ErrorAction Stop
            $item | Add-Member -NotePropertyName TmpName -NotePropertyValue $tmpName -Force
            $item.FullPath = Join-Path $directory $tmpName
            $i++
        } catch {
            Write-Log ("    ERROR pass1 gap fix " + $item.FileName + ": " + $_) "Red"
            $item | Add-Member -NotePropertyName TmpName -NotePropertyValue "" -Force
        }
    }

    # Pass 2: rename temp to final corrected names
    foreach ($item in $toFix) {
        if (-not $item.TmpName) { continue }
        $finalPath = Join-Path $directory $item.NewName
        if (Test-Path $finalPath) {
            Write-Log ("    SKIPPED (target exists): " + $item.NewName) "DarkYellow"
            Rename-Item -Path $item.FullPath -NewName $item.FileName -ErrorAction SilentlyContinue
            continue
        }
        try {
            Rename-Item -Path $item.FullPath -NewName $item.NewName -ErrorAction Stop
            Write-Log ("    [GAP FIXED] " + $item.FileName + " -> " + $item.NewName) "Green"
            $item.FullPath = $finalPath
            $script:fixSuccess++
        } catch {
            Write-Log ("    ERROR pass2 gap fix " + $item.TmpName + ": " + $_) "Red"
            $script:fixFailed++
        }
    }
    Write-Log ""
}

Apply-GapFix -Prefix "Exhibit" -Ext ".mp4"  -TmpPrefix "_TMP_GFIX_EXHIBIT_"
Apply-GapFix -Prefix "Video"   -Ext ".mp4"  -TmpPrefix "_TMP_GFIX_VIDEO_"
Apply-GapFix -Prefix "Image"   -Ext ".jpeg" -TmpPrefix "_TMP_GFIX_IMAGE_"

# --- Helper: copy a file and verify with post-copy checksum ---
function Copy-WithChecksum {
    param(
        [string]$SrcPath,
        [string]$DestPath,
        [string]$Label
    )

    try {
        Copy-Item -Path $SrcPath -Destination $DestPath -ErrorAction Stop
    } catch {
        Write-Log ("    ERROR copying " + $Label + ": " + $_) "Red"
        $script:copyFailed++
        return $false
    }

    # Verify destination matches source
    $srcInfo  = Get-Item -LiteralPath $SrcPath
    $destInfo = Get-Item -LiteralPath $DestPath
    $srcHash  = Get-FileChecksum  -FileInfo $srcInfo
    $destHash = Get-FileChecksum  -FileInfo $destInfo

    if (-not $srcHash -or -not $destHash) {
        Write-Log ("    WARNING: Could not verify checksum for " + $Label + " -- copy kept but flagged") "DarkYellow"
        $script:copySuccess++
        return $true
    }

    if ($srcHash -eq $destHash) {
        Write-Log ("    VERIFIED  " + $Label + "  [SHA256: " + $srcHash.Substring(0,16) + "...]") "Green"
        $script:copySuccess++
        return $true
    } else {
        Write-Log ("    CORRUPT COPY DETECTED -- deleting bad destination: " + $DestPath) "Red"
        Write-Log ("      Source SHA256 : " + $srcHash) "DarkRed"
        Write-Log ("      Dest   SHA256 : " + $destHash) "DarkRed"
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
        # Evict bad dest hash from cache so it does not persist
        $badKey = Get-CacheKey -FileInfo $destInfo
        $checksumCache.Remove($badKey)
        $script:copyCorrupt++
        return $false
    }
}

# --- Copy Exhibit files ---
if ($incomingExhibits.Count -gt 0) {
    Write-Log "  Copying Exhibit files to Directory..." "Cyan"
    foreach ($item in $incomingExhibits) {
        if (-not $item.NewName) { continue }
        $dest = Join-Path $directory $item.NewName
        if (Test-Path $dest) {
            Write-Log ("    SKIPPED (already exists): " + $item.NewName) "DarkYellow"
            continue
        }
        Copy-WithChecksum -SrcPath $item.FullPath -DestPath $dest -Label ($item.FileName + " -> " + $item.NewName)
    }
    Write-Log ""
}

# --- Copy Video files ---
if ($incomingVideos.Count -gt 0) {
    Write-Log "  Copying WhatsApp Video files to Directory..." "Cyan"
    foreach ($item in $incomingVideos) {
        if (-not $item.NewName) { continue }
        $dest = Join-Path $directory $item.NewName
        if (Test-Path $dest) {
            Write-Log ("    SKIPPED (already exists): " + $item.NewName) "DarkYellow"
            continue
        }
        Copy-WithChecksum -SrcPath $item.FullPath -DestPath $dest -Label ($item.FileName + " -> " + $item.NewName)
    }
    Write-Log ""
}

# --- Copy Image files ---
if ($incomingImages.Count -gt 0) {
    Write-Log "  Copying WhatsApp Image files to Directory..." "Cyan"
    foreach ($item in $incomingImages) {
        if (-not $item.NewName) { continue }
        $dest = Join-Path $directory $item.NewName
        if (Test-Path $dest) {
            Write-Log ("    SKIPPED (already exists): " + $item.NewName) "DarkYellow"
            continue
        }
        Copy-WithChecksum -SrcPath $item.FullPath -DestPath $dest -Label ($item.FileName + " -> " + $item.NewName)
    }
    Write-Log ""
}

# Save cache after all copies
Save-ChecksumCache

# --- Generate thumbnails for all MP4s in Directory that need one ---
# Re-scan Directory after copies so new files are included
$mp4NeedingThumb = Get-ChildItem -Path "$directory\*.mp4" -File | Sort-Object Name | Where-Object {
    $thumbPath = Join-Path $directory "$($_.BaseName).jpg"
    -not (Test-Path $thumbPath) -or ((Get-Item $thumbPath).LastWriteTime -lt $_.LastWriteTime)
}

if ($mp4NeedingThumb.Count -eq 0) {
    Write-Log "  Thumbnails: all up to date, nothing to generate." "DarkGray"
} else {
    Write-Log ("  Generating thumbnails for " + $mp4NeedingThumb.Count + " MP4 file(s)...") "Cyan"
    foreach ($video in $mp4NeedingThumb) {
        $thumbnail = Join-Path $directory "$($video.BaseName).jpg"
        Write-Log ("  " + $video.Name + " -> " + $video.BaseName + ".jpg") "Yellow"
        & ffmpeg -ss 00:00:02 -i "$($video.FullName)" -frames:v 1 -q:v 2 "$thumbnail" -y 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $thumbnail)) {
            Write-Log "    OK" "Green"
            $thumbSuccess++
        } else {
            Write-Log "    FAILED -- is FFmpeg installed and in PATH?" "Red"
            $thumbFailed++
        }
    }
}

Write-Log ""
Write-Log "========================================" "Cyan"
Write-Log "  Phase 2 Complete" "Green"
Write-Log ("  Gap fixes    : " + $fixSuccess + " file(s) (" + $fixFailed + " failed)") "White"
Write-Log ("  Copied       : " + $copySuccess + " file(s) (" + $copyFailed + " failed, " + $copyCorrupt + " corrupt/deleted)") $(if ($copyCorrupt -gt 0) { "Red" } else { "White" })
Write-Log ("  Thumbnails   : " + $thumbSuccess + " created, " + $thumbFailed + " failed") "White"
Write-Log "========================================" "Cyan"
Write-Log ""

# =============================================================================
# PHASE 3 -- FINAL DIFFERENTIAL: re-scan Directory vs BlobMedia now that
#            all new files have been copied and thumbnails generated.
#            This is the definitive upload list to act on.
#            Uses SHA-256 checksums (cache re-used, only new files hashed).
# =============================================================================
Write-Log "[ Phase 3 ] Final differential: Directory vs BlobMedia (checksum, post-copy)..." "Cyan"
Write-Log ""

if (-not (Test-Path $blobMedia)) {
    Write-Log "  WARNING: BlobMedia folder not found -- skipping final diff." "DarkYellow"
    Write-Log "  Upload everything in Directory to Azure Blob." "DarkYellow"
} else {
    $dirFilesPost  = Get-ChildItem -Path $directory -File |
        Where-Object { $_.Extension -match '^\.(mp4|jpg|jpeg)$' } | Sort-Object Name
    $blobFilesPost = Get-ChildItem -Path $blobMedia -File |
        Where-Object { $_.Extension -match '^\.(mp4|jpg|jpeg)$' } | Sort-Object Name

    $blobIdxPost = @{}
    foreach ($f in $blobFilesPost) { $blobIdxPost[$f.Name] = $f }
    $dirIdxPost  = @{}
    foreach ($f in $dirFilesPost)  { $dirIdxPost[$f.Name]  = $f }

    $finalDiff = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Log "  Hashing Directory files for Phase 3..." "DarkGray"
    foreach ($f in $dirFilesPost) {
        $dirHash = Get-FileChecksum -FileInfo $f

        if ($blobIdxPost.ContainsKey($f.Name)) {
            $blobFile = $blobIdxPost[$f.Name]
            $blobHash = Get-FileChecksum -FileInfo $blobFile

            if ($dirHash -and $blobHash -and $dirHash -eq $blobHash) {
                $status = "IN_SYNC"
            } elseif ($f.Length -ne $blobFile.Length) {
                $status = "SIZE_MISMATCH"
            } else {
                $status = "CHECKSUM_MISMATCH"
            }
        } else {
            $status   = "UPLOAD_NEEDED"
            $blobHash = "N/A"
        }

        $finalDiff.Add([PSCustomObject]@{
            FileName        = $f.Name
            Status          = $status
            DirectorySize   = $f.Length
            BlobSize        = if ($blobIdxPost.ContainsKey($f.Name)) { $blobIdxPost[$f.Name].Length } else { "N/A" }
            DirectorySHA256 = $dirHash
            BlobSHA256      = if ($blobIdxPost.ContainsKey($f.Name)) { (Get-FileChecksum -FileInfo $blobIdxPost[$f.Name]) } else { "N/A" }
            Extension       = $f.Extension
        })
    }

    foreach ($f in $blobFilesPost) {
        if (-not $dirIdxPost.ContainsKey($f.Name)) {
            $finalDiff.Add([PSCustomObject]@{
                FileName        = $f.Name
                Status          = "BLOB_ONLY"
                DirectorySize   = "N/A"
                BlobSize        = $f.Length
                DirectorySHA256 = "N/A"
                BlobSHA256      = (Get-FileChecksum -FileInfo $f)
                Extension       = $f.Extension
            })
        }
    }

    # Save final diff CSV and updated cache
    $finalDiffFile = Join-Path $manifestDir ("RenkVeRuh_UploadList_" + $runStamp + ".csv")
    $finalDiff | Sort-Object Status, FileName | Export-Csv -Path $finalDiffFile -NoTypeInformation -Encoding UTF8
    Save-ChecksumCache

    $fInSync          = @($finalDiff | Where-Object { $_.Status -eq "IN_SYNC" })
    $fUploadNeeded    = @($finalDiff | Where-Object { $_.Status -eq "UPLOAD_NEEDED" })
    $fSizeMismatch    = @($finalDiff | Where-Object { $_.Status -eq "SIZE_MISMATCH" })
    $fChksumMismatch  = @($finalDiff | Where-Object { $_.Status -eq "CHECKSUM_MISMATCH" })
    $fBlobOnly        = @($finalDiff | Where-Object { $_.Status -eq "BLOB_ONLY" })

    Write-Log "  Upload list saved: $finalDiffFile" "Green"
    Write-Log ""
    Write-Log "  Final Upload Summary:" "White"
    Write-Log ("    In sync (skip)                 : " + $fInSync.Count) "DarkGray"
    Write-Log ("    UPLOAD NEEDED                  : " + $fUploadNeeded.Count) "Yellow"
    Write-Log ("    Size mismatch (re-upload)      : " + $fSizeMismatch.Count) "DarkYellow"
    Write-Log ("    Checksum mismatch (re-upload)  : " + $fChksumMismatch.Count) "Red"
    Write-Log ("    Blob only (orphaned Azure)     : " + $fBlobOnly.Count) "Magenta"
    Write-Log ""

    if ($fUploadNeeded.Count -gt 0) {
        Write-Log "  -- FILES TO UPLOAD TO AZURE --" "Yellow"
        foreach ($item in ($fUploadNeeded | Sort-Object FileName)) {
            Write-Log ("    [UPLOAD]           " + $item.FileName) "Yellow"
        }
        Write-Log ""
    }

    if ($fSizeMismatch.Count -gt 0) {
        Write-Log "  -- SIZE MISMATCH (re-upload recommended) --" "DarkYellow"
        foreach ($item in ($fSizeMismatch | Sort-Object FileName)) {
            $localKB = [math]::Round($item.DirectorySize / 1KB, 1)
            $blobKB  = [math]::Round($item.BlobSize / 1KB, 1)
            Write-Log ("    [SIZE MISMATCH]    " + $item.FileName + "  local: " + $localKB + " KB  blob: " + $blobKB + " KB") "DarkYellow"
        }
        Write-Log ""
    }

    if ($fChksumMismatch.Count -gt 0) {
        Write-Log "  -- CHECKSUM MISMATCH (same size, different content -- re-upload!) --" "Red"
        foreach ($item in ($fChksumMismatch | Sort-Object FileName)) {
            Write-Log ("    [CHKSUM MISMATCH]  " + $item.FileName) "Red"
            Write-Log ("      Directory SHA256 : " + $item.DirectorySHA256) "DarkRed"
            Write-Log ("      Blob      SHA256 : " + $item.BlobSHA256) "DarkRed"
        }
        Write-Log ""
    }

    if ($fBlobOnly.Count -gt 0) {
        Write-Log "  -- BLOB ONLY (in Azure but not in Directory) --" "Magenta"
        foreach ($item in ($fBlobOnly | Sort-Object FileName)) {
            Write-Log ("    [BLOB ONLY]        " + $item.FileName) "Magenta"
        }
        Write-Log ""
    }

    if ($fUploadNeeded.Count -eq 0 -and $fSizeMismatch.Count -eq 0 -and $fChksumMismatch.Count -eq 0) {
        Write-Log "  All files are in sync (checksum verified). Nothing to upload to Azure." "Green"
        Write-Log ""
    }
}

Write-Log "  Checksum cache : $checksumDB" "White"
Write-Log "  Log saved      : $logFile" "White"
Write-Log ""
Write-Log "  NOTE: WhatsAppRAW files have NOT been deleted." "DarkGray"
Write-Log "        Delete them manually once you have verified Directory." "DarkGray"
Write-Log ""
pause
