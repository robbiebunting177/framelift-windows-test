# Framelift relay for Windows (PowerShell 5.1+, built into Windows 10/11).
# Started hidden by the After Effects panel. Receives exports from the Figma plugin on localhost and drops
# them into a folder the panel watches; answers status / progress / result queries. Same protocol as the
# macOS Perl relay. Quits when asked (relay.stop) or when After Effects has been gone for hours.
param([string]$dir)
$VERSION = '1.14'
$enc = New-Object System.Text.UTF8Encoding($false)
$log = Join-Path $dir 'relay.log'
function Log([string]$m) { try { [IO.File]::AppendAllText($log, (Get-Date).ToString('s') + ' ' + $m + "`r`n", $enc) } catch { } }
function WFile([string]$f, [byte[]]$b) {
  [IO.File]::WriteAllBytes("$f.tmp", $b)
  if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
  [IO.File]::Move("$f.tmp", $f)
}
function RText([string]$f) { if (Test-Path -LiteralPath $f) { return [IO.File]::ReadAllText($f, $enc) } return $null }
function HbAge { $f = Join-Path $dir 'heartbeat.json'; if (Test-Path -LiteralPath $f) { return ((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalSeconds } return 1e9 }

try { [IO.File]::WriteAllText($log, '', $enc) } catch { }
$listener = $null; $port = 0
foreach ($p in 7239..7243) {
  try {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
    $l.Start(); $listener = $l; $port = $p; break
  } catch { Log ("port $p busy: " + $_.Exception.Message) }
}
if (-not $listener) { Log 'no free port (7239-7243)'; exit 1 }
WFile (Join-Path $dir 'relay.pid') ($enc.GetBytes([string]$PID))
WFile (Join-Path $dir 'relay.port') ($enc.GetBytes([string]$port))
$stopFile = Join-Path $dir 'relay.stop'
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }
Log "listening on 127.0.0.1:$port (pid $PID, PowerShell $($PSVersionTable.PSVersion))"

$cors = "Access-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`n"
$reasons = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 404 = 'Not Found' }
function Reply($s, [int]$code, [string]$body) {
  $b = $enc.GetBytes($body)
  $h = "HTTP/1.1 $code " + $reasons[$code] + "`r`n" + $cors + "Content-Type: application/json; charset=utf-8`r`nContent-Length: " + $b.Length + "`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($h)
  $s.Write($hb, 0, $hb.Length)
  if ($b.Length) { $s.Write($b, 0, $b.Length) }
  $s.Flush()
}

$aliveFile = Join-Path $dir 'relay.alive'
$lastAlive = [DateTime]::MinValue
while ($true) {
  if (((Get-Date) - $lastAlive).TotalSeconds -ge 2) {
    try { [IO.File]::WriteAllText($aliveFile, [string]$PID, $enc) } catch { }
    $lastAlive = Get-Date
    if (Test-Path -LiteralPath $stopFile) { Log 'stop requested'; break }
    if ((HbAge) -gt 21600) { Log 'After Effects gone for 6 h - quitting'; break }
  }
  if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue }
  $c = $listener.AcceptTcpClient()
  try {
    $c.ReceiveTimeout = 30000; $c.SendTimeout = 30000
    $s = $c.GetStream()
    # request line + headers (up to the blank line)
    $hdr = New-Object System.IO.MemoryStream
    while ($true) {
      $x = $s.ReadByte(); if ($x -lt 0) { break }
      $hdr.WriteByte([byte]$x)
      $n = $hdr.Length
      if ($n -ge 4) { $a = $hdr.GetBuffer(); if ($a[$n - 4] -eq 13 -and $a[$n - 3] -eq 10 -and $a[$n - 2] -eq 13 -and $a[$n - 1] -eq 10) { break } }
      if ($n -gt 65536) { break }
    }
    $lines = [Text.Encoding]::ASCII.GetString($hdr.ToArray()) -split "`r`n"
    $first = $lines[0] -split ' '
    $m = $first[0]; $path = if ($first.Length -gt 1) { $first[1] } else { '/' }
    $len = 0
    foreach ($ln in $lines) { if ($ln -match '^(?i)content-length:\s*(\d+)') { $len = [int]$Matches[1] } }

    if ($m -eq 'OPTIONS') { Reply $s 204 '' }
    elseif ($path -like '/status*') {
      $hb = RText (Join-Path $dir 'heartbeat.json'); $age = HbAge
      if ($hb -ne $null -and $age -lt 300) {
        $asleep = if ($age -gt 8) { 'true' } else { 'false' }
        $hb = $hb -replace '\}\s*$', (',"asleep":' + $asleep + ',"relay":"' + $VERSION + '","port":' + $port + '}')
        Reply $s 200 $hb
      } else { Reply $s 200 '{"ok":false,"error":"After Effects panel not running"}' }
    }
    elseif ($m -eq 'POST' -and $path -match '^/import(\?(.*))?$') {
      $q = [string]$Matches[2]
      $buf = New-Object byte[] $len; $got = 0
      while ($got -lt $len) { $r = $s.Read($buf, $got, $len - $got); if ($r -le 0) { break }; $got += $r }
      if ($got -lt $len) { Reply $s 400 '{"ok":false,"error":"upload incomplete"}' }
      else {
        $id = [string][long]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalSeconds + (Get-Random -Maximum 999999).ToString('000000')
        WFile (Join-Path $dir "$id.query") ($enc.GetBytes($q))
        WFile (Join-Path $dir "$id.figae") $buf          # tmp + rename: AE only ever sees complete files
        Reply $s 200 ('{"ok":true,"queued":true,"id":"' + $id + '"}')
      }
    }
    elseif ($path -match '^/result\?id=(\w+)') {
      $id = $Matches[1]
      $rf = Join-Path $dir "$id.result.json"; $pf = Join-Path $dir "$id.progress.json"
      $r = RText $rf
      if ($r -ne $null) {
        Reply $s 200 $r
        Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
      } else {
        $pp = RText $pf
        if ($pp -ne $null) { Reply $s 200 $pp } else { Reply $s 200 '{"pending":true,"pct":0,"text":"Waiting for After Effects..."}' }
      }
    }
    else { Reply $s 404 '{"ok":false,"error":"unknown endpoint"}' }
  } catch { Log ('request failed: ' + $_.Exception.Message) }
  finally { try { $c.Close() } catch { } }
}
try { $listener.Stop() } catch { }
foreach ($f in @('relay.pid', 'relay.port', 'relay.alive')) { Remove-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue }
