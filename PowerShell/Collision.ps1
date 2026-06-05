$folder = "C:\Users\Hashi\Downloads\Directory"

# Rename JPEG files
$jpgFiles = Get-ChildItem $folder -Filter *.jpeg | Sort-Object Name

$i = 1
foreach ($file in $jpgFiles) {
    Rename-Item $file.FullName ("TMP_JPG_{0}.jpeg" -f $i)
    $i++
}

$jpgFiles = Get-ChildItem $folder -Filter "TMP_JPG_*.jpeg" | Sort-Object Name

$i = 1
foreach ($file in $jpgFiles) {
    Rename-Item $file.FullName ("Image{0:D3}.jpeg" -f $i)
    $i++
}

# Rename MP4 files
$mp4Files = Get-ChildItem $folder -Filter *.mp4 | Sort-Object Name

$i = 1
foreach ($file in $mp4Files) {
    Rename-Item $file.FullName ("TMP_MP4_{0}.mp4" -f $i)
    $i++
}

$mp4Files = Get-ChildItem $folder -Filter "TMP_MP4_*.mp4" | Sort-Object Name

$i = 1
foreach ($file in $mp4Files) {
    Rename-Item $file.FullName ("Video{0:D3}.mp4" -f $i)
    $i++
}

Write-Host "Re-indexing completed."