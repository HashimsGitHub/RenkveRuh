# =============================================================================
#  RenkVeRuh_Process.ps1
#
#  FOLDER STRUCTURE:
#    D:\RenkVeRuh\WhatsAppRAW\  -- dump all raw WhatsApp files here
#    D:\RenkVeRuh\Directory\    -- cleaned, renamed, indexed media (source of truth)
#    D:\RenkVeRuh\Manifest\     -- logs, CSVs, checksum cache (never media)
#    D:\RenkVeRuh\PowerShell\   -- this script
#
#  PHASE 1 -- Delta scan: hash every file in WhatsAppRAW, compare against
#             every file already in Directory. Raw files whose SHA-256 already
#             exists in Directory are marked ALREADY_IMPORTED and skipped.
#             Only genuinely new files are queued for copy. Nothing is
#             touched in this phase.
#
#  PHASE 2 -- Gap fix: detect and repair any numbering gaps in Directory
#             (two-pass rename so no collisions). Planning only -- no copies yet.
#
#  PHASE 3 -- Apply: copy queued new files into Directory with the next
#             sequential name in their series, verify each copy with a
#             post-copy SHA-256 checksum, then generate .jpg thumbnails for
#             any .mp4 missing one. WhatsAppRAW originals are never deleted.
#
#  CHECKSUM CACHE (Manifest\RenkVeRuh_ChecksumDB.csv):
#    Persistent key = "FileName|SizeBytes|LastWriteUtcTicks", value = SHA-256.
#    Re-used across runs -- unchanged files are never re-hashed.
# =============================================================================

$whatsappRaw  = "D:\RenkVeRuh\WhatsAppRAW"
$directory    = "D:\RenkVeRuh\Directory"
$manifestDir  = "D:\RenkVeRuh\Manifest"
$timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runStamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$manifestFile = Join-Path $manifestDir "RenkVeRuh_Manifest_$runStamp.csv"
$logFile      = Join-Path $manifestDir "RenkVeRuh_Log_$runStamp.txt"
$checksumDB   = Join-Path $manifestDir "RenkVeRuh_ChecksumDB.csv"

