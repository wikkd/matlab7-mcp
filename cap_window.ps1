# CAP_WINDOW.PS1  Capture a window by title substring to PNG (ZCode MCP helper).
# Usage: powershell -ExecutionPolicy Bypass -File cap_window.ps1 -Title "Scope" ^
#          -Out "C:\path\out.png" [-ResizeWidth 1250] [-ResizeHeight 900] [-Topmost 1]
param(
    [Parameter(Mandatory=$true)][string]$Title,
    [Parameter(Mandatory=$true)][string]$Out,
    [int]$ResizeWidth = 0,
    [int]$ResizeHeight = 0,
    [int]$Topmost = 1
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static System.Collections.Generic.List<IntPtr> Found = new System.Collections.Generic.List<IntPtr>();
    public static string Target = "";
    public static bool Cb(IntPtr h, IntPtr lp) {
        if (!IsWindowVisible(h)) return true;
        var sb = new System.Text.StringBuilder(512);
        GetWindowText(h, sb, 512);
        string t = sb.ToString();
        if (t.Length > 0 && t.IndexOf(Target, StringComparison.OrdinalIgnoreCase) >= 0) Found.Add(h);
        return true;
    }
    public static IntPtr FindByTitle(string title) {
        Found.Clear(); Target = title;
        EnumWindows(Cb, IntPtr.Zero);
        if (Found.Count == 0) return IntPtr.Zero;
        return Found[0];
    }
}
"@

$hwnd = [WinCap]::FindByTitle($Title)
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "NOTFOUND"; exit 1 }

# restore if minimized
$TOPMOST = New-Object System.Intptr(-1)
$NOTOP = New-Object System.Intptr(-2)
[WinCap]::SetWindowPos($hwnd, $TOPMOST, 0, 0, 0, 0, 0x0041) | Out-Null
Start-Sleep -Milliseconds 250
if ($ResizeWidth -gt 0 -and $ResizeHeight -gt 0) {
    [WinCap]::SetWindowPos($hwnd, $TOPMOST, 0, 0, $ResizeWidth, $ResizeHeight, 0x0004) | Out-Null
    Start-Sleep -Milliseconds 350
}
Start-Sleep -Milliseconds 250

$r = New-Object WinCap+RECT
[WinCap]::GetWindowRect($hwnd, [ref]$r) | Out-Null
if ($r.L -le -30000) { Write-Output "MINIMIZED"; exit 2 }
$w = $r.R - $r.L; $h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { Write-Output "BADRECT ${w}x${h}"; exit 3 }

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
if ($Topmost -eq 1) { [WinCap]::SetWindowPos($hwnd, $NOTOP, 0, 0, 0, 0, 0x0051) | Out-Null }
Write-Output "OK $w x $h -> $Out"
