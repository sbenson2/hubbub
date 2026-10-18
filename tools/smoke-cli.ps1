# Local smoke test of the hubbub CLI over the real n0 relays: two roots on this PC.
# Create a server, invite, join by link, then text both ways. Run from the repo root:
#   powershell -File tools\smoke-cli.ps1
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot '..\target\debug\hubbub.exe'
cargo build -p hubbub-cli
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("hubbub-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$a = Join-Path $tmp 'a'; $b = Join-Path $tmp 'b'
$sw = [Diagnostics.Stopwatch]::StartNew()
function Say($m) { Write-Host ("[{0,5:N1}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
function Hb($root) { $o = & $exe --root $root @args; if ($LASTEXITCODE -ne 0) { throw "hubbub $args failed" }; if ($o) { ($o | Select-Object -Last 1).ToString().Trim() } }

# A run process with captured output and a writable stdin.
function Start-Run($root, $cid, $label, $extra = '') {
  $psi = New-Object Diagnostics.ProcessStartInfo $exe
  $psi.Arguments = "--root `"$root`" $extra run --community $cid"
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $p = New-Object Diagnostics.Process; $p.StartInfo = $psi
  $lines = New-Object Collections.Concurrent.ConcurrentQueue[string]
  $h = { if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } }
  Register-ObjectEvent $p OutputDataReceived -Action $h -MessageData $lines | Out-Null
  Register-ObjectEvent $p ErrorDataReceived -Action { if ($EventArgs.Data) { Write-Host "  [$($Event.MessageData)] $($EventArgs.Data)" } } -MessageData $label | Out-Null
  $p.Start() | Out-Null; $p.BeginOutputReadLine(); $p.BeginErrorReadLine()
  [pscustomobject]@{ Proc = $p; Lines = $lines }
}
function Wait-Line($r, $needle, $secs) {
  $end = (Get-Date).AddSeconds($secs)
  while ((Get-Date) -lt $end) {
    foreach ($l in $r.Lines.ToArray()) { if ($l -like "*$needle*") { return $true } }
    Start-Sleep -Milliseconds 300
  }
  $false
}

$procs = @()
try {
  # Text needs a host, and a host needs LiveKit: A hosts, B (same PC, same ports) is text-only.
  $lk = (Resolve-Path (Join-Path $PSScriptRoot '..\vendor\livekit\windows-amd64\livekit-server.exe')).Path
  Hb $a profile name Alice | Out-Null
  Hb $b profile name Bob | Out-Null
  $cid = Hb $a --livekit-bin $lk community new SmokeLab
  Say "created $cid"
  $link = Hb $a --livekit-bin $lk invite $cid --hours 1 --uses 1
  Say "invite $($link.Substring(0, [Math]::Min(40, $link.Length)))..."
  $ra = Start-Run $a $cid 'A' "--livekit-bin `"$lk`""; $procs += $ra.Proc
  Start-Sleep -Seconds 5
  $bcid = Hb $b join $link
  Say "B joined $bcid"
  if ($bcid -ne $cid) { throw "joined id $bcid differs from $cid" }
  $rb = Start-Run $b $cid 'B'; $procs += $rb.Proc
  Start-Sleep -Seconds 5
  if (-not (Wait-Line $ra '"is_me":true' 60)) { throw 'A never became host' }
  Say 'A hosts'
  $ra.Proc.StandardInput.WriteLine('#general hello from A'); $ra.Proc.StandardInput.Flush()
  if (-not (Wait-Line $rb 'hello from A' 60)) { throw 'B never saw the text from A' }
  Say 'A -> B ok'
  $rb.Proc.StandardInput.WriteLine('#general hello from B'); $rb.Proc.StandardInput.Flush()
  if (-not (Wait-Line $ra 'hello from B' 60)) { throw 'A never saw the text from B' }
  Say 'B -> A ok'
  Say 'SMOKE PASSED'
} catch {
  Write-Host '--- A events'; $ra.Lines.ToArray() | Write-Host; Write-Host '--- B events'; if ($rb) { $rb.Lines.ToArray() | Write-Host }
  throw
} finally {
  foreach ($p in $procs) { if (-not $p.HasExited) { $p.Kill() } }
  Get-EventSubscriber | Unregister-Event
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
