param(
    [string]$UsbLabel = "VISIONUSB",
    [string]$ShareHost = "192.168.2.162",
    [string]$ShareName = "vision_mirror",
    [string]$SmbUser = "smbuser",
    [string]$SmbPass = "citomat",
    [int]$TimeoutSec = 180,
    [int]$PollSec = 5,
    [int]$LoadFileSizeMB = 2,
    [int]$LoadIntervalSec = 1,
    [int]$LoadDurationSec = 0,
    [int]$LoadFileCount = 0,
    [int]$LoadTargetUsedPercent = 85,
    [int]$LoadReserveFreePercent = 5,
    [int]$LoadMaxAutoFiles = 20000,
    [switch]$SkipRotateCheck,
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

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Host ""
    Write-Host ("-- STEP: {0}" -f $Name) -ForegroundColor Cyan
    try {
        & $Action
    } catch {
        Fail "$Name failed: $($_.Exception.Message)"
    }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Fail "$Name failed with exit code $LASTEXITCODE"
    }
    Pass "$Name"
}

if ($ShareHost -eq "") {
    Fail "ShareHost is required (CM5 IP/hostname)"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$functionalScript = Join-Path $scriptRoot "vision-functional.ps1"
$loadScript = Join-Path $scriptRoot "vision-load.ps1"

if (-not (Test-Path $functionalScript)) {
    Fail "Missing script: $functionalScript"
}
if (-not (Test-Path $loadScript)) {
    Fail "Missing script: $loadScript"
}

Show-Banner "Vision USB Gateway full functional test (Windows client)"
Write-Host ("[INFO] Target: {0}  Share: {1}  Label: {2}" -f $ShareHost, $ShareName, $UsbLabel) -ForegroundColor Cyan

$commonParams = @{
    UsbLabel = $UsbLabel
    ShareHost = $ShareHost
    ShareName = $ShareName
    TimeoutSec = $TimeoutSec
    PollSec = $PollSec
}
if ($SmbUser -ne "" -and $SmbPass -ne "") {
    $commonParams.SmbUser = $SmbUser
    $commonParams.SmbPass = $SmbPass
}

Invoke-Step -Name "Baseline sync check" -Action {
    & $functionalScript @commonParams
}

$loadParams = @{
    UsbLabel = $UsbLabel
    FileSizeMB = $LoadFileSizeMB
    IntervalSec = $LoadIntervalSec
}
if ($LoadFileCount -gt 0) {
    $loadParams.FileCount = $LoadFileCount
} elseif ($LoadDurationSec -gt 0) {
    $loadParams.DurationSec = $LoadDurationSec
} else {
    $loadParams.TargetUsedPercent = $LoadTargetUsedPercent
    $loadParams.ReserveFreePercent = $LoadReserveFreePercent
    $loadParams.MaxAutoFiles = $LoadMaxAutoFiles
}
if (-not $SkipRotateCheck.IsPresent) {
    $loadParams.WaitForRotate = $true
}
Invoke-Step -Name "Load phase (write pressure + optional rotation check)" -Action {
    & $loadScript @loadParams
}

$sync2Params = @{}
foreach ($entry in $commonParams.GetEnumerator()) {
    $sync2Params[$entry.Key] = $entry.Value
}
if ($Cleanup.IsPresent) {
    $sync2Params.Cleanup = $true
}
Invoke-Step -Name "Post-load sync check" -Action {
    & $functionalScript @sync2Params
}

if ($SkipRotateCheck.IsPresent) {
    Warn "Rotation check was skipped (-SkipRotateCheck)"
}

Show-Banner "Summary"
Write-Host "[PASS] full client suite completed" -ForegroundColor Green
