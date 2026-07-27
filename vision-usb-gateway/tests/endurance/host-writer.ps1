# Endurance writer — plays the AOI: writes unique ~2MB "images" to the gadget
# drive, forever (or -DurationHours), and records every file's SHA256 so
# verify-mirror.sh can later prove the mirror captured everything.
# The AOI only ever writes and retries after one failed write; NOTHING here may
# be fatal. Log appends use FileShare.ReadWrite + retry because the monitor
# (wc -l) and an alert tail read the same files concurrently — a plain
# Add-Content dies on the sharing violation the moment the reads line up.
#
# Default cadence is BURST, not steady: the real AOI saves ~12 images back to
# back (one inspection cycle) every ~6s (waiting for the next part), not one
# image every second. A rotation landing INSIDE a ~1.6-2s burst is a very
# different collision scenario than one landing in a steady 1/s stream — the
# quiet windows between bursts are ~4s+, far longer than the ~0.85s gaps a
# steady cadence gives the switch mechanism to work with. Pass -BurstSize 0
# for the old steady-cadence behaviour (one file every -IntervalMs).
#
# Folder layout mirrors the real AOI (deployed units use this 4-level tree,
# not a flat drop): <date>[_N]\<SceneGroup>\<Scene>\<OK|NG>\file.jpg. The
# date-folder is capped at -MaxPerDateFolder images TOTAL across every
# scene/OK-NG combination under it; once full, a new suffixed sibling
# (_2, _3, ...) opens for the rest of that day. This depth is why
# SYNC_SCAN_DEPTH matters here — verify it matches this layout before trusting
# a run against a real-shaped drive.
param(
  [string]$Drive = "",           # auto-detect the VISIONUSB volume when empty
  [int]$IntervalMs = 1000,       # steady-cadence gap; only used when BurstSize = 0
  [int]$BurstSize = 12,          # images per burst; 0 = steady cadence instead
  [double]$BurstPeriodSec = 6,   # wall-clock time from one burst start to the next
  [int]$SizeKB = 2048,
  [double]$DurationHours = 0,    # 0 = run until stopped
  [string]$OutDir = "D:\endurance-run",
  [string[]]$SceneGroups = @("SG1", "SG2"),
  [string[]]$Scenes = @("Scene1", "Scene2"),
  [double]$OkRatio = 0.9,        # fraction classified OK vs NG
  [int]$MaxPerDateFolder = 1000, # cap per date-folder (all scenes/OK-NG combined)
  [string]$PrefixPath = ""       # constant leading folders, e.g. "VisionData\Line1" — emulates a repointed AOI save path
)
$ErrorActionPreference = "Continue"

