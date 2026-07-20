# Endurance writer — plays the AOI: writes unique ~2MB "images" to the gadget
# drive at a steady rate, forever (or -DurationHours), and records every file's
# SHA256 so verify-mirror.sh can later prove the mirror captured everything.
# The AOI only ever writes and retries after one failed write; NOTHING here may
# be fatal. Log appends use FileShare.ReadWrite + retry because the monitor
# (wc -l) and an alert tail read the same files concurrently — a plain
# Add-Content dies on the sharing violation the moment the reads line up.
param(
  [string]$Drive = "",           # auto-detect the VISIONUSB volume when empty
  [int]$IntervalMs = 1000,
  [int]$SizeKB = 2048,
  [double]$DurationHours = 0,    # 0 = run until stopped
  [string]$OutDir = "D:\endurance-run"
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

if (-not (Test-Path $csv)) { Append-Line $csv "ts,name,sha256,bytes,write_ms" | Out-Null }

$rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$body = New-Object byte[] ($SizeKB * 1024)
$rng.GetBytes($body)
$sha  = [System.Security.Cryptography.SHA256]::Create()

$deadline = if ($DurationHours -gt 0) { (Get-Date).AddHours($DurationHours) } else { [datetime]::MaxValue }
$i = 0
$failStreak = 0
Write-Host "endurance writer: $Drive every ${IntervalMs}ms, $SizeKB KB/file, log: $csv"
while ((Get-Date) -lt $deadline) {
  try {
    $i++
    $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
    $name = "END_{0}_{1:D6}.jpg" -f $ts, $i
    $hdr = [Text.Encoding]::ASCII.GetBytes(("{0}|{1}" -f $name, [guid]::NewGuid()).PadRight(64).Substring(0, 64))
    [Array]::Copy($hdr, 0, $body, 0, 64)
    $hash = ([BitConverter]::ToString($sha.ComputeHash($body)) -replace "-", "").ToLower()
    $t0 = Get-Date
    try {
      [IO.File]::WriteAllBytes((Join-Path "$Drive\" $name), $body)
      $ms = [int]((Get-Date) - $t0).TotalMilliseconds
      Append-Line $csv ("{0},{1},{2},{3},{4}" -f (Get-Date -Format o), $name, $hash, $body.Length, $ms) | Out-Null
      $failStreak = 0
    } catch {
      # The drive can vanish for real (PC sleep, cable pulled) and come back
      # under a different letter — re-detect it, and throttle the alert stream
      # to one line per 30 consecutive failures so an unattended outage does
      # not flood the log at the write cadence.
      $failStreak++
      if ($failStreak -eq 1 -or ($failStreak % 30) -eq 0) {
        Append-Line $alerts ("{0} ALERT writer: write failed (streak {1}) for {2}: {3}" -f (Get-Date -Format o), $failStreak, $name, $_.Exception.Message) | Out-Null
      }
      $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object FileSystemLabel -eq "VISIONUSB" | Select-Object -First 1
      if ($vol -and $vol.DriveLetter) { $Drive = "$($vol.DriveLetter):" }
      Start-Sleep -Seconds 3
    }
  } catch {
    # belt and braces: the writer must outlive any surprise
    Start-Sleep -Seconds 3
  }
  Start-Sleep -Milliseconds $IntervalMs
}
Write-Host "endurance writer: done ($i files)"
