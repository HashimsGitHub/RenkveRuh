$folder = "C:\Users\Hashi\Downloads\Nanimi"

# Rename MP4 files
$videoCounter = 1
Get-ChildItem -Path $folder -Filter "*.mp4" |
    Sort-Object Name |
    ForEach-Object {
        $newName = "Video{0:D3}{1}" -f $videoCounter, $_.Extension
        Rename-Item -Path $_.FullName -NewName $newName
        $videoCounter++
    }

# Rename JPEG files
$imageCounter = 1
Get-ChildItem -Path $folder -Filter "*.jpeg" |
    Sort-Object Name |
    ForEach-Object {
        $newName = "Image{0:D3}{1}" -f $imageCounter, $_.Extension
        Rename-Item -Path $_.FullName -NewName $newName
        $imageCounter++
    }