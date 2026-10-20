# Peak (0..1) each process showed on the default Windows playback device during -Seconds
# seconds, per audio session (process id, path). Used to prove that a test played nothing
# through the speakers: the test's own process must stay at 0 while others may play.
#   powershell -File tools\output-peak.ps1 -Seconds 30
param([int]$Seconds = 10)
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int NotImpl1(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface); }
[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 { int NotImpl1(); int NotImpl2(); int GetSessionEnumerator(out IAudioSessionEnumerator e); }
[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator { int GetCount(out int n); int GetSession(int i, out IAudioSessionControl2 s); }
[Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
  int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(IntPtr n, ref Guid c); int GetIconPath(out IntPtr p);
  int SetIconPath(IntPtr p, ref Guid c); int GetGroupingParam(out Guid g); int SetGroupingParam(ref Guid g, ref Guid c);
  int RegisterAudioSessionNotification(IntPtr n); int UnregisterAudioSessionNotification(IntPtr n);
  int GetSessionIdentifier(out IntPtr i); int GetSessionInstanceIdentifier(out IntPtr i); int GetProcessId(out uint pid);
  int IsSystemSoundsSession(); int SetDuckingPreference(bool opt);
}
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioMeterInformation { int GetPeakValue(out float peak); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public static class SessionPeaks {
  public static Dictionary<uint, float> Run(int seconds) {
    var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);
    var iid = typeof(IAudioSessionManager2).GUID; object o; dev.Activate(ref iid, 23, IntPtr.Zero, out o);
    var mgr = (IAudioSessionManager2)o;
    var max = new Dictionary<uint, float>(); var end = DateTime.UtcNow.AddSeconds(seconds);
    while (DateTime.UtcNow < end) {
      IAudioSessionEnumerator e; mgr.GetSessionEnumerator(out e); int n; e.GetCount(out n);
      for (int i = 0; i < n; i++) {
        IAudioSessionControl2 c; e.GetSession(i, out c); uint pid; c.GetProcessId(out pid);
        float p; ((IAudioMeterInformation)c).GetPeakValue(out p);
        float old; if (!max.TryGetValue(pid, out old) || p > old) max[pid] = p;
      }
      System.Threading.Thread.Sleep(10);
    }
    return max;
  }
}
"@
$m = [SessionPeaks]::Run($Seconds)
foreach ($k in $m.Keys) {
  $path = ""
  try { $path = (Get-Process -Id $k -ErrorAction Stop).Path } catch { }
  Write-Output ("session pid={0} peak={1:F5} path={2}" -f $k, $m[$k], $path)
}
Write-Output "done"