if (-not $Drive) {
  $vol = Get-Volume | Where-Object FileSystemLabel -eq "VISIONUSB" | Select-Object -First 1
  if (-not $vol) { throw "VISIONUSB volume not found" }
  $Drive = "$($vol.DriveLetter):"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$csv    = Join-Path $OutDir "writer.csv"
$alerts = Join-Path $OutDir "alerts.log"

function Append-Line([string]$path, [string]$line) {
  for ($a = 0; $a -lt 5; $a++) {
    try {
      $fs = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
      $sw = New-Object IO.StreamWriter($fs, [Text.Encoding]::ASCII)
      $sw.WriteLine($line)
      $sw.Dispose()
      return $true
    } catch { Start-Sleep -Milliseconds 200 }
  }
  return $false
}

if (-not (Test-Path $csv)) { Append-Line $csv "ts,name,sha256,bytes,write_ms,relpath" | Out-Null }

$rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$body = New-Object byte[] ($SizeKB * 1024)
$rng.GetBytes($body)
$sha  = [System.Security.Cryptography.SHA256]::Create()

$script:i = 0
$script:failStreak = 0
$script:dateFolder = ""
$script:dateSuffix = 1
$script:dateFolderCount = 0

# Picks (and rolls over) the date-folder: a fresh unsuffixed folder each real
# calendar day, or an incrementing _N sibling the same day once the previous
# one hit -MaxPerDateFolder (total images, all scenes/OK-NG combined — this
# is a whole-day-folder cap, not a per-leaf one).
function Get-DateFolder {
  $today = Get-Date -Format "yyyy-MM-dd"
  if ($script:dateFolder -notlike "$today*") {
    $script:dateFolder = $today
    $script:dateSuffix = 1
    $script:dateFolderCount = 0
  }
  if ($script:dateFolderCount -ge $MaxPerDateFolder) {
    $script:dateSuffix++
    $script:dateFolder = "{0}_{1}" -f $today, $script:dateSuffix
    $script:dateFolderCount = 0
  }
  return $script:dateFolder
}

function Write-OneProbe {
  $script:i++
  $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
  $name = "END_{0}_{1:D6}.jpg" -f $ts, $script:i
  $hdr = [Text.Encoding]::ASCII.GetBytes(("{0}|{1}" -f $name, [guid]::NewGuid()).PadRight(64).Substring(0, 64))
  [Array]::Copy($hdr, 0, $body, 0, 64)
  $hash = ([BitConverter]::ToString($sha.ComputeHash($body)) -replace "-", "").ToLower()

  $dateFolder = Get-DateFolder
  $sg    = $SceneGroups[$script:i % $SceneGroups.Count]
  $scene = $Scenes[[math]::Floor($script:i / $SceneGroups.Count) % $Scenes.Count]
  $okng  = if ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt $OkRatio) { "OK" } else { "NG" }
  $relDir = Join-Path (Join-Path (Join-Path $dateFolder $sg) $scene) $okng
  if ($PrefixPath) { $relDir = Join-Path $PrefixPath $relDir }
  $destDir = Join-Path "$Drive\" $relDir

  $t0 = Get-Date
  try {
    New-Item -ItemType Directory -Force $destDir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $destDir $name), $body)
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    $script:dateFolderCount++
    Append-Line $csv ("{0},{1},{2},{3},{4},{5}" -f (Get-Date -Format o), $name, $hash, $body.Length, $ms, (Join-Path $relDir $name)) | Out-Null
    $script:failStreak = 0
  } catch {
    # The drive can vanish for real (PC sleep, cable pulled) and come back
    # under a different letter — re-detect it, and throttle the alert stream
    # to one line per 30 consecutive failures so an unattended outage does
    # not flood the log at the write cadence.
    $script:failStreak++
    if ($script:failStreak -eq 1 -or ($script:failStreak % 30) -eq 0) {
      Append-Line $alerts ("{0} ALERT writer: write failed (streak {1}) for {2}: {3}" -f (Get-Date -Format o), $script:failStreak, $name, $_.Exception.Message) | Out-Null
    }
    $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object FileSystemLabel -eq "VISIONUSB" | Select-Object -First 1
    if ($vol -and $vol.DriveLetter) { $script:Drive = "$($vol.DriveLetter):" }
    Start-Sleep -Seconds 3
  }
}

$deadline = if ($DurationHours -gt 0) { (Get-Date).AddHours($DurationHours) } else { [datetime]::MaxValue }

if ($BurstSize -gt 0) {
  Write-Host "endurance writer: $Drive BURST mode: $BurstSize images back-to-back every ${BurstPeriodSec}s, log: $csv"
  while ((Get-Date) -lt $deadline) {
    $burstStart = Get-Date
    for ($b = 0; $b -lt $BurstSize; $b++) {
      try { Write-OneProbe } catch { Start-Sleep -Seconds 3 }
    }
    $elapsedMs = ((Get-Date) - $burstStart).TotalMilliseconds
    $remainMs = ($BurstPeriodSec * 1000) - $elapsedMs
    if ($remainMs -gt 0) { Start-Sleep -Milliseconds $remainMs }
  }
} else {
  Write-Host "endurance writer: $Drive every ${IntervalMs}ms, $SizeKB KB/file, log: $csv"
  while ((Get-Date) -lt $deadline) {
    try { Write-OneProbe } catch { Start-Sleep -Seconds 3 }
    Start-Sleep -Milliseconds $IntervalMs
  }
}
Write-Host "endurance writer: done ($script:i files)"
