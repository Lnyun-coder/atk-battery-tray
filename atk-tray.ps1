<#
    ATK 鼠标电量托盘插件 (ATK Mouse Battery Tray)
    ---------------------------------------------------------------
    纯 PowerShell + WinForms + Win32 HID 调用，零额外依赖。
    在 Windows 任务栏通知区域常驻显示 ATK 鼠标电量百分比。

    协议来源：抓取官方网页驱动 (https://v3-hub.atkgear.com/) 通过 WebHID
              实际收发的报文后逆向得到，已在 ATK 烈空 Phantom Ultimate
              (VID 0x373B / 8K 接收器 PID 0x12F5) 上实测通过。

    用法:
        powershell -NoProfile -ExecutionPolicy Bypass -File atk-battery-tray.ps1
    参数:
        -IntervalSeconds <int>   刷新间隔秒数，默认 60
        -DryRun                  只读一次电量并打印，不创建托盘图标（排错用）
        -VerboseLog              在控制台输出每次读取结果
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 12,
    [switch]$AllowMulti,
    [switch]$LauncherMode,
    [switch]$TestMenu,
    [switch]$DryRun,
    [switch]$VerboseLog
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

# ---------------------------------------------------------------------------
# 单实例保护
#   开机自启 + 手动启动会产生多个实例，它们共用 status.txt / refresh.req，
#   互相抢文件会导致图标异常、菜单空白等现象。这里用命名互斥体拦住。
#   （调试时加 -AllowMulti 可跳过）
# ---------------------------------------------------------------------------
if (-not $AllowMulti -and -not $TestMenu) {
    if (-not ('AtkSingleInstance' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Threading;
public static class AtkSingleInstance
{
    static Mutex _m;
    public static bool Acquire()
    {
        bool created;
        _m = new Mutex(true, @"Local\AtkBatteryTray_SingleInstance", out created);
        if (created) return true;
        // 已存在同名互斥体 → 说明已有实例在跑
        try { _m.Dispose(); } catch { }
        _m = null;
        return false;
    }
    public static void Release()
    {
        if (_m == null) return;
        try { _m.ReleaseMutex(); } catch { }
        try { _m.Dispose(); } catch { }
        _m = null;
    }
}
"@
    }
    if (-not [AtkSingleInstance]::Acquire()) {
        Write-Host ''
        Write-Host '  ATK 电量插件已经在运行了。' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  请看任务栏右下角的圆环电量图标。' -ForegroundColor Gray
        Write-Host '  如果看不到，可能是被收进了「^」折叠菜单：' -ForegroundColor Gray
        Write-Host '    设置 - 个性化 - 任务栏 - 其他系统托盘图标 - 打开「ATK 鼠标电量」' -ForegroundColor Gray
        Write-Host ''
        if ($LauncherMode) { Start-Sleep -Seconds 4 }
        exit 0
    }
}

# ---------------------------------------------------------------------------
# HID 底层 + ATK 协议实现
# ---------------------------------------------------------------------------
if (-not ('AtkHid' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

public static class AtkHid
{
    // ==== 常量（由抓包确认）====
    public const ushort ATK_VID      = 0x373B;   // ATK / VXE / Pulsar 共用
    public const byte   REPORT_ID    = 0x08;     // 厂商集合 0xFF05 的输出报告 ID
    public const byte   HDR_72       = 0x72;     // 帧固定标记
    public const byte   HDR_3A       = 0x3A;     // 回包固定标记
    public const int    FRAME_LEN    = 64;       // 报告长度（含报告 ID）

    // 电量寄存器：回包 72 00 3A 00 07 01 <电量%> <充电标志>
    public const byte   BAT_ADDR_HI  = 0x07;
    public const byte   BAT_ADDR_LO  = 0x01;

    /// <summary>一次电量读数</summary>
    public class BatteryReading
    {
        public bool   Ok;
        public int    Level = -1;      // 0-100
        public bool   Charging;
        public string DeviceName = "";
        public string Error = "";
    }

    /// <summary>一个可用的 ATK 厂商命令接口</summary>
    public class CmdIface { public string Path; public string Name; public ushort Pid, InLen, OutLen; }

    // ---------------- Win32 ----------------
    [StructLayout(LayoutKind.Sequential)]
    struct SP_IFACE { public int cbSize; public Guid g; public int flags; public IntPtr res; }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    static extern bool HidD_GetProductString(IntPtr h, StringBuilder b, int n);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr pp, out CAPS c);

    [StructLayout(LayoutKind.Sequential)]
    struct CAPS
    {
        public ushort Usage, UsagePage, InLen, OutLen, FeatLen;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] R;
        public ushort N, IB, IV, II, OB, OV, OI, FB, FV, FI;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr h, int f);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr di, ref Guid g, int i, ref SP_IFACE d);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_IFACE d, IntPtr detail, int sz, out int req, IntPtr di);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string n, uint a, uint sh, IntPtr sec, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, byte[] b, int n, out int w, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] b, int n, out int r, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResult(IntPtr h, IntPtr ov, out int t, bool wait);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CancelIo(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateEvent(IntPtr s, bool m, bool i, string n);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint SHARE_RW = 3, OPEN_EXISTING = 3, FLAG_OVERLAPPED = 0x40000000;
    const int DIGCF_PRESENT = 2, DIGCF_DEVICEINTERFACE = 0x10;

    // ------------------------------------------------------------------
    // 网页驱动发给鼠标并按顺序得到回应的 9 条命令（抓包原样）
    // 设备只接受这一组已知帧；我们按同样顺序发送，并从中取出电量寄存器 0x0701
    // ------------------------------------------------------------------
    static readonly byte[][] KNOWN_FRAMES = new byte[][]
    {
        new byte[] { 0xCB, 0x72, 0x08, 0x00, 0x01, 0x4A, 0x06 },
        new byte[] { 0x97, 0x72, 0x05, 0x00, 0x01, 0x1C, 0x03 },
        new byte[] { 0xF7, 0x72, 0x03, 0x00, 0x00, 0x81, 0x01 },
        new byte[] { 0x9A, 0x72, 0x03, 0x00, 0x01, 0x23, 0x01 },
        new byte[] { 0x7D, 0x72, 0x02, 0x00, 0x01, 0x07, 0x01 },   // <-- 电量
        new byte[] { 0x85, 0x72, 0x02, 0x00, 0x01, 0x0F, 0x01 },
        new byte[] { 0x2B, 0x72, 0x06, 0x00, 0x01, 0xAE, 0x04 },
        new byte[] { 0x8F, 0x72, 0x02, 0x00, 0x00, 0x1A, 0x01 },
        new byte[] { 0x02, 0x72, 0x05, 0x00, 0x00, 0x88, 0x03 },
    };

    // 有线（USB 直连 PID 0x1312）：标志字节 = 00，校验和随之不同
    static readonly byte[][] WIRED_FRAMES = new byte[][]
    {
        new byte[] { 0xCA, 0x72, 0x08, 0x00, 0x00, 0x4A, 0x06 },
        new byte[] { 0x96, 0x72, 0x05, 0x00, 0x00, 0x1C, 0x03 },
        new byte[] { 0x7C, 0x72, 0x02, 0x00, 0x00, 0x07, 0x01 },   // <-- 电量寄存器 0x0701
        new byte[] { 0x84, 0x72, 0x02, 0x00, 0x00, 0x0F, 0x01 },
        new byte[] { 0x2A, 0x72, 0x06, 0x00, 0x00, 0xAE, 0x04 },
        new byte[] { 0x8F, 0x72, 0x02, 0x00, 0x00, 0x1A, 0x01 },
    };

    // 8K 无线接收器的 PID；其余（如 0x1312）视为有线直连
    const ushort DONGLE_PID = 0x12F5;


    // ------------------------------------------------------------------
    // 系统电源状态：判断"交流电是否接入"（笔记本/带供电的充电底座）
    // ------------------------------------------------------------------
    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS sps);

    /// <summary>交流电是否接入（1=接入, 0=未接入, 255=未知）</summary>
    public static int AcLineStatus()
    {
        try
        {
            SYSTEM_POWER_STATUS s;
            if (GetSystemPowerStatus(out s)) return s.ACLineStatus;
        }
        catch { }
        return 255;
    }

    public static byte[][] GetWirelessFrames() { return KNOWN_FRAMES; }
    public static byte[][] GetWiredFrames() { return WIRED_FRAMES; }
    public static ushort GetDonglePid() { return DONGLE_PID; }
    public static IntPtr OpenDevice(string p) { return CreateFile(p, GENERIC_READ|GENERIC_WRITE, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FLAG_OVERLAPPED, IntPtr.Zero); }
    public static bool IsBadHandle(IntPtr h) { return h == new IntPtr(-1); }
    public static void CloseDevice(IntPtr h) { if (h != new IntPtr(-1)) CloseHandle(h); }
    public static byte[] ToFrame(byte[] known)
    {
        byte[] f = new byte[FRAME_LEN];
        f[0] = REPORT_ID;
        Array.Copy(known, 0, f, 1, known.Length);
        return f;
    }

    /// <summary>枚举 VID 0x373B 上所有「厂商用途页 + 有输出报告」的接口</summary>
    public static List<CmdIface> FindCommandInterfaces()
    {
        var result = new List<CmdIface>();
        Guid guid; HidD_GetHidGuid(out guid);
        IntPtr set = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == new IntPtr(-1)) return result;
        try
        {
            for (int i = 0; ; i++)
            {
                var d = new SP_IFACE(); d.cbSize = Marshal.SizeOf(typeof(SP_IFACE));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref d)) break;
                int req;
                SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                if (req <= 0) continue;
                IntPtr buf = Marshal.AllocHGlobal(req);
                try
                {
                    Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                    var m = Regex.Match(path, @"vid_([0-9a-f]{4})&pid_([0-9a-f]{4})", RegexOptions.IgnoreCase);
                    if (!m.Success) continue;
                    if (Convert.ToUInt16(m.Groups[1].Value, 16) != ATK_VID) continue;

                    IntPtr h = CreateFile(path, 0, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h == new IntPtr(-1)) continue;
                    string name = "";
                    try
                    {
                        var sb = new StringBuilder(256);
                        if (HidD_GetProductString(h, sb, 512)) name = sb.ToString();
                        IntPtr pp;
                        if (!HidD_GetPreparsedData(h, out pp)) continue;
                        try
                        {
                            CAPS c;
                            if (HidP_GetCaps(pp, out c) != 0x110000) continue;
                            if (c.UsagePage == 0xFF05 && c.OutLen > 0)
                            {
                                result.Add(new CmdIface
                                {
                                    Path = path, Name = name,
                                    Pid = Convert.ToUInt16(m.Groups[2].Value, 16),
                                    InLen = c.InLen, OutLen = c.OutLen
                                });
                            }
                        }
                        finally { HidD_FreePreparsedData(pp); }
                    }
                    finally { CloseHandle(h); }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return result;
    }

    static IntPtr AllocOv(out IntPtr ev)
    {
        int sz = IntPtr.Size == 8 ? 32 : 20;
        IntPtr ov = Marshal.AllocHGlobal(sz);
        for (int i = 0; i < sz; i++) Marshal.WriteByte(ov, i, 0);
        ev = CreateEvent(IntPtr.Zero, true, false, null);
        Marshal.WriteIntPtr(ov, IntPtr.Size == 8 ? 24 : 16, ev);
        return ov;
    }

    static void FreeOv(IntPtr ov)
    {
        IntPtr ev = Marshal.ReadIntPtr(ov, IntPtr.Size == 8 ? 24 : 16);
        CloseHandle(ev);
        Marshal.FreeHGlobal(ov);
    }

    static bool WriteFrame(IntPtr h, byte[] f)
    {
        IntPtr ev; IntPtr ov = AllocOv(out ev);
        try
        {
            int n;
            if (WriteFile(h, f, f.Length, out n, ov)) return true;
            if (Marshal.GetLastWin32Error() != 997) return false;
            if (WaitForSingleObject(ev, 250) != 0) { CancelIo(h); return false; }
            int t; GetOverlappedResult(h, ov, out t, false);
            return t == f.Length;
        }
        finally { FreeOv(ov); }
    }

    static byte[] ReadOne(IntPtr h, int inLen, int ms)
    {
        IntPtr ev; IntPtr ov = AllocOv(out ev);
        try
        {
            byte[] buf = new byte[inLen];
            int n;
            if (!ReadFile(h, buf, inLen, out n, ov) && Marshal.GetLastWin32Error() != 997) return null;
            if (WaitForSingleObject(ev, (uint)ms) != 0) { CancelIo(h); return null; }
            int t; GetOverlappedResult(h, ov, out t, false);
            if (t <= 0) return null;
            byte[] r = new byte[t];
            Array.Copy(buf, r, t);
            return r;
        }
        finally { FreeOv(ov); }
    }

    /// <summary>排空之前残留的输入报告</summary>
    static void Drain(IntPtr h, int inLen)
    {
        for (int i = 0; i < 3; i++) if (ReadOne(h, inLen, 10) == null) break;
    }

    /// <summary>发送一帧并收集其回包，返回所有含 72 00 3A 的应答</summary>
    public static List<byte[]> Exchange(IntPtr h, int inLen, byte[] frame)
    {
        var replies = new List<byte[]>();
        Drain(h, inLen);
        if (!WriteFrame(h, frame)) return replies;
        for (int k = 0; k < 3; k++)
        {
            byte[] r = ReadOne(h, inLen, 120);
            if (r == null) break;
            if (r.Length >= 8 && r[1] == HDR_72 && r.Length > 3 && r[3] == HDR_3A) replies.Add(r);
        }
        return replies;
    }

    /// <summary>读取鼠标电量</summary>
    public static BatteryReading ReadBattery()
    {
        var reading = new BatteryReading();
        // 硬性时间预算：设备插拔/切换时 HID 句柄会长时间无响应，
        // 必须限时返回，否则托盘 UI 线程被堵死（表现为整个插件卡住）。
        var budget = Stopwatch.StartNew();
        const int TOTAL_MS = 1200;

        List<CmdIface> ifaces;
        try { ifaces = FindCommandInterfaces(); }
        catch (Exception ex) { reading.Error = "枚举设备失败: " + ex.Message; return reading; }

        if (ifaces.Count == 0)
        {
            reading.Error = "未找到 ATK 设备（VID 0x373B）";
            return reading;
        }
        if (budget.ElapsedMilliseconds > TOTAL_MS)
        {
            reading.Error = "枚举超时（设备正在切换连接）";
            return reading;
        }

        foreach (var iface in ifaces)
        {
            if (budget.ElapsedMilliseconds > TOTAL_MS)
            {
                reading.Error = "读取超时（设备正在切换连接）";
                return reading;
            }
            IntPtr h = CreateFile(iface.Path, GENERIC_READ | GENERIC_WRITE, SHARE_RW,
                                  IntPtr.Zero, OPEN_EXISTING, FLAG_OVERLAPPED, IntPtr.Zero);
            if (h == new IntPtr(-1)) continue;
            try
            {
                int inLen = iface.InLen > 0 ? iface.InLen : FRAME_LEN;
                reading.DeviceName = iface.Name;

                // 接收器用无线帧组，USB 直连用有线帧组
                byte[][] frames = (iface.Pid == DONGLE_PID) ? KNOWN_FRAMES : WIRED_FRAMES;
                foreach (byte[] known in frames)
                {
                    if (budget.ElapsedMilliseconds > TOTAL_MS)
                    {
                        reading.Error = "读取超时（设备正在切换连接）";
                        return reading;
                    }
                    var replies = Exchange(h, inLen, ToFrame(known));
                    foreach (byte[] r in replies)
                    {
                        // 应答格式: 72 00 3A 00 <addrHi> <addrLo> <data...>
                        if (r[5] == BAT_ADDR_HI && r[6] == BAT_ADDR_LO && r.Length > 8)
                        {
                            byte level = r[7];
                            if (level <= 100)
                            {
                                reading.Ok = true;
                                reading.Level = level;
                                // 无线回包 0xFF；有线回包两字节非零 → 统一看后两字节
                            // 充电判定：
                            //   无线 —— 仅 0xFF 表示正在充电（回包为 FF FF / 00 00）
                            //   有线 —— 设备标志字节不可靠，改用系统交流电接入状态
                            // 充电状态：不再上报。
                            //   实测无线回包第 8 字节有约 25% 概率误报 0xFF，
                            //   且无法与「充电底座供电」区分；有线回包该字节含义亦未确认。
                            //   与其显示错误信息，不如只显示电量百分比。
                            //   （如将来确认协议含义，把下面这行改成检测逻辑即可）
                            reading.Charging = false;
                            int _unusedFlag = r.Length > 8 ? r[8] : 0;
                                return reading;
                            }
                        }
                    }
                }
            }
            finally { CloseHandle(h); }
        }

        reading.Error = "设备已连接但未读到电量（鼠标可能未开机或未连上接收器）";
        return reading;
    }

    public static string Hex(byte[] b, int max)
    {
        if (b == null) return "(null)";
        var sb = new StringBuilder();
        for (int i = 0; i < b.Length && i < max; i++) sb.Append(b[i].ToString("X2")).Append(' ');
        return sb.ToString().Trim();
    }
}
'@
}

