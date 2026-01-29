param(
    [string]$UsbLabel = "VISIONUSB",
    [int]$FileSizeMB = 2,
    [int]$IntervalSec = 1,
    [int]$DurationSec = 300,
    [int]$FileCount = 0,
    [string]$Prefix = "vision_load",
    [switch]$WaitForRotate
)

function Pass($msg) { Write-Host "PASS: $msg" }
function Fail($msg) { Write-Host "FAIL: $msg"; exit 1 }
function Warn($msg) { Write-Host "WARN: $msg" }

Write-Host "== Vision USB Gateway load test (Windows client) =="

$vol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vol) {
    Fail "USB volume not found with label '$UsbLabel'"
}
if (-not $vol.DriveLetter) {
    Fail "USB volume '$UsbLabel' has no drive letter"
}

$drive = "$($vol.DriveLetter):"
Pass "USB volume detected: $drive ($UsbLabel)"

$sizeBytes = $FileSizeMB * 1024 * 1024
$start = Get-Date
$count = 0

while ($true) {
    if ($FileCount -gt 0) {
        if ($count -ge $FileCount) { break }
    } else {
        $elapsed = (Get-Date) - $start
        if ($elapsed.TotalSeconds -ge $DurationSec) { break }
    }

    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $name = "$Prefix`_$ts`_$count.bin"
    $path = Join-Path $drive $name

    # Create a fixed-size file quickly.
    cmd /c "fsutil file createnew `"$path`" $sizeBytes" | Out-Null
    $count++

    Start-Sleep -Seconds $IntervalSec
}

Pass "Created $count files of ${FileSizeMB}MB at ${IntervalSec}s intervals"

if ($WaitForRotate.IsPresent) {
    Write-Host "Waiting for USB volume to detach..."
    $deadline = (Get-Date).AddSeconds($DurationSec)
    $gone = $false
    while ((Get-Date) -lt $deadline) {
        $gone = -not (Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($gone) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $gone) {
        Warn "USB volume did not detach within ${DurationSec}s"
    } else {
        Pass "USB volume detached"
        Write-Host "Waiting for USB volume to reattach..."
        $deadline = (Get-Date).AddSeconds($DurationSec)
        $newVol = $null
        while ((Get-Date) -lt $deadline) {
            $newVol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($newVol) { break }
            Start-Sleep -Seconds 2
        }
        if (-not $newVol) {
            Warn "USB volume did not reattach within ${DurationSec}s"
        } else {
            $newDrive = if ($newVol.DriveLetter) { "$($newVol.DriveLetter):" } else { "<no-drive-letter>" }
            Pass "USB volume reattached: $newDrive"
        }
    }
}
