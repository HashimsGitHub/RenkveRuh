# Source folders
$folders = @(
    "C:\Users\Hashi\Downloads\Folder1",
    "C:\Users\Hashi\Downloads\Folder2"
)

# Destination folder
$dest = "C:\Users\Hashi\Downloads\Directory"

# Create destination if it doesn't exist
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# Process JPEG files
$jpgCounter = 1
Get-ChildItem $folders -Filter *.jpeg | Sort-Object FullName | ForEach-Object {
    $newName = "Image{0:D3}.jpeg" -f $jpgCounter
    Copy-Item $_.FullName (Join-Path $dest $newName)
    $jpgCounter++
}

# Process MP4 files
$mp4Counter = 1
Get-ChildItem $folders -Filter *.mp4 | Sort-Object FullName | ForEach-Object {
    $newName = "Video{0:D3}.mp4" -f $mp4Counter
    Copy-Item $_.FullName (Join-Path $dest $newName)
    $mp4Counter++
}

Write-Host "Completed."