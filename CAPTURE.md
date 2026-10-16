# 抓包重现指南

换设备或换固件后，如果插件读不到电量，用这个流程重新抓一次协议。

思路：**钩住官方网页驱动的 `navigator.hid`，记录它收发的原始报文**。

---

## 步骤

### 1. 打开网页驱动并预备钩子

用 **Edge 或 Chrome** 打开 <https://v3-hub.atkgear.com/> ，按 `F12` 打开 DevTools，
切到 **Console（控制台）**，粘贴：

```js
(function(){
  var L = window.__atkLog = [];
  var H = function(d){
    try{
      var v = d instanceof DataView ? d : new DataView(d.buffer, d.byteOffset||0, d.byteLength);
      var s = '';
      for (var i=0;i<v.byteLength;i++) s += ('0'+v.getUint8(i).toString(16)).slice(-2);
      return s.toUpperCase().replace(/(..)/g,'$1 ').trim();
    }catch(e){ return 'ERR'; }
  };
  var P = function(t,o){ L.push({t:Date.now(), tag:t, d:o}); };
  var hd = function(d){
    if(!d) return;
    var s0 = d.sendReport.bind(d);
    d.sendReport = function(r,x){ P('S',{hex:H(x)}); return s0(r,x); };
    d.addEventListener('inputreport', function(e){ P('R',{hex:H(e.data)}); });
  };
  var gd = navigator.hid.getDevices.bind(navigator.hid);
  navigator.hid.getDevices = function(){ return gd().then(function(ds){ (ds||[]).forEach(hd); return ds; }); };
  var rq = navigator.hid.requestDevice.bind(navigator.hid);
  navigator.hid.requestDevice = function(o){ return rq(o).then(function(ds){ (ds||[]).forEach(hd); return ds; }); };
  navigator.hid.addEventListener('connect', function(e){ hd(e.device); });
  navigator.hid.getDevices().then(function(ds){ (ds||[]).forEach(hd); });
  console.log('%c[ATK] 钩子已安装','color:#0a0;font-size:14px');
})()
```

### 2. 连接鼠标

在页面上点「新增设备」→ 选中你的鼠标 → 连接。
等电量显示出来，**再等 15 秒**（让网页驱动把该读的寄存器都读完）。

### 3. 导出记录

在 Console 粘贴：

```js
copy(window.__atkLog.map(function(e){ return e.tag+' '+e.d.hex; }).join('\n'));
console.log('已复制 ' + window.__atkLog.length + ' 条');
```

内容已进剪贴板，粘到文本文件里即可。

### 4. 识别电量寄存器

在记录里找 `72 00 3A 00 <地址高> <地址低> <数据…>` 形式的回包：

```
S 7D 72 02 00 01 07 01        ← 发送的读请求
R 72 00 3A 00 07 01 53 FF FF  ← 回包：地址 0x0701，数据 0x53 = 83%
                              ↑ 对照网页上显示的电量，就知道哪个字节是电量
```

**关键**：把 `R` 行的第 7 个字节（下标 7）和网页显示的电量对比，就能确定电量位置。

---

## 已知的两个坑

### 坑 1：设备只接受它自己那套帧

改任何一个字节（比如换个寄存器地址）设备就**完全不理你**。所以必须原样重放抓到的帧。

### 坑 2：无线 / 有线是两套帧

鼠标**插数据线充电时会断开 2.4G 连接、切到 USB 直连模式**，PID 变化，并且需要**另一套帧**
（帧内第 5 字节的标志位从 `01` 变成 `00`，校验和随之不同）。

所以**两种模式都要分别抓一次**。

---

## 用本插件直接验证（不用开浏览器）

拿到候选帧后，可以写个小脚本直接测试。插件里的 `AtkHid` 类暴露了这些公开方法：

```powershell
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# 从 atk-tray.ps1 里提取并编译 AtkHid 类
$src = [IO.File]::ReadAllText('.\atk-tray.ps1')
$m = [regex]::Match($src, "(?s)Add-Type -Language CSharp -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Add-Type -Language CSharp -TypeDefinition $m.Groups[1].Value

# 枚举厂商接口
[AtkHid]::FindCommandInterfaces() | ForEach-Object { "pid=0x{0:X4}  {1}" -f $_.Pid, $_.Name }

# 打开接口、发送自定义帧、打印回包
$if = [AtkHid]::FindCommandInterfaces()[0]
$h  = [AtkHid]::OpenDevice($if.Path)
foreach ($r in [AtkHid]::Exchange($h, 64, [AtkHid]::ToFrame(@(0x7D,0x72,0x02,0x00,0x01,0x07,0x01)))) {
    ($r | ForEach-Object { $_.ToString('X2') }) -join ' '
}
[AtkHid]::CloseDevice($h)
```

> `ToFrame()` 会自动在前面补上 Report ID `0x08` 并用 0 填满 64 字节，
> 所以你只需要传 7 字节的帧主体。

---

## 参考

- [WebHID API](https://developer.mozilla.org/docs/Web/API/WebHID_API)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
