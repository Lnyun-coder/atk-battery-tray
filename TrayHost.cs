// ATK 电量 —— 任务栏托盘宿主
// 编译：csc /target:winexe /out:ATK电量.exe /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll TrayHost.cs
using System;
using System.Text;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Threading;
using System.Windows.Forms;

static class TrayHost
{
    static string stateDir, statusFile, reqFile, workerScript;
    static NotifyIcon tray;
    static ContextMenuStrip menu;
    static ToolStripMenuItem miStatus, miRefresh, miStartup, miExit;
    static Icon currentIcon;
    static Process worker;
    static string lastSignature = "";
    static bool lastCharging = false;
    static string pendingCharging = null;
    static int pendingCount = 0;
    static bool lastShownCharging = false;
    static int g_curLevel = -1;          // 当前展示的电量
    static System.Windows.Forms.Timer g_animTimer;
    static string startupLnk;

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // 全局异常捕获：否则消息循环里的任何异常都会静默杀掉进程
        Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e)
        {
            LogCrash("UI-THREAD", e.Exception);
        };
        AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e)
        {
            LogCrash("FATAL", e.ExceptionObject as Exception ?? new Exception(e.ExceptionObject.ToString()));
        };

        bool createdNew;
        using (Mutex mtx = new Mutex(true, @"Local\AtkBatteryTray_SingleInstance", out createdNew))
        {
            if (!createdNew)
            {
                MessageBox.Show("ATK 电量插件已经在运行了（看任务栏通知区域）。", "ATK 电量",
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            stateDir = baseDir;   // 状态文件放在插件自身目录
            statusFile = Path.Combine(stateDir, "status.txt");
            reqFile = Path.Combine(stateDir, "refresh.req");
            workerScript = Path.Combine(baseDir, "atk-worker.ps1");
            startupLnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ATK电量.lnk");

            BuildMenu();
            StartWorker();

            var uiTimer = new System.Windows.Forms.Timer();
            uiTimer.Interval = 1500;
            uiTimer.Tick += delegate { try { RefreshFromStatus(); } catch (Exception ex) { LogCrash("UI-TIMER", ex); } };
            uiTimer.Start();

            var pollTimer = new System.Windows.Forms.Timer();
            pollTimer.Interval = 20000;
            pollTimer.Tick += delegate { try { RequestRefresh(); } catch (Exception ex) { LogCrash("POLL-TIMER", ex); } };
            pollTimer.Start();

            RefreshFromStatus();
            LogEvent("STARTUP", "exe 启动 pid=" + System.Diagnostics.Process.GetCurrentProcess().Id);
            Application.Run();

            LogEvent("SHUTDOWN", "正常退出（用户点退出或消息循环结束）");
            StopWorker();
        }
    }

    // ------------------------------------------------------------------
    // 崩溃日志：与脚本版 atk-tray.ps1 写同一个文件、同一格式
    // ------------------------------------------------------------------
    static void LogEvent(string tag, string msg)
    {
        try
        {
            string p = Path.Combine(stateDir ?? AppDomain.CurrentDomain.BaseDirectory, "atk-error.log");
            string line = string.Format("[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}\r\n",
                                        DateTime.Now, tag, "事件", msg);
            File.AppendAllText(p, line, new UTF8Encoding(false));
        }
        catch { }
    }

    static void LogCrash(string where, Exception ex)
    {
        try
        {
            string p = Path.Combine(stateDir ?? AppDomain.CurrentDomain.BaseDirectory, "atk-error.log");
            string line = string.Format("[{0:yyyy-MM-dd HH:mm:ss}] [CRASH] [{1}] {2}: {3}\r\n{4}\r\n",
                                        DateTime.Now, where, ex.GetType().Name, ex.Message, ex.StackTrace);
            File.AppendAllText(p, line, new UTF8Encoding(false));
        }
        catch { }
    }

    static void BuildMenu()
    {
        menu = new ContextMenuStrip();
        miStatus = new ToolStripMenuItem("正在读取…");
        miStatus.Enabled = false;
        menu.Items.Add(miStatus);
        menu.Items.Add(new ToolStripSeparator());

        var miStyle = new ToolStripMenuItem("切换图标样式（也可双击图标）");
        miStyle.Click += delegate
        {
            int s = CycleBatteryStyle();
            lastSignature = "";
            RefreshFromStatus();
            miStatus.Text = "图标样式：" + StyleName(s);
        };
        menu.Items.Add(miStyle);

        miRefresh = new ToolStripMenuItem("立即刷新");
        miRefresh.Click += delegate { RequestRefresh(); };
        menu.Items.Add(miRefresh);

        miStartup = new ToolStripMenuItem("开机自启");
        miStartup.CheckOnClick = true;
        miStartup.Checked = File.Exists(startupLnk);
        miStartup.Click += delegate
        {
            try
            {
                if (miStartup.Checked) CreateShortcut();
                else if (File.Exists(startupLnk)) File.Delete(startupLnk);
            }
            catch (Exception ex)
            {
                MessageBox.Show("设置自启失败：" + ex.Message, "ATK 电量");
                miStartup.Checked = !miStartup.Checked;
            }
        };
        menu.Items.Add(miStartup);

        var miWeb = new ToolStripMenuItem("打开 ATK 网页驱动");
        miWeb.Click += delegate { Process.Start("https://v3-hub.atkgear.com/"); };
        menu.Items.Add(miWeb);

        menu.Items.Add(new ToolStripSeparator());
        miExit = new ToolStripMenuItem("退出");
        miExit.Click += delegate
        {
            StopWorker();
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            Application.Exit();
        };
        menu.Items.Add(miExit);

        tray = new NotifyIcon();
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.Text = "ATK 电量：正在读取…";
        tray.Icon = MakeIcon(-1, false);
        // 双击 = 循环切换电池图标样式（与参考实现一致）
        tray.DoubleClick += delegate
        {
            int s = CycleBatteryStyle();
            lastSignature = "";      // 强制按新样式重绘
            RefreshFromStatus();
            tray.BalloonTipTitle = "ATK 电量";
            tray.BalloonTipText = "图标样式：" + StyleName(s);
            try { tray.ShowBalloonTip(1500); } catch { }
        };
    }

    static void CreateShortcut()
    {
        string exe = Application.ExecutablePath;
        // 用 WScript.Shell 通过反射或 dynamic 不方便，直接写一个 .lnk 太复杂 —— 改用启动文件夹里的 cmd 包装
        string target = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "启动插件.cmd");
        if (File.Exists(target))
        {
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            object shell = Activator.CreateInstance(t);
            object lnk = t.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { startupLnk });
            Type lt = lnk.GetType();
            lt.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { target });
            lt.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { AppDomain.CurrentDomain.BaseDirectory });
            lt.InvokeMember("WindowStyle", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { 7 });
            lt.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { "ATK 鼠标电量托盘" });
            lt.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, lnk, null);
        }
        else
        {
            // 没有 cmd 就直接指向自己
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            object shell = Activator.CreateInstance(t);
            object lnk = t.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { startupLnk });
            Type lt = lnk.GetType();
            lt.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { exe });
            lt.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { AppDomain.CurrentDomain.BaseDirectory });
            lt.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, lnk, null);
        }
    }

    static void StartWorker()
    {
        if (!File.Exists(workerScript))
        {
            tray.Text = "ATK 电量：缺少 atk-worker.ps1";
            MessageBox.Show("找不到 atk-worker.ps1，请确认它和本程序在同一目录。", "ATK 电量");
            return;
        }
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                        @"WindowsPowerShell\v1.0\powershell.exe");
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + workerScript + "\" -IntervalSeconds 60";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            worker = Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动后台读取进程失败：" + ex.Message, "ATK 电量");
        }
    }

    static void StopWorker()
    {
        try
        {
            if (worker != null && !worker.HasExited) { worker.Kill(); worker.WaitForExit(3000); }
        }
        catch { }
    }

    static void RequestRefresh()
    {
        try { File.WriteAllText(reqFile, DateTime.Now.ToString("o")); } catch { }
    }

    static Point lastStatusWrite = Point.Empty;

    static void RefreshFromStatus()
    {
        int level = -1;
        bool charging = false;
        string device = "", error = "", ts = "";
        try
        {
            if (!File.Exists(statusFile)) return;
            // 文件可能正被写入，稍后重试
            if (new FileInfo(statusFile).LastWriteTimeUtc == lastWriteUtc) return;
            lastWriteUtc = new FileInfo(statusFile).LastWriteTimeUtc;

            foreach (string line in File.ReadAllLines(statusFile))
            {
                int i = line.IndexOf('=');
                if (i <= 0) continue;
                string k = line.Substring(0, i).Trim();
                string v = line.Substring(i + 1).Trim();
                if (k == "level") int.TryParse(v, out level);
                else if (k == "charging") charging = (v == "1");
                else if (k == "device") device = v;
                else if (k == "error") error = v;
            }
        }
        catch { return; }

        string sig = level + "|" + charging + "|" + error;
        if (sig == lastSignature) return;
        lastSignature = sig;

        if (level >= 0)
        {
            // 充电状态消抖
            if (charging == lastShownCharging) { pendingCharging = null; pendingCount = 0; }
            else if (pendingCharging == charging.ToString()) { pendingCount++; if (pendingCount >= 2) { lastShownCharging = charging; pendingCharging = null; pendingCount = 0; } }
            else { pendingCharging = charging.ToString(); pendingCount = 1; }

            g_curLevel = level;
            SetIcon(level, lastShownCharging, g_phase);
            StartStopAnimation();
            string text = "ATK 鼠标电量：" + level + "%" + (lastShownCharging ? "（充电中）" : "");
            tray.Text = Trim(text);
            miStatus.Text = text + (device.Length > 0 ? "   [" + device + "]" : "");
        }
        else
        {
            g_curLevel = -1;
            SetIcon(-1, false, 0f);
            StartStopAnimation();
            tray.Text = Trim("ATK 电量：未连接 / 无数据");
            miStatus.Text = error.Length > 0 ? error : "未连接 / 无数据";
        }
    }

    static DateTime lastWriteUtc = DateTime.MinValue;

    static string Trim(string s)
    {
        if (s.Length > 63) return s.Substring(0, 60) + "...";
        return s;
    }

    // 充电动画相位（0~360），由 g_animTimer 递增
    static float g_phase = 0f;

    // 充电时启动动画：每 120ms 让高光沿圆环转一小步
    static void StartStopAnimation()
    {
        bool want = lastShownCharging && g_curLevel >= 0;
        if (want)
        {
            if (g_animTimer == null)
            {
                g_animTimer = new System.Windows.Forms.Timer();
                // 步长小、间隔短 → 转动连贯；6°/30ms = 60 帧转一圈，约 1.8 秒
                g_animTimer.Interval = 30;
                g_animTimer.Tick += delegate
                {
                    g_phase += 6f;
                    if (g_phase >= 360f) g_phase -= 360f;
                    SetIcon(g_curLevel, true, g_phase);
                };
            }
            if (!g_animTimer.Enabled) g_animTimer.Start();
        }
        else
        {
            if (g_animTimer != null) g_animTimer.Stop();
            g_phase = 0f;
        }
    }

    static void SetIcon(int level, bool charging)
    {
        SetIcon(level, charging, g_phase);
    }

    static void SetIcon(int level, bool charging, float phase)
    {
        try
        {
            Icon ic = MakeIcon(level, charging, phase);
            Icon old = currentIcon;
            tray.Icon = ic;
            currentIcon = ic;
            if (old != null) old.Dispose();
        }
        catch { }
    }

    // ==================================================================
    // 图标：逐像素照搬 Iris-0109/rapoo-tray 的 CreateBatteryIcon（MIT）
    //   style 0 = 经典纯净电池胶囊
    //   style 1 = 360° 环形电量进度圈
    //   style 2 = 大号数字 + 底部细比例横轨
    //   统一 4x 超采样 + 盒式滤波降采样
    // ==================================================================
    const int SS = 4;
    const string REG_KEY = @"Software\ATKBatteryTray";

    // 只保留配置二（环形电量）；如需恢复多样式切换，把 LOCK_STYLE 改成 -1
    const int LOCK_STYLE = 1;
    static int g_style = -1;

    static int GetBatteryStyle()
    {
        if (LOCK_STYLE >= 0) { g_style = LOCK_STYLE; return g_style; }
        if (g_style == -1)
        {
            g_style = 0;
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(REG_KEY))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("BatteryStyle");
                        if (v != null) g_style = Convert.ToInt32(v) % 3;
                    }
                }
            }
            catch { }
        }
        return g_style;
    }

    static int CycleBatteryStyle()
    {
        g_style = (GetBatteryStyle() + 1) % 3;
        try
        {
            using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(REG_KEY))
            {
                if (k != null) k.SetValue("BatteryStyle", g_style, Microsoft.Win32.RegistryValueKind.DWord);
            }
        }
        catch { }
        return g_style;
    }

    static string StyleName(int s)
    {
        if (s == 0) return "经典电池";
        if (s == 1) return "环形电量";
        return "滑轨数字";
    }

    static bool IsSystemDarkTheme()
    {
        try
        {
            using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                       @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            {
                if (k != null)
                {
                    object v = k.GetValue("SystemUsesLightTheme");
                    if (v != null) return Convert.ToInt32(v) == 0;
                    object v2 = k.GetValue("AppsUseLightTheme");
                    if (v2 != null) return Convert.ToInt32(v2) == 0;
                }
            }
        }
        catch { }
        return true;
    }

    // 两个 0xAARRGGBB 颜色按 t 线性混合
    static uint MixU(uint a, uint b, float t)
    {
        if (t < 0f) t = 0f; if (t > 1f) t = 1f;
        uint aA = (a >> 24) & 0xFF, aR = (a >> 16) & 0xFF, aG = (a >> 8) & 0xFF, aB = a & 0xFF;
        uint bA = (b >> 24) & 0xFF, bR = (b >> 16) & 0xFF, bG = (b >> 8) & 0xFF, bB = b & 0xFF;
        return (((uint)(aA + (bA - aA) * t) & 0xFF) << 24)
             | (((uint)(aR + (bR - aR) * t) & 0xFF) << 16)
             | (((uint)(aG + (bG - aG) * t) & 0xFF) << 8)
             | ((uint)(aB + (bB - aB) * t) & 0xFF);
    }

    static Color FromArgbU(uint c)
    {
        return Color.FromArgb((int)((c >> 24) & 0xFF), (int)((c >> 16) & 0xFF), (int)((c >> 8) & 0xFF), (int)(c & 0xFF));
    }

    static void FillRoundRect(Bitmap bmp, int x0, int y0, int x1, int y1, uint col, int rad)
    {
        if (rad > (x1 - x0) / 2) rad = (x1 - x0) / 2;
        if (rad > (y1 - y0) / 2) rad = (y1 - y0) / 2;
        if (rad < 0) rad = 0;
        Color c = FromArgbU(col);
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        if (w <= 0 || h <= 0) return;
        // 逐像素（与参考实现一致：圆角处用 dx*dx+dy*dy <= rad*rad 判定）
        for (int y = y0; y <= y1; y++)
        {
            for (int x = x0; x <= x1; x++)
            {
                int dx = (x < x0 + rad) ? (x0 + rad - x) : (x > x1 - rad) ? (x - (x1 - rad)) : 0;
                int dy = (y < y0 + rad) ? (y0 + rad - y) : (y > y1 - rad) ? (y - (y1 - rad)) : 0;
                if (dx * dx + dy * dy <= rad * rad) bmp.SetPixel(x, y, c);
            }
        }
    }

    static void DrawBolt(Bitmap bmp, int sx, int sy, uint col, int ss)
    {
        string[] pattern = { "..#", ".##", "###", ".#.", "##.", "#..", "..." };
        Color c = FromArgbU(col);
        for (int r = 0; r < 7; r++)
            for (int cc = 0; cc < 3; cc++)
                if (pattern[r][cc] == '#')
                    for (int dy = 0; dy < ss; dy++)
                        for (int dx = 0; dx < ss; dx++)
                            bmp.SetPixel(sx + cc * ss + dx, sy + r * ss + dy, c);
    }

    static Icon MakeIcon(int battery, bool isCharging) { return MakeIcon(battery, isCharging, 0f); }

    static Icon MakeIcon(int battery, bool isCharging, float phase)
    {
        int style = GetBatteryStyle();
        int size = SystemInformation.SmallIconSize.Width;
        if (size <= 0) size = 16;
        bool isDark = IsSystemDarkTheme();
        bool isConnected = battery >= 0;
        int W = size * SS, H = size * SS;

        Bitmap big = new Bitmap(W, H, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        big.SetResolution(96, 96);
        // 清零（含 alpha）
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) big.SetPixel(x, y, Color.Transparent);

        uint c_shell = isDark ? 0xFFFFFFFFu : 0xFF334155u;
        // 配色按电量阈值：>40% 绿、20~40% 黄、<20% 红
        // 全部为纯色（c_dark == c_lite，无渐变）；充电只靠流动高光区分
        uint c_state, c_dark, c_lite;
        if (!isConnected) c_state = 0xFF94A3B8u;
        else if (isCharging) c_state = 0xFF22C55Eu;
        else if (battery < 20) c_state = 0xFFEF4444u;
        else if (battery <= 40) c_state = 0xFFEAB308u;
        else c_state = 0xFF22C55Eu;
        c_dark = c_state; c_lite = c_state;
        // 流动高光颜色（只用于充电）
        uint c_glow = 0xFFBEFFDCu;
        Func<float, int> L2S = v => (int)(v * (float)(size * SS) / 16.0f + 0.5f);

        if (style == 0)
        {
            // ---------- 配置一：经典纯净电池胶囊 ----------
            int bx0 = 0, by0 = L2S(2.5f), bw = L2S(13.5f), bh = L2S(11.0f);
            int bx1 = bx0 + bw, by1 = by0 + bh;
            FillRoundRect(big, bx0, by0, bx1, by1, c_shell, L2S(2.5f));

            int nx0 = L2S(13.8f), ny0 = L2S(5.2f);
            int nx1 = Math.Min(W - 1, nx0 + L2S(1.8f)), ny1 = ny0 + L2S(5.6f);
            FillRoundRect(big, nx0, ny0, nx1, ny1, c_shell, L2S(1.0f));

            int stk = (int)(1.5f * SS + 0.5f);
            int cx0 = bx0 + stk, cy0 = by0 + stk, cx1 = bx1 - stk, cy1 = by1 - stk;
            FillRoundRect(big, cx0, cy0, cx1, cy1, 0x00000000u, 0);

            int pd = (int)(0.75f * SS + 0.5f);
            int ix0 = cx0 + pd, iy0 = cy0 + pd, ix1 = cx1 - pd, iy1 = cy1 - pd;
            int iw = ix1 - ix0 + 1, ih = iy1 - iy0 + 1;

            if (isConnected && battery > 0)
            {
                float ratio = Math.Min(1.0f, Math.Max(0.08f, battery / 100.0f));
                int fw = Math.Max(L2S(2.0f), (int)(iw * ratio));
                FillRoundRect(big, ix0, iy0, ix0 + fw, iy1, c_state, L2S(1.5f));
            }
            else if (!isConnected)
            {
                uint c_dim = isDark ? 0x40606060u : 0x40B0B0B0u;
                FillRoundRect(big, ix0, iy0, ix1, iy1, c_dim, L2S(1.5f));
                int dw = L2S(4.5f), dh = L2S(2.0f);
                int sx = ix0 + (iw - dw) / 2, sy = iy0 + (ih - dh) / 2;
                FillRoundRect(big, sx, sy, sx + dw, sy + dh, isDark ? 0xFFBBBBBBu : 0xFF666666u, 0);
            }
            if (isCharging)
            {
                int bxs = cx0 + (cx1 - cx0 + 1 - 3 * SS) / 2;
                int bys = cy0 + (cy1 - cy0 + 1 - 7 * SS) / 2;
                DrawBolt(big, bxs, bys, 0xFFFFFFFFu, SS);
            }
        }
        else if (style == 1)
        {
            // ---------- 配置二：360° 环形电量进度圈 ----------
            float ccx = W / 2.0f, ccy = H / 2.0f;
            float R = (float)(size * SS) * 5.8f / 16.0f;
            float T = (float)(size * SS) * 3.0f / 16.0f;
            uint c_track = isDark ? 0x40FFFFFFu : 0x35000000u;

            float sweep = isConnected ? Math.Min(360.0f, Math.Max(0.0f, 360.0f * (battery / 100.0f))) : 0.0f;
            float sweepRad = sweep * (float)Math.PI / 180.0f;
            float capR = T / 2.0f, capR2 = capR * capR;
            float sxCap = ccx, syCap = ccy - R;
            float exCap = ccx + R * (float)Math.Sin(sweepRad);
            float eyCap = ccy - R * (float)Math.Cos(sweepRad);

            int minX = Math.Max(0, (int)(ccx - R - T)), maxX = Math.Min(W - 1, (int)(ccx + R + T));
            int minY = Math.Max(0, (int)(ccy - R - T)), maxY = Math.Min(H - 1, (int)(ccy + R + T));

            for (int y = minY; y <= maxY; y++)
            {
                for (int x = minX; x <= maxX; x++)
                {
                    float px = x + 0.5f, py = y + 0.5f;
                    float dx = px - ccx, dy = py - ccy;
                    float dist = (float)Math.Sqrt(dx * dx + dy * dy);

                    // 按下标角度算渐变色（深 → 亮 → 高光）
                    float ang0 = (float)(Math.Atan2(dx, -dy) * (180.0 / Math.PI));
                    if (ang0 < 0) ang0 += 360.0f;
                    uint arcCol = MixU(c_dark, c_lite, ang0 / 360.0f);
                    if (isCharging)
                    {
                        float d = Math.Abs(ang0 - phase);
                        if (d > 180f) d = 360f - d;
                        float gW = (float)Math.Exp(-(d * d) / (2.0 * 38.0 * 38.0));
                        arcCol = MixU(arcCol, c_glow, gW);
                    }

                    if (isConnected && battery > 0 &&
                        ((px - sxCap) * (px - sxCap) + (py - syCap) * (py - syCap) <= capR2))
                    { big.SetPixel(x, y, FromArgbU(arcCol)); continue; }
                    if (isConnected && battery > 0 &&
                        ((px - exCap) * (px - exCap) + (py - eyCap) * (py - eyCap) <= capR2))
                    { big.SetPixel(x, y, FromArgbU(arcCol)); continue; }

                    if (Math.Abs(dist - R) <= capR)
                    {
                        if (isConnected && battery > 0)
                            big.SetPixel(x, y, FromArgbU(ang0 <= sweep ? arcCol : c_track));
                        else big.SetPixel(x, y, FromArgbU(c_track));
                    }
                }
            }
            // 充电改用圆环渐变 + 流动高光表达（闪电在 16px 下太小，已弃用）
            if (!isConnected)
            {
                int dw = L2S(4.0f), dh = L2S(2.0f);
                FillRoundRect(big, (W - dw) / 2, (H - dh) / 2, (W + dw) / 2, (H + dh) / 2,
                              isDark ? 0xFF888888u : 0xFF666666u, 0);
            }
        }
        else
        {
            // ---------- 配置三：大号数字 + 底部细比例横轨 ----------
            // 参考实现用 GDI DrawText 画白字，再按 alpha 取灰度重新着色
            int textH = (int)(H * 13.5f / 16.0f);
            string text = isConnected ? battery.ToString() : "-";
            float fs = (battery == 100) ? (H * 52f / 100f) : (H * 70f / 100f);
            using (Font font = new Font("Segoe UI", fs, FontStyle.Bold, GraphicsUnit.Pixel))
            using (StringFormat fmt = new StringFormat())
            {
                fmt.Alignment = StringAlignment.Center;
                fmt.LineAlignment = StringAlignment.Center;
                fmt.FormatFlags = StringFormatFlags.NoWrap;
                using (SolidBrush wb = new SolidBrush(Color.White))
                    bigDrawText(big, text, font, wb, fmt, W, textH, -SS);
            }

            uint target;
            if (!isConnected) target = isDark ? 0xFFA0A0A0u : 0xFF646464u;
            else if (isCharging) target = 0xFF22C55Eu;
            else if (battery <= 30) target = 0xFFEF4444u;
            else target = isDark ? 0xFFFFFFFFu : 0xFF141414u;

            uint tR = (target >> 16) & 0xFF, tG = (target >> 8) & 0xFF, tB = target & 0xFF;
            for (int y = 0; y < textH; y++)
            {
                for (int x = 0; x < W; x++)
                {
                    Color raw = big.GetPixel(x, y);
                    int gray = raw.A;
                    if (gray > 0) big.SetPixel(x, y, Color.FromArgb(gray, (int)tR, (int)tG, (int)tB));
                    else big.SetPixel(x, y, Color.Transparent);
                }
            }

            int bar_y0 = (int)(H * 14.0f / 16.0f), bar_y1 = H - 1;
            uint c_track = isDark ? 0x40FFFFFFu : 0x30000000u;
            FillRoundRect(big, 0, bar_y0, W - 1, bar_y1, c_track, SS / 2);
            if (isConnected && battery > 0)
            {
                int bar_w = Math.Min(W, Math.Max(2 * SS, (int)(W * (battery / 100.0f))));
                FillRoundRect(big, 0, bar_y0, bar_w - 1, bar_y1, c_state, SS / 2);
            }
        }

        // ---- 盒式滤波降采样 ----
        Bitmap outp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        outp.SetResolution(96, 96);
        int SS2 = SS * SS;
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                int sumA = 0, sumR = 0, sumG = 0, sumB = 0;
                for (int sy = 0; sy < SS; sy++)
                {
                    for (int sx = 0; sx < SS; sx++)
                    {
                        Color c = big.GetPixel(x * SS + sx, y * SS + sy);
                        if (c.A > 0) { sumA += c.A; sumR += c.R; sumG += c.G; sumB += c.B; }
                    }
                }
                int avgA = sumA / SS2;
                if (avgA == 0) outp.SetPixel(x, y, Color.Transparent);
                else outp.SetPixel(x, y, Color.FromArgb(avgA,
                    sumR / SS2 * avgA / 255, sumG / SS2 * avgA / 255, sumB / SS2 * avgA / 255));
            }
        }
        big.Dispose();

        IntPtr hh = outp.GetHicon();
        outp.Dispose();
        return Icon.FromHandle(hh);
    }

    static void bigDrawText(Bitmap bmp, string text, Font font, Brush brush, StringFormat fmt, int W, int textH, int yOff)
    {
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            g.DrawString(text, font, brush, new RectangleF(0, yOff, W, textH), fmt);
        }
    }
}