# ---------------------------------------------------------------------------
# 图标绘制
# ---------------------------------------------------------------------------
function Get-SystemDarkTheme {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop).SystemUsesLightTheme
        return ($v -eq 0)
    } catch { return $true }
}

function New-RoundedPath {
    param([single]$x, [single]$y, [single]$w, [single]$h, [single]$r)
    $d = $r * 2
    if ($d -gt $w) { $d = $w }
    if ($d -gt $h) { $d = $h }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# 只保留配置二（环形电量）。如需恢复三样式切换，把下面改成 $false
$script:LockRingStyle = $true

function Get-BatteryStyle {
    if ($script:LockRingStyle) { return 1 }
    if ($null -eq $script:batStyle) {
        $script:batStyle = 0
        try {
            $v = (Get-ItemProperty "HKCU:\$($script:StyleRegKey)" -Name BatteryStyle -ErrorAction Stop).BatteryStyle
            $script:batStyle = [int]$v % 3
        } catch { }
    }
    return $script:batStyle
}

function Cycle-BatteryStyle {
    $script:batStyle = ((Get-BatteryStyle) + 1) % 3
    try {
        if (-not (Test-Path "HKCU:\$($script:StyleRegKey)")) { New-Item -Path "HKCU:\$($script:StyleRegKey)" -Force | Out-Null }
        Set-ItemProperty -Path "HKCU:\$($script:StyleRegKey)" -Name BatteryStyle -Value $script:batStyle -Type DWord -Force
    } catch { }
    return $script:batStyle
}

function Get-StyleName {
    param([int]$s)
    if ($s -eq 0) { return '经典电池' }
    if ($s -eq 1) { return '环形电量' }
    return '滑轨数字'
}

function Write-AtkPixel {
    param($bmp, [int]$x, [int]$y, $c)
    $w = $bmp.Width; $h = $bmp.Height
    if ($x -ge 0 -and $x -lt $w -and $y -ge 0 -and $y -lt $h) { $bmp.SetPixel($x, $y, $c) }
}

function Fill-RoundRect {
    param($bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1, $col, [int]$rad)
    if ($rad -gt [int](($x1 - $x0) / 2)) { $rad = [int](($x1 - $x0) / 2) }
    if ($rad -gt [int](($y1 - $y0) / 2)) { $rad = [int](($y1 - $y0) / 2) }
    if ($rad -lt 0) { $rad = 0 }
    $r2 = $rad * $rad
    for ($y = $y0; $y -le $y1; $y++) {
        for ($x = $x0; $x -le $x1; $x++) {
            $dx = if ($x -lt $x0 + $rad) { $x0 + $rad - $x } elseif ($x -gt $x1 - $rad) { $x - ($x1 - $rad) } else { 0 }
            $dy = if ($y -lt $y0 + $rad) { $y0 + $rad - $y } elseif ($y -gt $y1 - $rad) { $y - ($y1 - $rad) } else { 0 }
            if ($dx * $dx + $dy * $dy -le $r2) { Write-AtkPixel $bmp $x $y $col }
        }
    }
}

function Draw-Bolt {
    param($bmp, [int]$sx, [int]$sy, $col, [int]$ss)
    $pattern = @('..#', '.##', '###', '.#.', '##.', '#..', '...')
    for ($r = 0; $r -lt 7; $r++) {
        for ($c = 0; $c -lt 3; $c++) {
            if ($pattern[$r][$c] -eq '#') {
                for ($dy = 0; $dy -lt $ss; $dy++) {
                    for ($dx = 0; $dx -lt $ss; $dx++) {
                        Write-AtkPixel $bmp ($sx + $c * $ss + $dx) ($sy + $r * $ss + $dy) $col
                    }
                }
            }
        }
    }
}

function Mix-Color {
    param($a, $b, [double]$t)
    if ($t -lt 0) { $t = 0 }; if ($t -gt 1) { $t = 1 }
    return [System.Drawing.Color]::FromArgb(255,
        [int]($a.R + ($b.R - $a.R) * $t), [int]($a.G + ($b.G - $a.G) * $t), [int]($a.B + ($b.B - $a.B) * $t))
}

function New-BatteryIcon {
    # 逐像素照搬 Iris-0109/rapoo-tray 的 CreateBatteryIcon（MIT）三种样式
    #   0 = 经典纯净电池胶囊   1 = 360° 环形电量圈（充电时为渐变+流动高光）   2 = 大号数字 + 底部横轨
    param([int]$Battery, [bool]$Charging, [bool]$Unknown, [double]$Phase = 0)

    $style = Get-BatteryStyle
    $S = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($S -le 0) { $S = 16 }
    $SS = 4
    $W = $S * $SS; $H = $W
    $isDark = Get-SystemDarkTheme
    $connected = -not $Unknown

    $cShell = if ($isDark) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(255, 51, 65, 85) }
    # 配色按电量阈值：>40% 绿、20~40% 黄、<20% 红；充电时圆环绿色 + 中心闪电
    # 全部纯色（cDark == cLite，无渐变）；充电只靠流动高光区分
    if (-not $connected) { $cState = [System.Drawing.Color]::FromArgb(255, 148, 163, 184) }
    elseif ($Charging) { $cState = [System.Drawing.Color]::FromArgb(255, 34, 197, 94) }
    elseif ($Battery -lt 20) { $cState = [System.Drawing.Color]::FromArgb(255, 239, 68, 68) }
    elseif ($Battery -le 40) { $cState = [System.Drawing.Color]::FromArgb(255, 234, 179, 8) }
    else { $cState = [System.Drawing.Color]::FromArgb(255, 34, 197, 94) }
    $cDark = $cState; $cLite = $cState
    $cGlow = [System.Drawing.Color]::FromArgb(255, 190, 255, 220)

    $unit = $S * $SS
    $L2S = { param($v) [int]($v * $unit / 16.0 + 0.5) }

    [FastRender]::Init($W, $H)
    [FastRender]::Clear()

    if ($style -eq 0) {
        # ---- 配置一：经典电池胶囊 ----
        $bx0 = 0; $by0 = & $L2S 2.5; $bw = & $L2S 13.5; $bh = & $L2S 11.0
        $bx1 = $bx0 + $bw; $by1 = $by0 + $bh
        Fill-RoundRect $big $bx0 $by0 $bx1 $by1 $cShell (& $L2S 2.5)

        $nx0 = & $L2S 13.8; $ny0 = & $L2S 5.2
        $nx1 = [math]::Min($W - 1, $nx0 + (& $L2S 1.8)); $ny1 = $ny0 + (& $L2S 5.6)
        Fill-RoundRect $big $nx0 $ny0 $nx1 $ny1 $cShell (& $L2S 1.0)

        $stk = [int](1.5 * $SS + 0.5)
        $cx0 = $bx0 + $stk; $cy0 = $by0 + $stk; $cx1 = $bx1 - $stk; $cy1 = $by1 - $stk
        Fill-RoundRect $big $cx0 $cy0 $cx1 $cy1 ([System.Drawing.Color]::Transparent) 0

        $pd = [int](0.75 * $SS + 0.5)
        $ix0 = $cx0 + $pd; $iy0 = $cy0 + $pd; $ix1 = $cx1 - $pd; $iy1 = $cy1 - $pd
        $iw = $ix1 - $ix0 + 1; $ih = $iy1 - $iy0 + 1

        if ($connected -and $Battery -gt 0) {
            $ratio = [math]::Min(1.0, [math]::Max(0.08, $Battery / 100.0))
            $fw = [math]::Max((& $L2S 2.0), [int]($iw * $ratio))
            Fill-RoundRect $big $ix0 $iy0 ($ix0 + $fw) $iy1 $cState (& $L2S 1.5)
        } elseif (-not $connected) {
            $cDim = if ($isDark) { [System.Drawing.Color]::FromArgb(64, 96, 96, 96) } else { [System.Drawing.Color]::FromArgb(64, 176, 176, 176) }
            Fill-RoundRect $big $ix0 $iy0 $ix1 $iy1 $cDim (& $L2S 1.5)
            $dw = & $L2S 4.5; $dh = & $L2S 2.0
            $sx = $ix0 + [int](($iw - $dw) / 2); $sy = $iy0 + [int](($ih - $dh) / 2)
            $cBar = if ($isDark) { [System.Drawing.Color]::FromArgb(255, 187, 187, 187) } else { [System.Drawing.Color]::FromArgb(255, 102, 102, 102) }
            Fill-RoundRect $big $sx $sy ($sx + $dw) ($sy + $dh) $cBar 0
        }
        if ($Charging) {
            Draw-Bolt $big ($cx0 + [int](($cx1 - $cx0 + 1 - 3 * $SS) / 2)) ($cy0 + [int](($cy1 - $cy0 + 1 - 7 * $SS) / 2)) ([System.Drawing.Color]::White) $SS
        }
    }
    elseif ($style -eq 1) {
        # ---- 配置二：环形电量圈（纯色圆环；充电时仅高光转动）----
        $ccx = $W / 2.0; $ccy = $H / 2.0
        $R = $unit * 5.8 / 16.0
        $T = $unit * 3.0 / 16.0
        $cTrack = if ($isDark) { [System.Drawing.Color]::FromArgb(64, 255, 255, 255) } else { [System.Drawing.Color]::FromArgb(53, 0, 0, 0) }
        $sweep = if ($connected) { [math]::Min(360.0, [math]::Max(0.0, 360.0 * ($Battery / 100.0))) } else { 0.0 }
        $haveBat = if ($connected -and $Battery -gt 0) { 1 } else { 0 }

        [FastRender]::Ring($ccx, $ccy, $R, $T, $sweep,
            $(if ($connected) { 1 } else { 0 }), $haveBat,
            $cTrack.R, $cTrack.G, $cTrack.B,
            $cDark.R, $cDark.G, $cDark.B,
            $cGlow.R, $cGlow.G, $cGlow.B,
            $(if ($Charging) { 1 } else { 0 }), [double]$Phase, 38.0)

        if (-not $connected) {
            $dw = & $L2S 4.0; $dh = & $L2S 2.0
            $cBar = if ($isDark) { [System.Drawing.Color]::FromArgb(255, 136, 136, 136) } else { [System.Drawing.Color]::FromArgb(255, 102, 102, 102) }
            [FastRender]::RoundRect([int](($W - $dw) / 2), [int](($H - $dh) / 2), [int](($W + $dw) / 2), [int](($H + $dh) / 2), 255, $cBar.R, $cBar.G, $cBar.B, 0)
        }
    }
    else {
        # ---- 配置三：大号数字 + 底部横轨 ----
        $textH = [int]($H * 13.5 / 16.0)
        $text = if ($connected) { "$Battery" } else { '-' }
        $fs = if ($Battery -eq 100) { $H * 52.0 / 100.0 } else { $H * 70.0 / 100.0 }
        $g2 = [System.Drawing.Graphics]::FromImage($big)
        try {
            $g2.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
            $font = New-Object System.Drawing.Font('Segoe UI', [single]$fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            try {
                $fmt = New-Object System.Drawing.StringFormat
                $fmt.Alignment = [System.Drawing.StringAlignment]::Center
                $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
                $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
                $wb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
                try { $g2.DrawString($text, $font, $wb, (New-Object System.Drawing.RectangleF(0, -$SS, $W, $textH)), $fmt) } finally { $wb.Dispose(); $fmt.Dispose() }
            } finally { $font.Dispose() }
        } finally { $g2.Dispose() }

        if (-not $connected) { $target = if ($isDark) { [System.Drawing.Color]::FromArgb(255, 160, 160, 160) } else { [System.Drawing.Color]::FromArgb(255, 100, 100, 100) } }
        elseif ($Charging) { $target = [System.Drawing.Color]::FromArgb(255, 34, 197, 94) }
        elseif ($Battery -le 30) { $target = [System.Drawing.Color]::FromArgb(255, 239, 68, 68) }
        else { $target = if ($isDark) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(255, 20, 20, 20) } }

        for ($y = 0; $y -lt $textH; $y++) {
            for ($x = 0; $x -lt $W; $x++) {
                $raw = $big.GetPixel($x, $y)
                $gray = $raw.A
                if ($gray -gt 0) { $big.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($gray, $target.R, $target.G, $target.B)) }
                else { $big.SetPixel($x, $y, [System.Drawing.Color]::Transparent) }
            }
        }

        $barY0 = [int]($H * 14.0 / 16.0); $barY1 = $H - 1
        $cTrack = if ($isDark) { [System.Drawing.Color]::FromArgb(64, 255, 255, 255) } else { [System.Drawing.Color]::FromArgb(48, 0, 0, 0) }
        Fill-RoundRect $big 0 $barY0 ($W - 1) $barY1 $cTrack ([int]($SS / 2))
        if ($connected -and $Battery -gt 0) {
            $barW = [math]::Min($W, [math]::Max(2 * $SS, [int]($W * ($Battery / 100.0))))
            Fill-RoundRect $big 0 $barY0 ($barW - 1) $barY1 $cState ([int]($SS / 2))
        }
    }

    # ---- 盒式滤波降采样（C# 侧完成，快 20 倍以上）----
    $out = [FastRender]::Downsample($SS)
    $hIcon = $out.GetHicon()
    $out.Dispose()
    return [System.Drawing.Icon]::FromHandle($hIcon)
}