# --- Ensure folders exist ---
foreach ($folder in @($directory, $manifestDir)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

# =============================================================================
# LOGGING
# =============================================================================
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
Write-Log "  Manifest    : $manifestDir" "Cyan"
Write-Log ""

if (-not (Test-Path $whatsappRaw)) {
    Write-Log "ERROR: WhatsAppRAW folder not found: $whatsappRaw" "Red"
    pause; exit
}

# =============================================================================
# CHECKSUM CACHE
#   Persistent CSV: Manifest\RenkVeRuh_ChecksumDB.csv
#   Key   = "FileName|SizeBytes|LastWriteUtcTicks"
#   Value = SHA-256 hex string
# =============================================================================
$checksumCache = @{}

if (Test-Path $checksumDB) {
    try {
        Import-Csv -Path $checksumDB -Encoding UTF8 | ForEach-Object {
            if ($_.CacheKey -and $_.SHA256) { $checksumCache[$_.CacheKey] = $_.SHA256 }
        }
        Write-Log ("  Checksum cache loaded: " + $checksumCache.Count + " entr(ies)") "DarkGray"
    } catch {
        Write-Log "  WARNING: Could not load checksum cache -- starting fresh." "DarkYellow"
    }
} else {
    Write-Log "  Checksum cache not found -- will be created at: $checksumDB" "DarkGray"
}
Write-Log ""

function Get-CacheKey ([System.IO.FileInfo]$f) {
    return ("{0}|{1}|{2}" -f $f.Name, $f.Length, $f.LastWriteTimeUtc.Ticks)
}

function Get-FileChecksum ([System.IO.FileInfo]$f) {
    $key = Get-CacheKey $f
    if ($checksumCache.ContainsKey($key)) { return $checksumCache[$key] }
    try {
        $sha    = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($f.FullName)
        $bytes  = $sha.ComputeHash($stream)
        $stream.Close(); $sha.Dispose()
        $hex = [System.BitConverter]::ToString($bytes) -replace '-', ''
        $checksumCache[$key] = $hex
        return $hex
    } catch {
        Write-Log ("  WARNING: Cannot hash: " + $f.FullName + " -- " + $_) "DarkYellow"
        return $null
    }
}

function Save-ChecksumCache {
    try {
        $checksumCache.GetEnumerator() |
            ForEach-Object { [PSCustomObject]@{ CacheKey = $_.Key; SHA256 = $_.Value } } |
            Export-Csv -Path $checksumDB -NoTypeInformation -Encoding UTF8
    } catch {
        Write-Log ("  WARNING: Could not save checksum cache: " + $_) "DarkYellow"
    }
}

# =============================================================================
# PHASE 1 -- DELTA SCAN: WhatsAppRAW vs Directory (by checksum)
#
#   1. Hash every media file already in Directory -> build a "known hashes" set.
#   2. Hash every media file in WhatsAppRAW.
#   3. If RAW hash is already in the known-hashes set -> ALREADY_IMPORTED (skip).
#   4. Otherwise -> queue for copy (COPY_VIDEO / COPY_IMAGE / COPY_EXHIBIT).
#   5. Existing Directory files are also categorised for gap-fix and thumb checks.
#
#   Nothing is touched in this phase.
# =============================================================================
Write-Log "[ Phase 1 ] Delta scan: WhatsAppRAW vs Directory..." "Cyan"
Write-Log ""

# --- Scan Directory ----------------------------------------------------------
$existingMp4  = Get-ChildItem -Path "$directory\*.mp4"  -File -ErrorAction SilentlyContinue | Sort-Object Name
$existingJpeg = Get-ChildItem -Path "$directory\*.jpeg" -File -ErrorAction SilentlyContinue | Sort-Object Name
$existingJpg  = Get-ChildItem -Path "$directory\*.jpg"  -File -ErrorAction SilentlyContinue | Sort-Object Name

# Build a set of all SHA-256 hashes that already exist in Directory
# (thumbnails .jpg are excluded from duplicate detection -- only media files count)
Write-Log "  Building Directory hash index..." "DarkGray"
$dirHashSet = @{}   # hash -> DirectoryFileName (for reporting)

foreach ($f in ($existingMp4 + $existingJpeg)) {
    $h = Get-FileChecksum $f
    if ($h) { $dirHashSet[$h] = $f.Name }
}
Write-Log ("  Directory index: " + $dirHashSet.Count + " unique media hash(es) across " +
    ($existingMp4.Count + $existingJpeg.Count) + " file(s)") "DarkGray"
Write-Log ""

# --- Scan WhatsAppRAW --------------------------------------------------------
$rawMp4   = Get-ChildItem -Path "$whatsappRaw\*.mp4"   -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
$rawJpeg  = Get-ChildItem -Path "$whatsappRaw\*.jpeg"  -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime

Write-Log ("  WhatsAppRAW contains: " + $rawMp4.Count + " MP4(s), " + $rawJpeg.Count + " JPEG(s)") "DarkGray"
Write-Log "  Checking each RAW file against Directory hash index..." "DarkGray"
Write-Log ""

$manifest = [System.Collections.Generic.List[PSCustomObject]]::new()

# Helper: classify a raw file
function Add-RawEntry ([System.IO.FileInfo]$f, [string]$preferredAction) {
    $h = Get-FileChecksum $f
    if ($h -and $dirHashSet.ContainsKey($h)) {
        $action      = "ALREADY_IMPORTED"
        $matchedName = $dirHashSet[$h]
    } else {
        $action      = $preferredAction
        $matchedName = ""
    }
    $script:manifest.Add([PSCustomObject]@{
        Source      = "WHATSAPPRAW"
        FileName    = $f.Name
        FileType    = $f.Extension.TrimStart('.').ToUpper()
        Action      = $action
        MatchedFile = $matchedName   # populated when ALREADY_IMPORTED
        SHA256      = $h
        FullPath    = $f.FullName
        NewName     = ""
    })
}

foreach ($f in $rawMp4) {
    if    ($f.Name -match '^WhatsApp Video') { Add-RawEntry $f "COPY_VIDEO"   }
    elseif ($f.Name -match '^Exhibit')        { Add-RawEntry $f "COPY_EXHIBIT" }
    else                                      { Add-RawEntry $f "UNKNOWN_RAW_MP4" }
}

foreach ($f in $rawJpeg) {
    if ($f.Name -match '^WhatsApp Image') { Add-RawEntry $f "COPY_IMAGE" }
    else                                  { Add-RawEntry $f "UNKNOWN_RAW_JPEG" }
}

# --- Categorise existing Directory MP4 files (for gap-fix + thumb tracking) ---
foreach ($f in $existingMp4) {
    $thumbPath    = Join-Path $directory "$($f.BaseName).jpg"
    $thumbExists  = Test-Path $thumbPath
    $thumbCurrent = $thumbExists -and ((Get-Item $thumbPath).LastWriteTime -ge $f.LastWriteTime)

    if    ($f.Name -match '^Exhibit\d{3}\.mp4$') { $action = if ($thumbCurrent) { "OK_EXHIBIT"    } else { "THUMB_NEEDED" } }
    elseif ($f.Name -match '^Video\d{3}\.mp4$')   { $action = if ($thumbCurrent) { "OK"            } else { "THUMB_NEEDED" } }
    else                                           { $action = "UNKNOWN_MP4" }

    $manifest.Add([PSCustomObject]@{
        Source      = "DIRECTORY"
        FileName    = $f.Name
        FileType    = "MP4"
        Action      = $action
        MatchedFile = ""
        SHA256      = (Get-FileChecksum $f)
        FullPath    = $f.FullName
        NewName     = ""
    })
}

# --- Categorise existing Directory JPEG files ---
foreach ($f in $existingJpeg) {
    $action = if ($f.Name -match '^Image\d{3}\.jpeg$') { "OK" } else { "UNKNOWN_JPEG" }
    $manifest.Add([PSCustomObject]@{
        Source      = "DIRECTORY"
        FileName    = $f.Name
        FileType    = "JPEG"
        Action      = $action
        MatchedFile = ""
        SHA256      = (Get-FileChecksum $f)
        FullPath    = $f.FullName
        NewName     = ""
    })
}

# Save cache after all hashing in Phase 1
Save-ChecksumCache

# --- Phase 1 summary ---------------------------------------------------------
$alreadyImported = @($manifest | Where-Object { $_.Action -eq "ALREADY_IMPORTED" })
$copyCount       = @($manifest | Where-Object { $_.Action -like "COPY_*" })
$unknownRaw      = @($manifest | Where-Object { $_.Action -like "UNKNOWN_RAW_*" })
$thumbNeeded     = @($manifest | Where-Object { $_.Action -eq "THUMB_NEEDED" })
$okCount         = @($manifest | Where-Object { $_.Action -like "OK*" })

Write-Log "  Delta scan results:" "White"
Write-Log ("    Already imported (skip)    : " + $alreadyImported.Count) "DarkGray"
Write-Log ("    New files to copy          : " + $copyCount.Count) "Yellow"
Write-Log ("    Unrecognised RAW (skip)    : " + $unknownRaw.Count) "DarkYellow"
Write-Log ("    Directory files OK         : " + $okCount.Count) "DarkGray"
Write-Log ("    Thumbnails needed          : " + $thumbNeeded.Count) "Yellow"
Write-Log ""

if ($alreadyImported.Count -gt 0) {
    Write-Log "  -- ALREADY IMPORTED (will not be copied again) --" "DarkGray"
    foreach ($item in ($alreadyImported | Sort-Object FileName)) {
        Write-Log ("    [SKIP]  " + $item.FileName + "  (matches Directory: " + $item.MatchedFile + ")") "DarkGray"
    }
    Write-Log ""
}

if ($unknownRaw.Count -gt 0) {
    Write-Log "  -- UNRECOGNISED RAW FILES (skipped -- rename manually if needed) --" "DarkYellow"
    foreach ($item in ($unknownRaw | Sort-Object FileName)) {
        Write-Log ("    [?]     " + $item.FileName) "DarkYellow"
    }
    Write-Log ""
}

# =============================================================================
# PHASE 2 -- GAP FIX PLANNING: detect numbering gaps in Directory
#            and plan corrected sequential names. Planning only -- no rename yet.
# =============================================================================
Write-Log "[ Phase 2 ] Checking Directory for numbering gaps..." "Cyan"
Write-Log ""

function Plan-GapFix ([string]$Prefix, [string]$Ext) {
    $dirItems = @($manifest |
        Where-Object { $_.Source -eq "DIRECTORY" -and $_.FileName -match "^${Prefix}\d{3}${Ext}$" } |
        Sort-Object FileName)

    if ($dirItems.Count -eq 0) { return 0 }

    $indexes = @($dirItems | ForEach-Object {
        if ($_.FileName -match "^${Prefix}(\d{3})${Ext}$") { [int]$Matches[1] }
    })

    $hasGaps = $false
    for ($i = 0; $i -lt $indexes.Count; $i++) {
        if ($indexes[$i] -ne ($i + 1)) { $hasGaps = $true; break }
    }

    if ($hasGaps) {
        Write-Log ("  GAP DETECTED in $Prefix$Ext -- planning reindex of " + $dirItems.Count + " file(s)") "DarkYellow"
        $counter = 1
        foreach ($item in $dirItems) {
            $corrected = "{0}{1:D3}{2}" -f $Prefix, $counter, $Ext
            if ($item.FileName -ne $corrected) {
                $item.Action  = "FIX_REINDEX"
                $item.NewName = $corrected
                Write-Log ("    [PLAN] " + $item.FileName + " -> " + $corrected) "DarkYellow"
            }
            $counter++
        }
    } else {
        Write-Log ("  " + $Prefix + $Ext + ": no gaps (1.." + $dirItems.Count + ")") "DarkGray"
    }

    return $dirItems.Count
}

$highestExhibit = Plan-GapFix "Exhibit" ".mp4"
$highestVideo   = Plan-GapFix "Video"   ".mp4"
$highestImage   = Plan-GapFix "Image"   ".jpeg"

$gapCount = ($manifest | Where-Object { $_.Action -eq "FIX_REINDEX" }).Count
if ($gapCount -eq 0) { Write-Log "  All sequences are clean -- no gaps found." "DarkGray" }
Write-Log ""

# --- Assign destination names to new RAW files (append after highest index) --
$incomingExhibits = @($manifest | Where-Object { $_.Action -eq "COPY_EXHIBIT" } | Sort-Object FileName)
$exhibitNext = $highestExhibit + 1
foreach ($item in $incomingExhibits) { $item.NewName = "Exhibit{0:D3}.mp4"  -f $exhibitNext; $exhibitNext++ }

$incomingVideos = @($manifest | Where-Object { $_.Action -eq "COPY_VIDEO" } |
    Sort-Object { (Get-Item $_.FullPath).LastWriteTime })
$videoNext = $highestVideo + 1
foreach ($item in $incomingVideos) { $item.NewName = "Video{0:D3}.mp4"   -f $videoNext;   $videoNext++ }

$incomingImages = @($manifest | Where-Object { $_.Action -eq "COPY_IMAGE" } |
    Sort-Object { (Get-Item $_.FullPath).LastWriteTime })
$imageNext = $highestImage + 1
foreach ($item in $incomingImages) { $item.NewName = "Image{0:D3}.jpeg"  -f $imageNext;   $imageNext++ }

# --- Emit manifest CSV (full plan before any changes are made) ---------------
$manifest | Export-Csv -Path $manifestFile -NoTypeInformation -Encoding UTF8
Write-Log "  Manifest written: $manifestFile" "Green"
Write-Log ""

# --- Print per-file plan -----------------------------------------------------
Write-Log "  File-by-file plan:" "White"
foreach ($item in $manifest) {
    $color = switch -Wildcard ($item.Action) {
        "OK*"              { "DarkGray" }
        "ALREADY_IMPORTED" { "DarkGray" }
        "COPY_*"           { "Yellow"   }
        "THUMB_NEEDED"     { "Cyan"     }
        "FIX_REINDEX"      { "DarkYellow" }
        default            { "DarkYellow" }
    }
    $tag     = "[{0,-18}]" -f $item.Action
    $newPart = if ($item.NewName)     { " -> " + $item.NewName }     else { "" }
    $match   = if ($item.MatchedFile) { " (= " + $item.MatchedFile + ")" } else { "" }
    $src     = if ($item.Source -eq "WHATSAPPRAW") { " [RAW]" } else { "" }
    Write-Log ("    $tag $($item.FileName)$newPart$match$src") $color
}
Write-Log ""

$totalWork = $copyCount.Count + $thumbNeeded.Count + $gapCount
if ($totalWork -eq 0) {
    Write-Log "  Nothing to do -- WhatsAppRAW has no new files and Directory is fully up to date." "Green"
    Write-Log ""
    Write-Log "========================================" "Cyan"
    Write-Log "  Done. No changes made." "Green"
    Write-Log "  Checksum cache : $checksumDB" "White"
    Write-Log "  Log saved      : $logFile" "White"
    Write-Log "========================================" "Cyan"
    Write-Log ""
    pause; exit
}

# =============================================================================
# PHASE 3 -- APPLY
#   Step A: fix numbering gaps in Directory (two-pass rename)
#   Step B: copy new RAW files into Directory with assigned sequential names,
#           verify each copy with a post-copy SHA-256 checksum
#   Step C: generate thumbnails for MP4s that need one
#   WhatsAppRAW originals are NEVER deleted.
# =============================================================================
Write-Log "[ Phase 3 ] Applying changes..." "Cyan"
Write-Log ""

$fixSuccess  = 0; $fixFailed  = 0
$copySuccess = 0; $copyFailed = 0; $copyCorrupt = 0
$thumbOk     = 0; $thumbFail  = 0

# ---------------------------------------------------------------------------
# Step A: two-pass gap rename
# ---------------------------------------------------------------------------
function Apply-GapFix ([string]$Prefix, [string]$Ext, [string]$TmpPrefix) {
    $toFix = @($manifest |
        Where-Object { $_.Action -eq "FIX_REINDEX" -and $_.FileName -match "^$Prefix" } |
        Sort-Object FileName)
    if ($toFix.Count -eq 0) { return }

    Write-Log ("  Fixing $Prefix gaps (" + $toFix.Count + " file(s))...") "DarkYellow"

    # Pass 1: -> temp names (avoids collision between old and new names)
    $i = 1
    foreach ($item in $toFix) {
        $tmp = "${TmpPrefix}{0:D5}${Ext}" -f $i
        try {
            Rename-Item -Path $item.FullPath -NewName $tmp -ErrorAction Stop
            $item | Add-Member -NotePropertyName TmpName -NotePropertyValue $tmp -Force
            $item.FullPath = Join-Path $directory $tmp
            $i++
        } catch {
            Write-Log ("    ERROR pass1: " + $item.FileName + " -- " + $_) "Red"
            $item | Add-Member -NotePropertyName TmpName -NotePropertyValue "" -Force
        }
    }

    # Pass 2: temp -> final corrected names
    foreach ($item in $toFix) {
        if (-not $item.TmpName) { continue }
        $dest = Join-Path $directory $item.NewName
        if (Test-Path $dest) {
            Write-Log ("    SKIPPED (target exists): " + $item.NewName) "DarkYellow"
            Rename-Item -Path $item.FullPath -NewName $item.FileName -ErrorAction SilentlyContinue
            continue
        }
        try {
            Rename-Item -Path $item.FullPath -NewName $item.NewName -ErrorAction Stop
            Write-Log ("    [FIXED] " + $item.FileName + " -> " + $item.NewName) "Green"
            $item.FullPath = $dest
            $script:fixSuccess++
        } catch {
            Write-Log ("    ERROR pass2: " + $item.TmpName + " -- " + $_) "Red"
            $script:fixFailed++
        }
    }
    Write-Log ""
}

Apply-GapFix "Exhibit" ".mp4"  "_TMP_GFIX_EXHIBIT_"
Apply-GapFix "Video"   ".mp4"  "_TMP_GFIX_VIDEO_"
Apply-GapFix "Image"   ".jpeg" "_TMP_GFIX_IMAGE_"

# ---------------------------------------------------------------------------
# Step B: copy new files with post-copy checksum verification
# ---------------------------------------------------------------------------
function Copy-WithChecksum ([string]$SrcPath, [string]$DestPath, [string]$Label) {
    try {
        Copy-Item -Path $SrcPath -Destination $DestPath -ErrorAction Stop
    } catch {
        Write-Log ("    ERROR copying $Label -- " + $_) "Red"
        $script:copyFailed++
        return
    }

    $srcInfo  = Get-Item -LiteralPath $SrcPath
    $destInfo = Get-Item -LiteralPath $DestPath
    $srcHash  = Get-FileChecksum $srcInfo
    $destHash = Get-FileChecksum $destInfo

    if (-not $srcHash -or -not $destHash) {
        Write-Log ("    WARNING: Could not verify $Label -- copy kept but unconfirmed") "DarkYellow"
        $script:copySuccess++
        return
    }

    if ($srcHash -eq $destHash) {
        Write-Log ("    OK  $Label  [" + $srcHash.Substring(0,12) + "...]") "Green"
        $script:copySuccess++
    } else {
        Write-Log ("    CORRUPT COPY -- deleting bad file: $DestPath") "Red"
        Write-Log ("      src  SHA256: $srcHash") "DarkRed"
        Write-Log ("      dest SHA256: $destHash") "DarkRed"
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
        $badKey = Get-CacheKey $destInfo
        $checksumCache.Remove($badKey)
        $script:copyCorrupt++
    }
}

function Copy-Group ([array]$Items, [string]$GroupLabel) {
    if ($Items.Count -eq 0) { return }
    Write-Log "  Copying $GroupLabel..." "Cyan"
    foreach ($item in $Items) {
        if (-not $item.NewName) { continue }
        $dest = Join-Path $directory $item.NewName
        if (Test-Path $dest) {
            Write-Log ("    SKIPPED (dest exists): " + $item.NewName) "DarkYellow"
            continue
        }
        Copy-WithChecksum -SrcPath $item.FullPath -DestPath $dest `
            -Label ($item.FileName + " -> " + $item.NewName)
    }
    Write-Log ""
}

Copy-Group $incomingExhibits "Exhibit files"
Copy-Group $incomingVideos   "Video files"
Copy-Group $incomingImages   "Image files"

Save-ChecksumCache

# ---------------------------------------------------------------------------
# Step C: generate missing/stale thumbnails
# ---------------------------------------------------------------------------
$mp4NeedingThumb = Get-ChildItem -Path "$directory\*.mp4" -File | Sort-Object Name | Where-Object {
    $tp = Join-Path $directory "$($_.BaseName).jpg"
    -not (Test-Path $tp) -or ((Get-Item $tp).LastWriteTime -lt $_.LastWriteTime)
}

if ($mp4NeedingThumb.Count -eq 0) {
    Write-Log "  Thumbnails: all up to date." "DarkGray"
} else {
    Write-Log ("  Generating thumbnails for " + $mp4NeedingThumb.Count + " MP4(s)...") "Cyan"
    foreach ($video in $mp4NeedingThumb) {
        $thumb = Join-Path $directory "$($video.BaseName).jpg"
        Write-Log ("    " + $video.Name + " -> " + $video.BaseName + ".jpg") "Yellow"
        & ffmpeg -ss 00:00:02 -i "$($video.FullName)" -frames:v 1 -q:v 2 "$thumb" -y 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $thumb)) {
            Write-Log "      OK" "Green"; $thumbOk++
        } else {
            Write-Log "      FAILED -- is FFmpeg installed and in PATH?" "Red"; $thumbFail++
        }
    }
}

Write-Log ""
Write-Log "========================================" "Cyan"
Write-Log "  Done." "Green"
Write-Log ("  Gap fixes  : " + $fixSuccess + " ok, " + $fixFailed + " failed") "White"
Write-Log ("  Copied     : " + $copySuccess + " ok, " + $copyFailed + " failed, " + $copyCorrupt + " corrupt/deleted") $(if ($copyCorrupt -gt 0) { "Red" } else { "White" })
Write-Log ("  Thumbnails : " + $thumbOk + " created, " + $thumbFail + " failed") "White"
Write-Log "  Manifest   : $manifestFile" "White"
Write-Log "  Cache      : $checksumDB" "White"
Write-Log "  Log        : $logFile" "White"
Write-Log ""
Write-Log "  NOTE: WhatsAppRAW files have NOT been deleted." "DarkGray"
Write-Log "        Review the manifest, then delete them manually." "DarkGray"
Write-Log "========================================" "Cyan"
Write-Log ""
pause
