# Generate JPEG thumbnails from MP4 files using FFmpeg
# Place this script in C:\Users\Hashi\Downloads\Directory and run it

$directory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $directory

Write-Host "Generating JPEG thumbnails from MP4 files in:" -ForegroundColor Cyan
Write-Host $directory -ForegroundColor Cyan
Write-Host ""

# Fix: use -Filter with a wildcard path instead of -Include
$videos = Get-ChildItem -Path "$directory\*.mp4" -File | Where-Object { $_.Name -match '^(Exhibit|Video)\d+\.mp4$' }

if ($videos.Count -eq 0) {
    Write-Host "No Exhibit*.mp4 or Video*.mp4 files found in this directory." -ForegroundColor Red
    pause
    exit
}

$success = 0
$failed = 0

foreach ($video in $videos) {
    $thumbnail = Join-Path $directory "$($video.BaseName).jpg"
    Write-Host "Processing: $($video.Name) -> $($video.BaseName).jpg" -ForegroundColor Yellow
    
    & ffmpeg -ss 00:00:02 -i "$($video.FullName)" -frames:v 1 -q:v 2 "$thumbnail" -y 2>$null
    
    if ($LASTEXITCODE -eq 0 -and (Test-Path $thumbnail)) {
        Write-Host "  OK" -ForegroundColor Green
        $success++
    } else {
        Write-Host "  FAILED (is FFmpeg installed?)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "Done! $success thumbnail(s) created, $failed failed." -ForegroundColor Cyan
Write-Host "Upload all .jpg files to your Azure blob storage alongside the .mp4 files." -ForegroundColor Cyan
Write-Host ""
pause
