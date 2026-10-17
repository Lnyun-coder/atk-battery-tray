<#
    ATK 电量 —— 后台工作进程（由 ATK电量.exe 启动，一般不需要手动运行）
    ---------------------------------------------------------------
    职责：
      * 按 HID 协议读取 ATK 鼠标电量
      * 把结果写入 %LOCALAPPDATA%\ATK电量\status.txt，供托盘宿主绘制图标
      * 监听 refresh.req，宿主要求立即刷新时马上重读
    参数：
      -IntervalSeconds <int>   轮询间隔，默认 60
      -Once                    只读一次写状态然后退出（调试用）
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 12,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

# 状态文件放在插件自身目录，整个文件夹可以随意移动
$stateDir = $PSScriptRoot
if (-not $stateDir) { $stateDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$statusFile = Join-Path $stateDir 'status.txt'
$reqFile = Join-Path $stateDir 'refresh.req'

# ---------------------------------------------------------------------------
# HID 底层 + ATK 协议（由官方网页驱动 WebHID 报文逆向，真机验证）
# ---------------------------------------------------------------------------
if (-not ('AtkHid' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Diagnostics;

public static class AtkHid
{
    public const ushort ATK_VID   = 0x373B;
    public const byte   REPORT_ID = 0x08;
    public const int    FRAME_LEN = 64;
    public const byte   BAT_ADDR_HI = 0x07;
    public const byte   BAT_ADDR_LO = 0x01;

    public class BatteryReading
    {
        public bool Ok;
        public int  Level = -1;
        public bool Charging;
        public string DeviceName = "";
        public string Error = "";
    }

    public class CmdIface { public string Path; public string Name; public ushort Pid, InLen, OutLen; }

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

    // 无线（2.4G 接收器 PID 0x12F5）：标志字节 = 01
    static readonly byte[][] KNOWN_FRAMES = new byte[][]
    {
        new byte[] { 0xCB, 0x72, 0x08, 0x00, 0x01, 0x4A, 0x06 },
        new byte[] { 0x97, 0x72, 0x05, 0x00, 0x01, 0x1C, 0x03 },
        new byte[] { 0xF7, 0x72, 0x03, 0x00, 0x00, 0x81, 0x01 },
        new byte[] { 0x9A, 0x72, 0x03, 0x00, 0x01, 0x23, 0x01 },
        new byte[] { 0x7D, 0x72, 0x02, 0x00, 0x01, 0x07, 0x01 },
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

    // ---- 诊断用公开方法 ----

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
    public static IntPtr OpenDevice(string path) { return CreateFile(path, GENERIC_READ|GENERIC_WRITE, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FLAG_OVERLAPPED, IntPtr.Zero); }
    public static bool IsBadHandle(IntPtr h) { return h == new IntPtr(-1); }
    public static void CloseDevice(IntPtr h) { if (h != new IntPtr(-1)) CloseHandle(h); }

    public static byte[] ToFrame(byte[] known)
    {
        byte[] f = new byte[FRAME_LEN];
        f[0] = REPORT_ID;
        Array.Copy(known, 0, f, 1, known.Length);
        return f;
    }

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
                                result.Add(new CmdIface { Path = path, Name = name,
                                    Pid = Convert.ToUInt16(m.Groups[2].Value, 16), InLen = c.InLen, OutLen = c.OutLen });
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
        CloseHandle(ev); Marshal.FreeHGlobal(ov);
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
            byte[] buf = new byte[inLen]; int n;
            if (!ReadFile(h, buf, inLen, out n, ov) && Marshal.GetLastWin32Error() != 997) return null;
            if (WaitForSingleObject(ev, (uint)ms) != 0) { CancelIo(h); return null; }
            int t; GetOverlappedResult(h, ov, out t, false);
            if (t <= 0) return null;
            byte[] r = new byte[t]; Array.Copy(buf, r, t); return r;
        }
        finally { FreeOv(ov); }
    }
    static void Drain(IntPtr h, int inLen) { for (int i = 0; i < 3; i++) if (ReadOne(h, inLen, 10) == null) break; }

    public static List<byte[]> Exchange(IntPtr h, int inLen, byte[] frame)
    {
        var replies = new List<byte[]>();
        Drain(h, inLen);
        if (!WriteFrame(h, frame)) return replies;
        for (int k = 0; k < 3; k++)
        {
            byte[] r = ReadOne(h, inLen, 120);
            if (r == null) break;
            if (r.Length >= 8 && r[1] == 0x72 && r[3] == 0x3A) replies.Add(r);
        }
        return replies;
    }

    public static BatteryReading ReadBattery()
    {
        var reading = new BatteryReading();
        // 硬性时间预算：设备插拔/切换时 HID 句柄可能长时间无响应
        var budget = Stopwatch.StartNew();
        const int TOTAL_MS = 1200;
        List<CmdIface> ifaces;
        try { ifaces = FindCommandInterfaces(); }
        catch (Exception ex) { reading.Error = "枚举设备失败: " + ex.Message; return reading; }

        if (ifaces.Count == 0) { reading.Error = "未找到 ATK 设备（VID 0x373B）"; return reading; }

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
                    foreach (byte[] r in Exchange(h, inLen, ToFrame(known)))
                    {
                        if (r[5] == BAT_ADDR_HI && r[6] == BAT_ADDR_LO && r.Length > 8 && r[7] <= 100)
                        {
                            reading.Ok = true;
                            reading.Level = r[7];
                            // 无线回包用 0xFF 表示充电；有线回包是两字节非零 → 统一看后两字节
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
            finally { CloseHandle(h); }
        }

        reading.Error = "设备已连接但未读到电量（鼠标可能未开机或未连上接收器）";
        return reading;
    }
}
'@
}

# ---------------------------------------------------------------------------
# 状态写入（原始值，消抖交给托盘宿主负责）
# ---------------------------------------------------------------------------

function Write-Status {
    param([bool]$Ok, [int]$Level, [bool]$Charging, [string]$Device, [string]$Error)
    $lines = @(
        "ok=$($Ok.ToString().ToLower())",
        "level=$Level",
        "charging=$(if ($Charging) { '1' } else { '0' })",
        "device=$Device",
        "error=$Error",
        "ts=$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    )
    try {
        Set-Content -Path $statusFile -Value $lines -Encoding UTF8 -Force
    } catch { }
}

function Invoke-Poll {
    try {
        $r = [AtkHid]::ReadBattery()
    } catch {
        Write-Status $false -1 $false '' "读取异常: $($_.Exception.Message)"
        return
    }
    if ($r.Ok) {
        # 直接上报原始值；充电状态会抖动，消抖由 TrayHost 做
        Write-Status $true $r.Level ([bool]$r.Charging) $r.DeviceName ''
    } else {
        Write-Status $false -1 $false '' $r.Error
    }
}

Invoke-Poll
if ($Once) { exit 0 }

# 信号处理：宿主退出时一起退出
while ($true) {
    $elapsed = 0
    while ($elapsed -lt $IntervalSeconds) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
        if (Test-Path $reqFile) {
            Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
            break
        }
    }
    Invoke-Poll
}
