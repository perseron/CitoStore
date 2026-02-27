param(
    [string]$UsbLabel = "VISIONUSB",
    [string]$ShareHost = "192.168.2.162",
    [string]$ShareName = "vision_mirror",
    [string]$SmbUser = "smbuser",
    [string]$SmbPass = "citomat",
    [int]$TimeoutSec = 180,
    [int]$PollSec = 5,
    [switch]$WaitForRotate,
    [switch]$Cleanup
)

function Show-Banner($msg) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $msg -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

if ($ShareHost -eq "") {
    Fail "ShareHost is required (CM5 IP/hostname)"
}

Show-Banner "Vision USB Gateway functional test (Windows client)"

$vol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vol) {
    Fail "USB volume not found with label '$UsbLabel'"
}

if (-not $vol.DriveLetter) {
    Fail "USB volume '$UsbLabel' has no drive letter"
}

$drive = "$($vol.DriveLetter):"
Pass "USB volume detected: $drive ($UsbLabel)"

$testId = Get-Date -Format "yyyyMMdd_HHmmss"
$fileName = "vision_test_$testId.txt"
$filePath = Join-Path $drive $fileName
$content = "vision-test $testId"

Set-Content -Path $filePath -Value $content -Encoding ASCII
Start-Sleep -Milliseconds 200

$fileInfo = Get-Item $filePath
$size = $fileInfo.Length
$mtime = $fileInfo.LastWriteTime
$epochUtc = [int][double](Get-Date $fileInfo.LastWriteTimeUtc -UFormat %s)
$epochLocal = [int][double](Get-Date $fileInfo.LastWriteTime -UFormat %s)
Pass "Wrote test file: $fileName ($size bytes)"

$unc = "\\$ShareHost\$ShareName"

if ($SmbUser -ne "" -and $SmbPass -ne "") {
    cmd /c "net use $unc $SmbPass /user:$SmbUser" | Out-Null
    Pass "Connected to SMB share with credentials"
}

if (-not (Test-Path $unc)) {
    Fail "SMB share not reachable: $unc"
}

$rawPath = Join-Path $unc "raw"
$bydatePath = Join-Path $unc ("bydate\" + $mtime.ToString("yyyy\\MM\\dd"))

if (-not (Test-Path $rawPath)) {
    Fail "SMB raw folder missing: $rawPath"
}

if (-not (Test-Path $bydatePath)) {
    Warn "SMB bydate folder missing (yet): $bydatePath"
}

$stem = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
$ext = [System.IO.Path]::GetExtension($fileName)
$expectedExact = "^" + [regex]::Escape($fileName) + "$"
$expectedRegexUtcMtime = "^" + [regex]::Escape($stem + "_" + $epochUtc) + [regex]::Escape($ext) + "$"
$expectedRegexLocalMtime = "^" + [regex]::Escape($stem + "_" + $epochLocal) + [regex]::Escape($ext) + "$"
$expectedRegexUtcHash = "^" + [regex]::Escape($stem + "_" + $epochUtc + "_") + "[0-9a-f]{8}" + [regex]::Escape($ext) + "$"
$expectedRegexLocalHash = "^" + [regex]::Escape($stem + "_" + $epochLocal + "_") + "[0-9a-f]{8}" + [regex]::Escape($ext) + "$"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$foundRaw = $null

while ((Get-Date) -lt $deadline) {
    $foundRaw = Get-ChildItem -Path $rawPath -Filter "${stem}*${ext}" -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -eq $size -and (
                $_.Name -match $expectedExact -or
                $_.Name -match $expectedRegexUtcMtime -or
                $_.Name -match $expectedRegexLocalMtime -or
                $_.Name -match $expectedRegexUtcHash -or
                $_.Name -match $expectedRegexLocalHash
            )
        } |
        Select-Object -First 1
    if ($foundRaw) { break }
    $remaining = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
    Write-Host ("[WAIT] SMB sync pending ({0}s left)" -f [math]::Max(0, $remaining)) -ForegroundColor DarkYellow
    Start-Sleep -Seconds $PollSec
}

if (-not $foundRaw) {
    $candidates = Get-ChildItem -Path $rawPath -Filter "${stem}*${ext}" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5
    if ($candidates) {
        Write-Host "Recent candidates in raw:"
        $candidates | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }
    }
    Fail "Synced file not found in SMB raw within $TimeoutSec seconds (expected one of: ${fileName}, ${stem}_${epochUtc}${ext}, ${stem}_${epochUtc}_<hash>${ext})"
}

Pass "Synced file found in raw: $($foundRaw.Name)"

if (Test-Path $bydatePath) {
    $bydateFile = Join-Path $bydatePath $foundRaw.Name
    if (Test-Path $bydateFile) {
        Pass "Synced file found in bydate: $bydateFile"
    } else {
        Warn "Synced file not found in bydate (yet): $bydateFile"
    }
}

if ($WaitForRotate.IsPresent) {
    Write-Host "[INFO] Waiting for USB volume to detach..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $gone = -not (Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($gone) { break }
        $remaining = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        Write-Host ("[WAIT] detach pending ({0}s left)" -f [math]::Max(0, $remaining)) -ForegroundColor DarkYellow
        Start-Sleep -Seconds $PollSec
    }
    if (-not $gone) {
        Fail "USB volume did not detach within $TimeoutSec seconds"
    }
    Pass "USB volume detached"

    Write-Host "[INFO] Waiting for USB volume to reattach..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $newVol = $null
    while ((Get-Date) -lt $deadline) {
        $newVol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($newVol) { break }
        $remaining = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        Write-Host ("[WAIT] reattach pending ({0}s left)" -f [math]::Max(0, $remaining)) -ForegroundColor DarkYellow
        Start-Sleep -Seconds $PollSec
    }
    if (-not $newVol) {
        Fail "USB volume did not reattach within $TimeoutSec seconds"
    }
    $newDrive = if ($newVol.DriveLetter) { "$($newVol.DriveLetter):" } else { "<no-drive-letter>" }
    Pass "USB volume reattached: $newDrive"
}

if ($Cleanup.IsPresent) {
    Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    Pass "Removed USB test file"
}

Show-Banner "Summary"
Write-Host "[PASS] client functional test completed" -ForegroundColor Green
