<div align="center">

# atk-battery-tray

**ATK 游戏鼠标电量托盘显示插件**

在任务栏托盘里显示鼠标电量百分比，**独立运行，不需要 ATK HUB**

<img src="docs/icon_final_state.png" width="720" alt="各种电量下的托盘图标" />

<sub>从左到右：89% / 55% / 41% / 40% / 25% / 20% / 19% / 5% / 未连接</sub>

<details>
<summary>另两种图标样式（源码里保留，可通过 <code>LOCK_STYLE</code> 切换）</summary>

<img src="docs/styles.png" width="720" alt="三种图标样式对比" />

</details>

</div>

---

## 为什么做这个

ATK 官方驱动 **ATK HUB 后台占用较高**，而我只想在任务栏瞄一眼电量。所以逆向出电量协议，
写了个纯托盘的小工具：**零依赖、不驻留驱动、不连网**。

## 特性

| 特性 | 说明 |
| --- | --- |
| 🔋 **独立的托盘电量** | 圆环按电量展开，一眼看清百分比 |
| 🎨 **三档配色** | >40% 绿 / 20–40% 黄 / <20% 红，未连接灰色 + 短横条 |
| 🔌 **无线 / 有线自动适配** | 插拔数据线时自动切换协议帧组，无需手动干预 |
| 🖱️ **即点即刷** | 双击图标或右键「立即刷新」立刻重读 |
| 🛡️ **不卡顿** | HID 读写跑在独立子进程，托盘 UI 永不阻塞 |
| 🚫 **单实例保护** | 命名互斥体拦重复启动（开机自启 + 手动启动不会打架） |
| 🌗 **跟随系统主题** | 深色 / 浅色任务栏自动切换外壳配色 |
| 📝 **崩溃日志** | 异常写入 `atk-error.log`，方便排查 |

## 安装

需要 **Windows 10 / 11** 和 **PowerShell 5.1**（系统自带，无需安装）。

```powershell
git clone https://github.com/<你的用户名>/atk-battery-tray.git
cd atk-battery-tray
```

双击 **`启动插件.cmd`** 即可。

<details>
<summary>也可以直接用命令行启动</summary>

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "atk-tray.ps1"
```

想放桌面快捷方式的话：右键 `启动插件.cmd` → 发送到 → 桌面快捷方式。

</details>

### 让图标显示在任务栏（不在「^」折叠菜单里）

Windows 默认会把新图标放进折叠菜单。手动设置一次即可，之后一直生效：

**设置 → 个性化 → 任务栏 → 其他系统托盘图标 → 找到「ATK 鼠标电量」→ 打开**

## 使用

| 操作 | 效果 |
| --- | --- |
| **双击**图标 | 立即刷新 |
| **右键**图标 | 菜单：立即刷新 / 开机自启 / 打开 ATK 网页驱动 / 退出 |
| **悬停**图标 | 显示 `ATK 鼠标电量：89%` 和设备名 |

### 命令行参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-IntervalSeconds <n>` | `12` | 后台读电量的间隔（秒）。想更灵敏可设 5，想更省资源可设 30 |
| `-DryRun` | — | 只读一次并打印结果，不启动托盘（用于验证） |
| `-VerboseLog` | — | 在控制台输出每次刷新的日志 |
| `-TestMenu` | — | 菜单自检：打印菜单项并弹出菜单 10 秒 |
| `-AllowMulti` | — | 跳过多实例检查（仅调试用） |

```powershell
# 让电量变化更灵敏（约 5 秒延迟）
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "atk-tray.ps1" -IntervalSeconds 5
```

## 目录结构

```
atk-battery-tray/
├── atk-tray.ps1              # 插件本体：托盘 UI + 协议实现（主程序）
├── atk-worker.ps1            # 后台读取进程：HID 通信，结果写入 status.txt
├── 启动插件.cmd               # 双击启动
├── test-menu.cmd             # 菜单自检工具
├── ATKBattery.exe            # 可选的专用托盘宿主（见下方说明）
├── ATKBattery.exe.manifest   # exe 的清单（asInvoker）
├── TrayHost.cs               # ATKBattery.exe 的 C# 源码
├── docs/                     # 截图
└── LICENSE
```

### 关于 `ATKBattery.exe`

可选的**专用托盘宿主**：任务栏条目会挂在它自己名下（而不是 `powershell.exe`），
右键菜单更清爽。功能与脚本版完全相同。源码在 `src/TrayHost.cs`，可用系统自带编译器重建：

```bat
C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
  /out:ATKBattery.exe /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll TrayHost.cs
```

## 实现要点

### 架构

```
atk-worker.ps1（独立子进程）── 每 12 秒读一次 HID ──> status.txt
                                                        ↑
atk-tray.ps1（托盘 UI）────── 每 250ms 只读这个文件 ─────┘
```

