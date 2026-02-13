param(
    [string]$UsbLabel = "VISIONUSB",
    [int]$FileSizeMB = 2,
    [int]$IntervalSec = 1,
    [int]$DurationSec = 0,
    [int]$FileCount = 0,
    [int]$TargetUsedPercent = 85,
    [int]$ReserveFreePercent = 5,
    [int]$MaxAutoFiles = 20000,
    [string]$Prefix = "vision_load",
    [switch]$WaitForRotate
)

function Pass($msg) { Write-Host "PASS: $msg" }
function Fail($msg) { Write-Host "FAIL: $msg"; exit 1 }
function Warn($msg) { Write-Host "WARN: $msg" }
function Get-VolumeIdentity($v) {
    if (-not $v) { return "" }
    $uid = if ($v.UniqueId) { $v.UniqueId } else { "" }
    $dl = if ($v.DriveLetter) { $v.DriveLetter } else { "" }
    return "$uid|$dl|$($v.Size)"
}

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
$initialIdentity = Get-VolumeIdentity $vol

$sizeBytes = $FileSizeMB * 1024 * 1024
$totalBytes = [int64]$vol.Size
$freeBytes = [int64]$vol.SizeRemaining
if ($totalBytes -le 0 -or $freeBytes -lt 0) {
    Fail "Could not read USB size/free-space for auto planning"
}
if ($TargetUsedPercent -lt 1 -or $TargetUsedPercent -gt 99) {
    Fail "TargetUsedPercent must be in range 1..99"
}
if ($ReserveFreePercent -lt 0 -or $ReserveFreePercent -gt 50) {
    Fail "ReserveFreePercent must be in range 0..50"
}
if ($MaxAutoFiles -lt 1) {
    Fail "MaxAutoFiles must be >= 1"
}
if ($sizeBytes -le 0) {
    Fail "FileSizeMB must be >= 1"
}

$plannedByCount = $FileCount -gt 0
$plannedByDuration = (-not $plannedByCount) -and ($DurationSec -gt 0)
$autoPlannedCount = 0

if (-not $plannedByCount -and -not $plannedByDuration) {
    $usedBytes = $totalBytes - $freeBytes
    $targetUsedBytes = [int64]([math]::Floor($totalBytes * ($TargetUsedPercent / 100.0)))
    $reserveBytes = [int64]([math]::Floor($totalBytes * ($ReserveFreePercent / 100.0)))
    $maxWritableBytes = [int64][math]::Max([double]0, [double]($freeBytes - $reserveBytes))
    $neededBytes = [int64][math]::Max([double]0, [double]($targetUsedBytes - $usedBytes))
    $planBytes = [int64][math]::Min([double]$neededBytes, [double]$maxWritableBytes)
    $autoPlannedCount = [int][math]::Floor($planBytes / $sizeBytes)
    if ($autoPlannedCount -gt $MaxAutoFiles) {
        $autoPlannedCount = $MaxAutoFiles
    }
    if ($autoPlannedCount -le 0) {
        Warn "Auto plan computed zero files (already near target or free reserve too small)"
        $autoPlannedCount = 1
    }
    $FileCount = $autoPlannedCount
    $plannedByCount = $true
    Pass "Auto plan: total=$([math]::Round($totalBytes/1GB,2))GB free=$([math]::Round($freeBytes/1GB,2))GB target=${TargetUsedPercent}% reserve=${ReserveFreePercent}% -> files=$FileCount x ${FileSizeMB}MB"
}

$start = Get-Date
$count = 0

while ($true) {
    if ($plannedByCount) {
        if ($count -ge $FileCount) { break }
    } elseif ($plannedByDuration) {
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
    $waitSec = if ($plannedByDuration) {
        $DurationSec
    } else {
        [math]::Max(120, ($count * [math]::Max(1, $IntervalSec)) + 120)
    }
    Write-Host "Waiting for USB volume to detach..."
    $deadline = (Get-Date).AddSeconds($waitSec)
    $gone = $false
    $rotated = $false
    $rotationMode = ""
    while ((Get-Date) -lt $deadline) {
        $curVol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $curVol) {
            $gone = $true
        } else {
            $curIdentity = Get-VolumeIdentity $curVol
            if ($gone) {
                $rotated = $true
                $rotationMode = "detach/reattach"
                break
            }
            if ($curIdentity -ne $initialIdentity) {
                $rotated = $true
                $rotationMode = "identity-change"
                break
            }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $rotated -and -not $gone) {
        Warn "USB rotation not observed within ${waitSec}s (no detach and no identity change)"
    } else {
        if (-not $rotated -and $gone) {
            Write-Host "Waiting for USB volume to reattach..."
            $deadline = (Get-Date).AddSeconds($waitSec)
            $newVol = $null
            while ((Get-Date) -lt $deadline) {
                $newVol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($newVol) {
                    $rotated = $true
                    $rotationMode = "detach/reattach"
                    break
                }
                Start-Sleep -Seconds 2
            }
        }

        if (-not $rotated) {
            Warn "USB volume detached but did not reattach within ${waitSec}s"
        } else {
            $newVol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
            $newDrive = if ($newVol -and $newVol.DriveLetter) { "$($newVol.DriveLetter):" } else { "<no-drive-letter>" }
            Pass "USB rotation observed (${rotationMode}); current volume: $newDrive"
        }
    }
}
