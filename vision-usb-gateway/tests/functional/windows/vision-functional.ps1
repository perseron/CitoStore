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

function Pass($msg) { Write-Host "PASS: $msg" }
function Fail($msg) { Write-Host "FAIL: $msg"; exit 1 }
function Warn($msg) { Write-Host "WARN: $msg" }

if ($ShareHost -eq "") {
    Fail "ShareHost is required (CM5 IP/hostname)"
}

Write-Host "== Vision USB Gateway functional test (Windows client) =="

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
$expectedRegexUtc = "^" + [regex]::Escape($stem + "_" + $epochUtc + "_") + "[0-9a-f]{8}" + [regex]::Escape($ext) + "$"
$expectedRegexLocal = "^" + [regex]::Escape($stem + "_" + $epochLocal + "_") + "[0-9a-f]{8}" + [regex]::Escape($ext) + "$"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$foundRaw = $null

while ((Get-Date) -lt $deadline) {
    $foundRaw = Get-ChildItem -Path $rawPath -Filter "${stem}_*${ext}" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq $size -and ($_.Name -match $expectedRegexUtc -or $_.Name -match $expectedRegexLocal) } |
        Select-Object -First 1
    if ($foundRaw) { break }
    Start-Sleep -Seconds $PollSec
}

if (-not $foundRaw) {
    $candidates = Get-ChildItem -Path $rawPath -Filter "${stem}_*${ext}" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5
    if ($candidates) {
        Write-Host "Recent candidates in raw:"
        $candidates | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }
    }
    Fail "Synced file not found in SMB raw within $TimeoutSec seconds (expected name like ${stem}_${epochUtc or epochLocal}_<hash>${ext})"
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
    Write-Host "Waiting for USB volume to detach..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $gone = -not (Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($gone) { break }
        Start-Sleep -Seconds $PollSec
    }
    if (-not $gone) {
        Fail "USB volume did not detach within $TimeoutSec seconds"
    }
    Pass "USB volume detached"

    Write-Host "Waiting for USB volume to reattach..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $newVol = $null
    while ((Get-Date) -lt $deadline) {
        $newVol = Get-Volume -FileSystemLabel $UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($newVol) { break }
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

Write-Host "== Summary =="
Write-Host "PASS (client)"