**为什么不让 UI 自己读？** 鼠标在无线 ↔ 有线之间切换时，HID 句柄会几秒钟不响应。
若在 UI 线程上直接读写，整个消息循环被堵死 —— 表现为插件完全卡住、右键菜单点不动。
所以 HID 全部交给子进程，UI 只读文件（平均 1.5 ms）。

另外读取侧还有**硬性 1.2 秒时间预算**，超时就放弃并汇报，不会无限期卡在 `ReadFile`。

### 图标绘制

- **4× 超采样 + 4×4 盒式滤波降采样** —— 这是小图标清晰锐利的根本原因
- 16×16 托盘格子，圆环半径 `5.8/16`、线宽 `3.0/16`
- 支持三档配色，纯色无渐变

> 性能：早期版本用 PowerShell 逐像素 `GetPixel`/`SetPixel`，单帧重建要 **229 ms**，
> 远超刷新间隔导致动画卡顿。改为 C# 侧 `FastRender`（`LockBits` 直操作字节数组 +
> 环形光栅化 + 降采样）后，单帧 **0.99 ms，快 230 倍**。

### 协议（逆向自官方网页驱动）

通过 Chrome DevTools Protocol 钩住 `navigator.hid` 抓包得到。厂商 HID 接口：
Usage Page `0xFF05`，输入/输出报告各 64 字节，Report ID `0x08`。

**读电量帧**（第 5 字节的标志位随连接方式变化，校验和随之不同）：

| 连接方式 | 设备 PID | 读电量帧 |
| --- | --- | --- |
| 2.4G 无线接收器 | `0x12F5` | `7D 72 02 00 01 07 01` |
| USB 有线直连 | `0x1312` | `7C 72 02 00 00 07 01` |

**回包格式**（两种模式一致）：

```
72 00 3A 00 07 01 53 FF FF ...
            └─地址─┘ └电量┘ └充电标志（不可靠，见下）
```

- `r[5..6]` = 寄存器地址 `0x0701`
- `r[7]` = 电量百分比（0–100）
- `r[8]` = 充电标志

重现抓包的完整脚本和步骤见 [`docs/CAPTURE.md`](docs/CAPTURE.md)。

## 已知限制

### ⚠️ 充电状态不显示

电量回包的第 8 字节是充电标志，但**实测不可信**：

| 连接方式 | 标志字节 | 实测结果 |
| --- | --- | --- |
| 2.4G 无线 | `FF` = 充电 / `00` = 未充电 | **约 25% 概率误报 `FF`** |
| USB 有线 | `E8` / `BC` 等非零值 | 含义未确认 |

而且 `FF` 无法区分「插线充电」和「放在充电底座上被供电」。
**与其显示错误信息，不如不显示** —— 所以插件不上报充电状态，只显示电量百分比。

> 检测代码保留在源码里（`reading.Charging = false;`，两个脚本各一处），
> 若将来确认协议含义，换回检测逻辑即可启用。

### 其他

- **鼠标休眠时可能读不到**。设备侧不响应时提示会显示「未连接 / 无数据」，移动鼠标唤醒即可。
- **只测过 ATK 烈空幻影 ULTIMATE（ATK PHANTOM ULTIMATE）**。
  同代 ATK / VXE 鼠标 VID 同为 `0x373B`，**很可能通用**，但需要你实测反馈。
- 台式机的 `ACLineStatus` 恒为 1，所以无法用系统电源状态推断有线充电。

## 适配其它型号

1. 用 `-DryRun` 看是否已能读到：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "atk-tray.ps1" -DryRun
   ```
2. 如果读不到，按 [`docs/CAPTURE.md`](docs/CAPTURE.md) 抓一次包，把新帧告诉我。

## 开源协议

[MIT](LICENSE)

## 鸣谢

- **图标设计**参考 [Iris-0109/rapoo-tray](https://github.com/Iris-0109/rapoo-tray) 的
  「环形电量进度圈」实现（MIT），**4× 超采样 + 盒式滤波降采样**的思路来自该项目。
- 协议逆向过程中参考过 [noosxe/atk-tool](https://github.com/noosxe/atk-tool)、
  [ReformedDoge/0x44oge-ATK](https://github.com/ReformedDoge/0x44oge-ATK) 和
  Linux 内核 `hid-pulsar` 驱动，但本设备的 64 字节报告格式与它们都不同，
  最终靠抓包确定。

## 免责声明

本项目为个人开源作品，**非 ATK 官方出品**。「ATK」及相关产品名称的所有权归其各自所有者。
软件按「原样」提供，作者不对使用过程中产生的任何问题承担责任。