function Get-BatteryText {
    param($Reading)
    if ($null -eq $Reading -or -not $Reading.Ok) { return 'ATK 鼠标：未连接 / 无数据' }
    $s = "ATK 鼠标电量：$($Reading.Level)%"
    # 充电状态已停用（固件标志不可靠），不再附加"充电中"
    # 如将来恢复：if ($Reading.Charging) { $s += '（充电中）' }
    return $s
}

if ($DryRun) {
    Write-Host '正在读取 ATK 鼠标电量…' -ForegroundColor Cyan
    $r = [AtkHid]::ReadBattery()
    if ($r.Ok) {
        Write-Host (Get-BatteryText $r) -ForegroundColor Green
        if ($r.DeviceName) { Write-Host "设备: $($r.DeviceName)" -ForegroundColor DarkGray }
    } else {
        Write-Host "读取失败：$($r.Error)" -ForegroundColor Red
    }
    exit $(if ($r.Ok) { 0 } else { 1 })
}


# ---------------------------------------------------------------------------
# 快速像素层：直接操作字节数组，避免每像素 .NET 调用（充电动画性能关键）
# ---------------------------------------------------------------------------
Add-Type -Language CSharp -ReferencedAssemblies System.Drawing, System.Windows.Forms `
    -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class FastRender
{
    public static int W, H;
    static byte[] _buf;

    public static void Init(int w, int h)
    {
        W = w; H = h;
        _buf = new byte[w * h * 4];
    }

    public static void Clear() { Array.Clear(_buf, 0, _buf.Length); }

    public static void SetPx(int x, int y, int a, int r, int g, int b)
    {
        if (x < 0 || y < 0 || x >= W || y >= H) return;
        int i = (y * W + x) * 4;
        _buf[i] = (byte)b; _buf[i + 1] = (byte)g; _buf[i + 2] = (byte)r; _buf[i + 3] = (byte)a;
    }

    public static void RoundRect(int x0, int y0, int x1, int y1, int a, int r, int g, int b, int rad)
    {
        if (x1 < x0 || y1 < y0) return;
        if (rad > (x1 - x0) / 2) rad = (x1 - x0) / 2;
        if (rad > (y1 - y0) / 2) rad = (y1 - y0) / 2;
        if (rad < 0) rad = 0;
        int r2 = rad * rad;
        for (int y = y0; y <= y1; y++)
        {
            for (int x = x0; x <= x1; x++)
            {
                int dx = (x < x0 + rad) ? (x0 + rad - x) : (x > x1 - rad) ? (x - (x1 - rad)) : 0;
                int dy = (y < y0 + rad) ? (y0 + rad - y) : (y > y1 - rad) ? (y - (y1 - rad)) : 0;
                if (dx * dx + dy * dy <= r2) SetPx(x, y, a, r, g, b);
            }
        }
    }

    public static void Bolt(int sx, int sy, int a, int r, int g, int b, int ss)
    {
        string[] pat = { "..#", ".##", "###", ".#.", "##.", "#..", "..." };
        for (int row = 0; row < 7; row++)
            for (int col = 0; col < 3; col++)
                if (pat[row][col] == '#')
                    for (int dy = 0; dy < ss; dy++)
                        for (int dx = 0; dx < ss; dx++)
                            SetPx(sx + col * ss + dx, sy + row * ss + dy, a, r, g, b);
    }


    // 环形电量圈光栅化（全部在 C# 侧完成，PowerShell 只调用一次）
    //  ang 计算基准：以正上方为 0°，顺时针递增
    //  cGlow 只在高光相位处叠加（高斯衰减）
    public static void Ring(int ccx, int ccy, double R, double T, double sweep,
                            int connected, int haveBattery,
                            int tAr, int tAg, int tAb,
                            int ar, int ag, int ab,
                            int gr, int gg, int gb,
                            int glowing, double phase, double sigma)
    {
        double capR = T / 2.0, capR2 = capR * capR;
        double sweepRad = sweep * Math.PI / 180.0;
        double sxCap = ccx, syCap = ccy - R;
        double exCap = ccx + R * Math.Sin(sweepRad);
        double eyCap = ccy - R * Math.Cos(sweepRad);

        int minX = Math.Max(0, (int)(ccx - R - T)), maxX = Math.Min(W - 1, (int)(ccx + R + T));
        int minY = Math.Max(0, (int)(ccy - R - T)), maxY = Math.Min(H - 1, (int)(ccy + R + T));

        for (int y = minY; y <= maxY; y++)
        {
            for (int x = minX; x <= maxX; x++)
            {
                double px = x + 0.5, py = y + 0.5;
                double dx = px - ccx, dy = py - ccy;
                double dist = Math.Sqrt(dx * dx + dy * dy);

                double ang = Math.Atan2(dx, -dy) * (180.0 / Math.PI);
                if (ang < 0) ang += 360.0;

                int cr = ar, cg = ag, cb = ab;
                if (glowing == 1)
                {
                    double d = Math.Abs(ang - phase);
                    if (d > 180.0) d = 360.0 - d;
                    double w = Math.Exp(-(d * d) / (2.0 * sigma * sigma));
                    cr = (int)(ar + (gr - ar) * w);
                    cg = (int)(ag + (gg - ag) * w);
                    cb = (int)(ab + (gb - ab) * w);
                }

                bool isCap = (connected == 1 && haveBattery == 1) &&
                    (((px - sxCap) * (px - sxCap) + (py - syCap) * (py - syCap) <= capR2) ||
                     ((px - exCap) * (px - exCap) + (py - eyCap) * (py - eyCap) <= capR2));

                if (isCap) { SetPx(x, y, 255, cr, cg, cb); continue; }

                if (Math.Abs(dist - R) <= capR)
                {
                    if (connected == 1 && haveBattery == 1)
                    {
                        if (ang <= sweep) SetPx(x, y, 255, cr, cg, cb);
                        else SetPx(x, y, 255, tAr, tAg, tAb);
                    }
                    else SetPx(x, y, 255, tAr, tAg, tAb);
                }
            }
        }
    }

    public static Bitmap Downsample(int ss)
    {
        int outW = W / ss, outH = H / ss;
        Bitmap bmp = new Bitmap(outW, outH, PixelFormat.Format32bppArgb);
        bmp.SetResolution(96, 96);
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, outW, outH),
                                     ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            byte[] ob = new byte[outW * outH * 4];
            int n = ss * ss;
            for (int y = 0; y < outH; y++)
            {
                for (int x = 0; x < outW; x++)
                {
                    int sa = 0, sr = 0, sg = 0, sb = 0;
                    for (int sy = 0; sy < ss; sy++)
                    {
                        int rowBase = ((y * ss + sy) * W + x * ss) * 4;
                        for (int sx = 0; sx < ss; sx++)
                        {
                            int i = rowBase + sx * 4;
                            int aa = _buf[i + 3];
                            if (aa > 0) { sa += aa; sb += _buf[i]; sg += _buf[i + 1]; sr += _buf[i + 2]; }
                        }
                    }
                    int oi = (y * outW + x) * 4;
                    int avgA = sa / n;
                    if (avgA > 0)
                    {
                        ob[oi]     = (byte)(sb / n * avgA / 255);
                        ob[oi + 1] = (byte)(sg / n * avgA / 255);
                        ob[oi + 2] = (byte)(sr / n * avgA / 255);
                        ob[oi + 3] = (byte)avgA;
                    }
                }
            }
            Marshal.Copy(ob, 0, bd.Scan0, ob.Length);
        }
        finally { bmp.UnlockBits(bd); }
        return bmp;
    }
}
"@

# ---------------------------------------------------------------------------
# 托盘
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:StyleRegKey = 'Software\ATKBatteryTray'
$script:phase = 0.0           # 充电动画相位（度）
$script:curLevel = -1
$script:animTimer = $null
$script:batStyle = $null
$script:busy = $false
$script:lastCharging = $false
$script:pendingCharging = $null
$script:pendingCount = 0
$script:lastTs = 0                # 上次 status.txt 的时间戳
$script:workerProc = $null        # 后台读取进程
$script:StatusFile = Join-Path $PSScriptRoot 'status.txt'
$script:ReqFile = Join-Path $PSScriptRoot 'refresh.req'
$script:WorkerScript = Join-Path $PSScriptRoot 'atk-worker.ps1'

# ---------------------------------------------------------------------------
# 崩溃日志：任何未捕获的异常都记录下来，便于排查"插件莫名退出"
# ---------------------------------------------------------------------------
$script:ErrLog = Join-Path $PSScriptRoot 'atk-error.log'

function Write-ErrLog {
    param([string]$Where, $Err)
    try {
        $tag = if ($Where -match 'STARTUP|MENU-EXIT|SHUTDOWN') { '事件' } else { 'CRASH' }
        $msg = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $tag, $Where, $Err
        Add-Content -Path $script:ErrLog -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# 全局兜底：脚本级未捕获错误
trap {
    Write-ErrLog 'GLOBAL-TRAP' ("$($_.Exception.GetType().Name): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)")
    continue
}

function Invoke-Safe {
    param([string]$Where, [scriptblock]$Body)
    try { & $Body }
    catch {
        Write-ErrLog $Where ("$($_.Exception.GetType().Name): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)")
    }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Icon = New-BatteryIcon -Battery -1 -Charging $false -Unknown $true
$notify.Text = 'ATK 鼠标电量：正在读取…'


# 充电时每 120ms 让高光沿圆环转一步（约 2.4 秒一圈）
function StartStop-TrayAnimation {
    # 充电状态已停用 → 动画不再启动（高光保持静止）
    $want = $false
    if ($want) {
        if ($null -eq $script:animTimer) {
            $script:animTimer = New-Object System.Windows.Forms.Timer
            # 步长小、间隔短 → 转动连贯；6°/30ms = 60 帧转一圈，约 1.8 秒
            $script:animTimer.Interval = 30
            $script:animTimer.add_Tick({
                $script:phase += 6.0
                if ($script:phase -ge 360.0) { $script:phase -= 360.0 }
                try {
                    $notify.Icon = New-BatteryIcon -Battery $script:curLevel -Charging $true -Unknown $false -Phase $script:phase
                } catch { }
            })
        }
        if (-not $script:animTimer.Enabled) { $script:animTimer.Start() }
    } else {
        if ($null -ne $script:animTimer) { $script:animTimer.Stop() }
        $script:phase = 0.0
    }
}

# 从 status.txt 读取后台进程的结果（不触碰 HID，UI 永不阻塞）
function Read-StatusFile {
    $st = @{ ok = $false; level = -1; charging = $false; device = ''; error = '等待后台读取…'; ts = 0; fresh = $false; stale = $false }
    if (-not (Test-Path $script:StatusFile)) { return $st }
    try {
        # 文件可能正被写入，重试一次
        $lines = $null
        for ($try = 0; $try -lt 2; $try++) {
            try { $lines = Get-Content -Path $script:StatusFile -Encoding UTF8 -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 30 }
        }
        if (-not $lines) { return $st }
        foreach ($ln in $lines) {
            $i = $ln.IndexOf('=')
            if ($i -lt 1) { continue }
            $k = $ln.Substring(0, $i).Trim()
            $v = $ln.Substring($i + 1)
            switch ($k) {
                'ok'       { $st.ok = ($v -eq 'true') }
                'level'    { $st.level = [int]$v }
                'charging' { $st.charging = ($v -eq '1') }
                'device'   { $st.device = $v }
                'error'    { $st.error = $v }
                'ts'       { $st.ts = [long]$v }
            }
        }
        $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        $st.fresh = ($st.ts -eq $script:lastTs)      # 时间戳没变 = 还没拿到新数据
        $st.stale = ($st.ts -gt 0 -and ($now - $st.ts) -gt 45)   # 超过 45 秒未更新
    } catch { }
    return $st
}

function Update-Tray {
    if ($script:busy) { return }
    $script:busy = $true
    try {
        $st = Read-StatusFile
        $reading = New-Object psobject -Property @{
            Ok       = [bool]$st.ok
            Level    = [int]$st.level
            Charging = [bool]$st.charging
            DeviceName = $st.device
            Error    = $st.error
        }
        if ($reading.Ok) {
            # 充电状态已停用，消抖逻辑一并跳过（代码保留以便将来恢复）
            $script:lastCharging = $false
            $reading.Charging = $false
            $reading.Charging = $script:lastCharging
            $script:lastTs = $st.ts
            $script:curLevel = $reading.Level
            $notify.Icon = New-BatteryIcon -Battery $reading.Level -Charging $reading.Charging -Unknown $false -Phase $script:phase
            StartStop-TrayAnimation
            $notify.Text = (Get-BatteryText $reading)
            if ($st.stale) { $notify.Text = $notify.Text + '（数据较旧，后台读取中…）' }
            if ($VerboseLog) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), (Get-BatteryText $reading)) -ForegroundColor Green }
        } else {
            $script:curLevel = -1
            $notify.Icon = New-BatteryIcon -Battery -1 -Charging $false -Unknown $true -Phase 0
            $notify.Text = 'ATK 鼠标：未连接 / 无数据'
            if ($VerboseLog) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $reading.Error) -ForegroundColor DarkYellow }
        }
    } catch {
        if ($VerboseLog) { Write-Host "读取异常: $($_.Exception.Message)" -ForegroundColor Red }
    } finally {
        $script:busy = $false
    }
}

# ---------------------------------------------------------------------------
# 后台读取进程：HID I/O 全部在子进程里做，托盘 UI 只读 status.txt
# ---------------------------------------------------------------------------
function Start-Worker {
    if (-not (Test-Path $script:WorkerScript)) { return }
    if ($null -ne $script:workerProc -and -not $script:workerProc.HasExited) { return }
    try {
        $script:workerProc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', $script:WorkerScript, '-IntervalSeconds', [string]([Math]::Max(10, $IntervalSeconds))
        )
    } catch { $script:workerProc = $null }
}

function Stop-Worker {
    if ($null -ne $script:workerProc) {
        try { if (-not $script:workerProc.HasExited) { Stop-Process -Id $script:workerProc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        $script:workerProc = $null
    }
}

function Request-Refresh {
    try { Set-Content -Path $script:ReqFile -Value '1' -Encoding ASCII -Force } catch { }
}

# 右键菜单
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('立即刷新')
$miRefresh.add_Click({ Invoke-Safe 'MENU-REFRESH' { Request-Refresh; Update-Tray } })

$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('开机自启')
$miStartup.CheckOnClick = $true
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ATK鼠标电量.lnk'
$miStartup.Checked = Test-Path $startupLnk
$miStartup.add_Click({
    param($sender, $e)
    try {
        if ($sender.Checked) {
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($startupLnk)
            $lnk.TargetPath = (Get-Process -Id $PID).Path
            $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            $lnk.WorkingDirectory = Split-Path $PSCommandPath
            $lnk.WindowStyle = 7
            $lnk.Description = 'ATK 鼠标电量托盘插件'
            $lnk.Save()
        } elseif (Test-Path $startupLnk) {
            Remove-Item $startupLnk -Force
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("设置自启失败：$($_.Exception.Message)", 'ATK 电量插件')
        $sender.Checked = -not $sender.Checked
    }
})
$menu.Items.Add($miStartup) | Out-Null

$miWeb = $menu.Items.Add('打开 ATK 网页驱动')
$miWeb.add_Click({ Invoke-Safe 'MENU-WEB' { Start-Process 'https://v3-hub.atkgear.com/' } })

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = $menu.Items.Add('退出')
$miExit.add_Click({
    Invoke-Safe 'MENU-EXIT' {
        Write-ErrLog 'MENU-EXIT' '用户点击了「退出」'
        Stop-Worker
        if ('AtkSingleInstance' -as [type]) {
            try { [AtkSingleInstance]::Release() } catch { }
        }
        $notify.Visible = $false
        $notify.Dispose()
        [System.Windows.Forms.Application]::Exit()
    }
})

# ---- 菜单自检（-TestMenu）：打印每项文字并弹出 6 秒 ----
if ($TestMenu) {
    Write-Host '=== 菜单项检查 ===' -ForegroundColor Cyan
    $i = 0
    foreach ($it in $menu.Items) {
        $type = $it.GetType().Name
        $txt = if ($null -eq $it.Text) { '<null>' } elseif ($it.Text -eq '') { '<空字符串>' } else { $it.Text }
        $len = if ($null -eq $it.Text) { 0 } else { $it.Text.Length }
        Write-Host ("  [{0}] {1,-22} Text='{2}' 长度={3}" -f $i, $type, $txt, $len)
        $i++
    }
    $f = $menu.Font
    Write-Host ("菜单字体: {0} {1}px  尺寸={2}x{3}" -f $f.Name, $f.SizeInPoints, $menu.Width, $menu.Height)
    $desc = ($menu.Items | ForEach-Object {
        $tx = if ([string]::IsNullOrEmpty($_.Text)) { "(分隔线)" } else { $_.Text }
        "  [$($_.GetType().Name)] $tx"
    }) -join "`r`n"
    $body = "菜单共 $($menu.Items.Count) 项:`r`n`r`n$desc`r`n`r`n字体: $($menu.Font.Name) $([int]$menu.Font.SizeInPoints)pt`r`n`r`n随后菜单会弹出 10 秒，请看托盘菜单是否显示这些文字。"
    $null = [System.Windows.Forms.MessageBox]::Show($body, "ATK 插件菜单自检", "OK", "Information")
    Write-Host '弹出菜单 6 秒…'
    $menu.Show([System.Windows.Forms.Cursor]::Position)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 10) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $menu.Close()
    Write-Host "菜单已关闭。按回车键退出自检…" -ForegroundColor Cyan
    $null = [Console]::ReadLine()
    [System.Windows.Forms.Application]::Exit()
    return
}

$notify.ContextMenuStrip = $menu
$notify.add_MouseDoubleClick({ Invoke-Safe 'DOUBLE-CLICK' { Request-Refresh; Update-Tray } })

Start-Worker
Request-Refresh

# 每 250ms 读一次状态文件（纯文件读取，平均 1.5ms，不会阻塞 UI）
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({ Invoke-Safe 'TIMER-TICK' { Update-Tray } })
$timer.Start()

# 首次等后台进程出结果（最多 5 秒），避免图标停在"正在读取…"
for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 100
    if ($script:lastTs -gt 0 -or (Test-Path $script:StatusFile)) { break }
}
Update-Tray

Invoke-Safe 'STARTUP' { Write-ErrLog 'STARTUP' "插件启动 pid=$PID" }
if ($LauncherMode) {
    # 双击启动时给个反馈，避免"到底起没起来"的疑惑
    Invoke-Safe 'BALLOON' {
        $notify.BalloonTipTitle = 'ATK 电量插件'
        $notify.BalloonTipText = '已启动，图标在任务栏右下角'
        $notify.ShowBalloonTip(3000)
    }
}
if ($VerboseLog) { Write-Host "托盘插件已启动（后台进程读电量，UI 不阻塞）。右键菜单可退出。" -ForegroundColor Cyan }

[System.Windows.Forms.Application]::Run()
