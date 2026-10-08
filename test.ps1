# Framelift Windows link test - runs under Windows PowerShell 5.1 on a GitHub Windows runner.
$ErrorActionPreference = 'Stop'
$script:fail = 0
$script:lines = New-Object System.Collections.ArrayList
function Check($ok, [string]$msg) { $l = $(if ($ok) { "PASS  $msg" } else { "FAIL  $msg" }); Write-Host $l; [void]$script:lines.Add($l); if (-not $ok) { $script:fail++ } }
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $([Environment]::OSVersion.VersionString)"
$enc = New-Object Text.UTF8Encoding($false)
# same shape as C:\Users\Andre\AppData\Roaming\Framelift\relay, with spaces and an accented letter
$dir = Join-Path $env:RUNNER_TEMP ("Framelift Andr" + [char]0x00E9 + " test\relay")
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item relay.ps1 (Join-Path $dir 'relay.ps1'); Copy-Item start.vbs (Join-Path $dir 'start.vbs')
[IO.File]::WriteAllText((Join-Path $dir 'heartbeat.json'), '{"ok":true,"app":"After Effects 25.0","version":"1.14","project":"Job.aep"}', $enc)
function P([string]$n) { Join-Path $dir $n }
function WaitAlive($sec) { $t = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $t) { if ((Test-Path (P 'relay.alive')) -and (Test-Path (P 'relay.port'))) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }

# 1) start exactly like the panel: open the .vbs (ShellExecute = ExtendScript File.execute())
$t0 = Get-Date
Start-Process -FilePath (P 'start.vbs')
Check (WaitAlive 30) ("helper started from start.vbs in " + [int]((Get-Date) - $t0).TotalMilliseconds + " ms")
$pid1 = [int](Get-Content (P 'relay.pid')); $port = (Get-Content (P 'relay.port')).Trim()
$proc = Get-CimInstance Win32_Process -Filter "ProcessId=$pid1"
Check ($proc.Name -eq 'powershell.exe') "runs in Windows PowerShell 5.1 ($($proc.Name), pid $pid1, port $port)"
Write-Host "      $($proc.CommandLine)"
Check ((Get-Process -Id $pid1).MainWindowHandle -eq 0) "no visible window"

# 2) what the Figma plugin does
$st = curl.exe -s "http://localhost:$port/status"
Check ($st -match '"relay":"1.14"' -and $st -match '"asleep":false') "status: $st"
$h = (curl.exe -s -i -X OPTIONS "http://localhost:$port/import") -join "`n"
Check ($h -match 'Access-Control-Allow-Private-Network: true' -and $h -match 'Access-Control-Allow-Origin: \*') "browser pre-flight answered"
$age = ((Get-Date) - (Get-Item (P 'relay.alive')).LastWriteTime).TotalSeconds
Check ($age -lt 5) ("alive file fresh (" + [int]$age + " s old)")
$big = Join-Path $env:RUNNER_TEMP 'big.bin'; $bytes = New-Object byte[] 31457280; (New-Object Random 7).NextBytes($bytes); [IO.File]::WriteAllBytes($big, $bytes)
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = curl.exe -s -X POST -H "Content-Type: text/plain" --data-binary "@$big" "http://localhost:$port/import?mode=update&target=new&name=Home%20screen"
$sw.Stop()
$id = ([regex]::Match($r, '"id":"(\d+)"')).Groups[1].Value
Check ($id -ne '') "30 MB upload accepted in $($sw.ElapsedMilliseconds) ms: $r"
$fig = P "$id.figae"
Check ((Test-Path $fig) -and ((Get-FileHash $fig).Hash -eq (Get-FileHash $big).Hash)) "upload byte-identical"
Check ((Get-Content (P "$id.query")) -eq 'mode=update&target=new&name=Home%20screen') "send options saved"
$pr = curl.exe -s "http://localhost:$port/result?id=$id"; Check ($pr -match 'pending') "waiting: $pr"
[IO.File]::WriteAllText((P "$id.progress.json"), '{"pending":true,"pct":40,"text":"Building layers"}', $enc)
$pr = curl.exe -s "http://localhost:$port/result?id=$id"; Check ($pr -match '"pct":40') "progress: $pr"
[IO.File]::WriteAllText((P "$id.result.json"), '{"ok":true,"comps":1,"layers":12}', $enc)
$pr = curl.exe -s "http://localhost:$port/result?id=$id"; Check ($pr -match '"layers":12') "result: $pr"
Check (-not (Test-Path (P "$id.result.json"))) "result file cleaned up"

# 3) panel restarting a stuck helper: launcher with the taskkill line, via the command-line fallback
$kill = (Get-Content -Raw start-kill.vbs) -replace '999999', "$pid1"
[IO.File]::WriteAllText((P 'start.vbs'), $kill, $enc)
Remove-Item (P 'relay.alive'), (P 'relay.port') -ErrorAction SilentlyContinue
cmd /c ('wscript.exe //nologo //B "' + (P 'start.vbs') + '"')
Check (WaitAlive 30) "restarted via wscript fallback"
Start-Sleep 1
$pid2 = [int](Get-Content (P 'relay.pid'))
Check ($pid2 -ne $pid1 -and -not (Get-Process -Id $pid1 -ErrorAction SilentlyContinue)) "old helper $pid1 stopped, new $pid2 running"
Check ((Get-Content (P 'relay.port')).Trim() -eq '7239') "new helper back on port 7239"
$st = curl.exe -s "http://localhost:7239/status"; Check ($st -match '"ok":true') "status after restart"

# 4) unticking "Receive from Figma"
[IO.File]::WriteAllText((P 'relay.stop'), 'stop', $enc)
Start-Sleep 5
Check (-not (Get-Process -Id $pid2 -ErrorAction SilentlyContinue)) "helper exits on stop"
Check (-not (Test-Path (P 'relay.pid'))) "pid file removed"
Write-Host "--- relay.log"; Get-Content (P 'relay.log')
$sum = ("PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)`n" + ($script:lines -join "`n")) -replace '%', '%25' -replace "`r", '' -replace "`n", '%0A'
Write-Host "::notice title=Framelift results::$sum"
if ($script:fail) { Write-Host "$($script:fail) check(s) FAILED"; exit 1 } else { Write-Host "ALL PASSED" }
