# Checks by hand that the game overlay shows over a borderless window that takes the foreground
# as it opens. EVENT_SYSTEM_FOREGROUND can arrive while GetForegroundWindow() still returns the
# previous window; the watcher must trust the event's window, or the overlay stays hidden.
#
# Hubbub must be running, in a voice call, with the game overlay on and its main window hidden.
# Each run opens overlay-test-window.ps1 -Mode borderless, brings it to the front if Windows
# didn't (both failed before the fix), and expects the overlay window (class HubbubGameOverlay)
# to be hidden before the run and visible within 1.5 s. Exits 1 if any run fails.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\overlay-foreground-check.ps1 -Runs 3
param([ValidateRange(1, 20)][int]$Runs = 3)

Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class OverlayCheck {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  public static IntPtr Find(uint pid) { IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid || !IsWindowVisible(h)) return true;
      var t = new StringBuilder(256); GetWindowText(h, t, 256);
      if (t.ToString().StartsWith("Hubbub overlay test window")) { found = h; return false; } return true; }, IntPtr.Zero);
    return found; }
  public static void Front(IntPtr h) { uint unused; uint other = GetWindowThreadProcessId(GetForegroundWindow(), out unused);
    uint me = GetCurrentThreadId(); AttachThreadInput(me, other, true); BringWindowToTop(h); SetForegroundWindow(h); AttachThreadInput(me, other, false); }
  public static bool OverlayVisible() { IntPtr o = FindWindow("HubbubGameOverlay", null); return o != IntPtr.Zero && IsWindowVisible(o); }
}
"@

$script = Join-Path $PSScriptRoot 'overlay-test-window.ps1'
$failed = 0
for ($run = 1; $run -le $Runs; $run++) {
  for ($i = 0; $i -lt 40 -and [OverlayCheck]::OverlayVisible(); $i++) { Start-Sleep -Milliseconds 50 }
  if ([OverlayCheck]::OverlayVisible()) { Write-Output "run ${run}: FAIL, the overlay was already visible"; $failed++; continue }
  $p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Mode', 'borderless', '-Seconds', '20'
  $window = [IntPtr]::Zero
  for ($i = 0; $i -lt 100 -and $window -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 50; $window = [OverlayCheck]::Find([uint32]$p.Id) }
  if ($window -eq [IntPtr]::Zero) {
    Write-Output "run ${run}: FAIL, the test window never opened"; $failed++
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; continue
  }
  $tookFront = [OverlayCheck]::GetForegroundWindow() -eq $window
  if (-not $tookFront) { [OverlayCheck]::Front($window) }
  $shown = $false
  for ($i = 0; $i -lt 30 -and -not $shown; $i++) { Start-Sleep -Milliseconds 50; $shown = [OverlayCheck]::OverlayVisible() }
  $how = if ($tookFront) { 'took the foreground itself' } else { 'brought to the front' }
  if ($shown) { Write-Output "run ${run}: pass ($how)" } else { Write-Output "run ${run}: FAIL, no overlay after 1.5 s ($how)"; $failed++ }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 800
}
if ($failed) { exit 1 }
