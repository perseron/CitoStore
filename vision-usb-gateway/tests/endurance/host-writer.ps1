# Endurance writer — plays the AOI: writes unique ~2MB "images" to the gadget
# drive at a steady rate, forever (or -DurationHours), and records every file's
# SHA256 so verify-mirror.sh can later prove the mirror captured everything.
# The AOI only ever writes and retries after one failed write; errors here are
# logged and retried the same way, never fatal.
param(
  [string]$Drive = "",           # auto-detect the VISIONUSB volume when empty
  [int]$IntervalMs = 1000,
  [int]$SizeKB = 2048,
  [double]$DurationHours = 0,    # 0 = run until stopped
  [string]$OutDir = "D:\endurance-run"
)
$ErrorActionPreference = "Stop"

if (-not $Drive) {
  $vol = Get-Volume | Where-Object FileSystemLabel -eq "VISIONUSB" | Select-Object -First 1
  if (-not $vol) { throw "VISIONUSB volume not found" }
  $Drive = "$($vol.DriveLetter):"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$csv    = Join-Path $OutDir "writer.csv"
$alerts = Join-Path $OutDir "alerts.log"
if (-not (Test-Path $csv)) { "ts,name,sha256,bytes,write_ms" | Out-File -Encoding ascii $csv }

$rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$body = New-Object byte[] ($SizeKB * 1024)
$rng.GetBytes($body)
$sha  = [System.Security.Cryptography.SHA256]::Create()

$deadline = if ($DurationHours -gt 0) { (Get-Date).AddHours($DurationHours) } else { [datetime]::MaxValue }
$i = 0
Write-Host "endurance writer: $Drive every ${IntervalMs}ms, $SizeKB KB/file, log: $csv"
while ((Get-Date) -lt $deadline) {
  $i++
  $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
  $name = "END_{0}_{1:D6}.jpg" -f $ts, $i
  # 64-byte unique header over the shared random body -> every file hashes differently
  $hdr = [Text.Encoding]::ASCII.GetBytes(("{0}|{1}" -f $name, [guid]::NewGuid()).PadRight(64).Substring(0, 64))
  [Array]::Copy($hdr, 0, $body, 0, 64)
  $hash = ([BitConverter]::ToString($sha.ComputeHash($body)) -replace "-", "").ToLower()
  $t0 = Get-Date
  try {
    [IO.File]::WriteAllBytes((Join-Path "$Drive\" $name), $body)
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    "{0},{1},{2},{3},{4}" -f (Get-Date -Format o), $name, $hash, $body.Length, $ms | Add-Content -Encoding ascii $csv
  } catch {
    "{0} ALERT writer: write failed for {1}: {2}" -f (Get-Date -Format o), $name, $_.Exception.Message |
      Add-Content -Encoding ascii $alerts
    Start-Sleep -Seconds 3
  }
  Start-Sleep -Milliseconds $IntervalMs
}
Write-Host "endurance writer: done ($i files)"
