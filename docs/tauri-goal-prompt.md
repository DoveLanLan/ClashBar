# ClashBar for Windows — Tauri + React 开发目标

> 这是一份可直接投喂给 AI 编码助手的 goal prompt。
> 目标：在 Windows 上用 Tauri 2 + React 复刻 macOS 版 ClashBar，**UI 与操作方式保持一致**。

---

## 0. 一句话目标

用 **Tauri 2 + React 19 + TypeScript** 实现一个 Windows 菜单栏（托盘）代理客户端，视觉与交互**逐项对齐** macOS 版 ClashBar（面板宽 360px、5 个 Tab、折叠卡片式设置），并与 macOS 版共用同一套 mihomo 配置与 WebDAV 同步协议。

---

## 1. 硬性约束（不可妥协）

| 约束 | 说明 |
|---|---|
| **面板宽度固定 360px** | 与 macOS 版一致，不允许自适应放大 |
| **5 个 Tab 顺序固定** | 节点 / 分流 / 连接 / 日志 / 设置 |
| **模式切换在 Tab 上方** | 规则 / 全局 / 直连，三选一 |
| **设置页用折叠卡片** | 不是扁平列表，必须可折叠展开 |
| **配置文件零转换** | 直接读写 mihomo 的 YAML，不做中间格式 |
| **同步协议零改动** | 严格按 `docs/sync-protocol.md` 实现 |
| **无 Dock/任务栏主窗口** | 只在托盘 + 弹出面板，不占任务栏 |

---

## 2. 技术栈（已定，不要更换）

```
Tauri             2.x（Rust 后端 + WebView2）
React             19.x
TypeScript        5.x（strict）
状态管理          Zustand（轻量，替代 SwiftUI 的 @Published）
样式              Tailwind CSS 4 + CSS Variables
组件基础          Radix UI primitives（无样式，自行套皮）
图标              lucide-react（对应 SF Symbols）
虚拟列表          @tanstack/react-virtual（987 节点必须虚拟化）
请求              @tauri-apps/plugin-http 或前端 fetch
```

**不要用**：Electron（体积）、Ant Design / MUI（视觉风格不符）、Next.js（不需要 SSR）。

---

## 3. UI 规格（从 macOS 版逐项提取）

### 3.1 尺寸与间距

```css
/* 精确对齐 macOS 版 MenuBarLayoutTokens.swift */
--panel-width: 360px;
--space-1: 1px;
--space-2: 2px;
--space-4: 4px;
--space-6: 6px;
--space-8: 8px;
--radius-panel: 10px;
--radius-item: 6px;
--row-height: 32px;
--row-height-compact: 20px;
--row-leading-icon: 16px;
--stroke-width: 0.65px;
```

### 3.2 字号

| 用途 | 大小 |
|---|---|
| 状态栏 / caption | 10px |
| subheadline | 11px |
| callout | 12px |
| **body（正文，最常用）** | **13px** |
| title3 | 15px |
| title2 | 17px |

### 3.3 动画与阴影

```css
--duration-quick: 150ms;
--duration-standard: 350ms;
--shadow-panel: 0 6px 12px rgba(0, 0, 0, 0.20);
```

**折叠卡片动画**必须用 spring 曲线近似：

```css
transition: max-height 300ms cubic-bezier(0.34, 1.20, 0.64, 1),
            opacity 300ms cubic-bezier(0.34, 1.20, 0.64, 1);
/* macOS 版原值：spring(response: 0.30, dampingFraction: 0.80) */
```

### 3.4 面板外观

- 圆角 10px，边框 0.65px
- **半透明磨砂**：`backdrop-filter: blur(24px) saturate(180%)`
  （Windows WebView2 支持，需要用 `background: rgba(var(--bg), 0.92)`）
- 弹出位置：托盘图标正下方，右对齐，距屏幕边缘 8px
- 点击面板外部自动关闭（需要监听 `window.blur`）

### 3.5 主题

必须支持 `浅色 / 深色 / 跟随系统`，用 CSS 变量切换：

```css
:root[data-theme="light"] {
  --label-primary: rgba(0,0,0,0.85);
  --label-secondary: rgba(0,0,0,0.55);
  --label-tertiary: rgba(0,0,0,0.35);
  --bg-panel: 255 255 255;
}
:root[data-theme="dark"] {
  --label-primary: rgba(255,255,255,0.92);
  --label-secondary: rgba(255,255,255,0.55);
  --label-tertiary: rgba(255,255,255,0.35);
  --bg-panel: 30 30 30;
}
```

---

## 4. 整体布局

```
┌─────────────────────────────────────────┐
│ Header                                  │  标题 "ClashBar" + 版本
│ [ClashBar]  [🌐 WebUI]     连接数 42 ˅   │  + WebUI 按钮 + 连接数
├─────────────────────────────────────────┤
│ Mode/Tab Section                        │
│ ┌─────────┬─────────┬─────────┐         │  模式：规则/全局/直连
│ │  规则   │  全局   │  直连   │         │
│ └─────────┴─────────┴─────────┘         │
│ ┌────┬────┬────┬────┬────┐              │  Tab（带图标）
│ │节点│分流│连接│日志│设置│              │
│ └────┴────┴────┴────┴────┘              │
├─────────────────────────────────────────┤
│ Content (ScrollView, 自适应高度)         │
│                                         │
│   ...每个 Tab 的内容...                  │
│                                         │
├─────────────────────────────────────────┤
│ Footer                                  │
│ [系统代理 ▢] [TUN ▢]      上传 1.2MB/s  │
└─────────────────────────────────────────┘
```

---

## 5. 功能清单（逐 Tab）

### 5.1 Header

- 标题 `ClashBar` + 版本号（小字）
- **WebUI 按钮**（地球图标）：用系统浏览器打开 mihomo 的 `external-ui`
- **连接数显示**：`42 ˅`，点击展开连接明细（跳到连接 Tab）

### 5.2 节点 Tab（`square.grid.2x2.fill`）

**区块 1：订阅提供者（可折叠）**

```
▾ 订阅提供者                                    (14)
  ┌───────────────────────────────────────┐
  │ p_chatgpt          396 节点   ⟳  ⋯    │
  │ p_speed1m          390 节点   ⟳  ⋯    │
  └───────────────────────────────────────┘
```

- 折叠按钮在区块标题右侧，chevron 旋转 90°
- 每行：名称 + 节点数 + 刷新按钮 + 更多菜单（测延迟 / 编辑 / 删除）
- 刷新中显示 spinner，禁用按钮

**区块 2：策略组**

```
⚙️ 自定义代理              日本-优化 ˅      ▸
  ├─ 🇯🇵 日本-Trojan-85       92ms  ●
  ├─ 🇯🇵 日本-Trojan-183     101ms  ○
  └─ 日本-优化                85ms  ●
```

- 组头：名称 + 当前选择 + 延迟 + 展开箭头
- `select` 类型组：点击节点切换
- `url-test` 类型组：显示自动选中的节点，标注 `自动`
- 节点行：名称 + 延迟徽章 + 选中圆点
- **延迟徽章按数值着色**：<100ms 绿 / <300ms 黄 / 其他红 / 未测 灰

**工具栏**（区块标题右侧三个图标按钮）：

| 图标 | 功能 |
|---|---|
| `arrow.up.arrow.down` | 按延迟排序（切换开/关） |
| `chart.line.uptrend.xyaxis` | 显示/隐藏延迟历史 |
| `eye` / `eye.slash` | 隐藏 `hidden: true` 的组 |

**性能要求**：987 个节点必须用虚拟列表，滚动 60fps。

### 5.3 分流 Tab（`arrow.left.arrow.right`）

```
▾ 规则                                         (127)
  ┌───────────────────────────────────────┐
  │ RULE-SET    OpenAI      → 🤖 人工智能  │
  │ GEOSITE     google      → ⚙️ 自定义代理│
  │ DOMAIN-SUFF    yanwentech.com → DIRECT │
  │ IP-CIDR     100.64.0.0/10     → DIRECT │
  └───────────────────────────────────────┘
```

- 每行：规则类型（等宽字体）+ 内容（省略号截断）+ 箭头 + 目标策略
- 顶部搜索框，实时过滤
- 目标策略用彩色标签（DIRECT 绿 / REJECT 红 / 组名蓝）

### 5.4 连接 Tab（`link`）

```
活跃连接 (42)                    [关闭全部]
┌──────────────────────────────────────────┐
│ Chrome    api.anthropic.com:443          │
│ ↕ 12.3 KB  ↑ 4.1 KB   ⚙️ 自定义代理      │
├──────────────────────────────────────────┤
│ OrbStack  1.1.1.1:443                    │
│ ↕ 890 B    ↑ 210 B    DIRECT             │
└──────────────────────────────────────────┘
```

- 每行：进程名 + 目标地址 + 上下行流量 + 命中的策略
- 顶部：连接总数 + 「关闭全部」按钮
- 实时更新（mihomo 的 WebSocket `/connections`）

### 5.5 日志 Tab（`doc.fill`）

```
[全部 ▢] [信息] [警告] [错误]      [清空] [暂停]
┌──────────────────────────────────────────┐
│ 16:23:41 INFO  [TCP] google.com → proxy  │
│ 16:23:42 WARN  rule-set timeout          │
│ 16:23:43 ERROR connection refused        │
└──────────────────────────────────────────┘
```

- 顶部两排筛选：级别（全部/信息/警告/错误）+ 来源（ClashBar/Mihomo）
- 右侧：清空 / 暂停滚动
- 等宽字体，自动滚到底部（暂停时不滚）
- 最多保留 5000 条

### 5.6 设置 Tab（`gearshape.fill`）— **重点**

**必须用折叠卡片结构**，与 macOS 版一致：

```
┌─ 基础设置 ───────────────────────────┐
│ 开机自启                      [开关] │
│ 内核自启                      [开关] │
│ 菜单栏样式                    [图标▾]│
│ 语言                        [简体中文▾]│
│ 外观                        [跟随系统▾]│
│ 日志级别                      [info▾]│
│ ▸ 代理绕过                     (5) › │  ← 折叠
│ ▸ 配置同步               已同步 16:20 › │  ← 折叠
└──────────────────────────────────────┘

┌─ 核心设置 ───────────────────────────┐
│ 允许局域网连接                 [开关] │
│ IPv6                         [开关] │
│ TCP 并发                     [开关] │
│ TUN 模式                     [开关] │
│ HTTP 端口                    [   0 ]│
│ SOCKS 端口                   [   0 ]│
│ 混合端口                     [7890 ]│
│ Redir 端口                   [   0 ]│
│ TProxy 端口                  [   0 ]│
└──────────────────────────────────────┘

┌─ 维护 ───────────────────────────────┐
│ [清理 FakeIP 缓存] [清理 DNS 缓存]   │
│ [更新 GEO 数据库]  [打开核心目录]     │
└──────────────────────────────────────┘
```

#### 折叠卡片规格（复刻 macOS 版）

**折叠状态**（header 行）：

```tsx
<button className="flex items-center gap-2 h-8 px-1 w-full">
  <Icon size={14} strokeWidth={2} className="text-tertiary" />
  <span className="text-[13px] font-medium flex-1 text-left">代理绕过</span>
  <span className="text-[10px] text-secondary">(5)</span>
  <ChevronRight className="w-3 h-3 transition-transform duration-150"
                style={{ transform: expanded ? 'rotate(90deg)' : 'none' }} />
</button>
```

**展开内容**：

```tsx
<div
  className="overflow-hidden"
  style={{
    maxHeight: expanded ? '2000px' : '0px',
    opacity: expanded ? 1 : 0,
    transition: 'max-height 300ms cubic-bezier(0.34,1.20,0.64,1), opacity 300ms',
  }}
>
  {/* 内容 */}
</div>
```

**间距**：每行 `padding: 6px 4px`（垂直 6px / 水平 4px）

#### 配置同步卡片（WebDAV）

折叠状态下右侧直接显示状态：

| 状态 | 显示 | 颜色 |
|---|---|---|
| 未配置 | `未同步` | 灰 |
| 同步中 | `同步中…` | 橙 |
| 成功 | `已同步 MM-dd HH:mm` | 绿 |
| 失败 | 错误信息 | 红 |

展开后：

```
同步当前配置与设置。坚果云请使用「应用密码」，不是登录密码。

WebDAV 服务器
[ https://dav.jianguoyun.com/dav/           ]

账号（邮箱）
[ you@example.com                           ]

应用密码
[ ••••••••••••••••                          ]

远端目录
[ ClashBar                                  ]

启动时同步                           [开关]
定时自动同步                         [开关]

[  上传  ]  [  下载  ]  [  同步  ]
```

---

## 6. Tauri 特有能力映射

### 6.1 托盘图标 + 弹出面板

```rust
// src-tauri/src/tray.rs
use tauri::tray::{TrayIconBuilder, TrayIconEvent};
use tauri::{Manager, WebviewWindowBuilder, WebviewUrl};

pub fn setup_tray(app: &mut tauri::App) -> tauri::Result<()> {
    TrayIconBuilder::new()
        .icon(load_icon("brand_sleep.png"))   // 三种状态图标
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, .. } = event {
                toggle_panel(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

fn toggle_panel(app: &AppHandle) {
    let win = app.get_webview_window("panel").unwrap();
    if win.is_visible().unwrap() {
        win.hide().unwrap();
    } else {
        position_under_tray(&win);   // 计算托盘图标位置
        win.show().unwrap();
        win.set_focus().unwrap();
    }
}
```

**窗口配置**（`tauri.conf.json`）：

```json
{
  "label": "panel",
  "url": "index.html",
  "width": 360,
  "height": 600,
  "resizable": false,
  "decorations": false,
  "transparent": true,
  "alwaysOnTop": true,
  "skipTaskbar": true,
  "visible": false,
  "shadow": false
}
```

**点击外部关闭**：

```ts
// 前端监听失焦
import { getCurrentWindow } from '@tauri-apps/api/window';
getCurrentWindow().onFocusChanged(({ payload: focused }) => {
  if (!focused) getCurrentWindow().hide();
});
```

### 6.2 托盘图标动态切换

macOS 版有三种状态图标（`BrandRun` / `BrandSleep` / `BrandTun`）。Windows 需要：

```rust
// 根据状态切换托盘图标 + 可选显示速度文字
fn update_tray_icon(app: &AppHandle, state: CoreState, speed: Option<(u64, u64)>) {
    let path = match state {
        CoreState::Running => "brand_run.png",
        CoreState::Stopped => "brand_sleep.png",
        CoreState::Tun     => "brand_tun.png",
    };
    app.tray_by_id("main").unwrap().set_icon(Some(load_icon(path))).unwrap();

    // Windows 支持在托盘图标旁显示文字（macOS 不支持）
    // 可作为增强：显示 ↑1.2M ↓3.4M
    if let Some((up, down)) = speed {
        app.tray_by_id("main").unwrap().set_title(Some(
            format!("↑{} ↓{}", human_speed(up), human_speed(down))
        )).unwrap();
    }
}
```

### 6.3 mihomo 内核管理（Sidecar）

```json
// tauri.conf.json
{
  "bundle": {
    "externalBin": ["binaries/mihomo"]
  }
}
```

```rust
// src-tauri/src/core.rs
use tauri_plugin_shell::ShellExt;

pub async fn start_core(app: &AppHandle, config_dir: &Path) -> Result<Child> {
    let sidecar = app.shell()
        .sidecar("mihomo")?
        .args(["-d", config_dir.to_str().unwrap(), "-f", "ClashBar.yaml"]);
    let (mut rx, child) = sidecar.spawn()?;

    // 转发 stdout/stderr 到前端（日志 Tab 需要）
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            if let CommandEvent::Stdout(line) = event {
                app.emit("core-log", String::from_utf8_lossy(&line).to_string()).ok();
            }
        }
    });

    Ok(child)
}
```

**内核位置**：`%APPDATA%\ClashBar\core\mihomo.exe`
（对应 macOS 的 `~/Library/Application Support/ClashBar/core/mihomo`）

**下载内核**（首次启动或版本更新）：

```rust
// 从 https://github.com/MetaCubeX/mihomo/releases 下载
// 选 mihomo-windows-amd64-vX.Y.Z.zip
// 解压出 mihomo.exe → core/mihomo.exe
```

### 6.4 系统代理（Windows 注册表）

```rust
use windows::Win32::Networking::WinInet::{
    InternetSetOptionW, INTERNET_OPTION_SETTINGS_CHANGED, INTERNET_OPTION_REFRESH,
};
use winreg::enums::*;
use winreg::RegKey;

const IE_SETTINGS: &str = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

pub fn set_system_proxy(host: &str, port: u16, bypass: &[String]) -> Result<()> {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let (key, _) = hkcu.create_subkey(IE_SETTINGS)?;

    key.set_value("ProxyEnable", &1u32)?;
    key.set_value("ProxyServer", &format!("{host}:{port}"))?;
    key.set_value("ProxyOverride", &bypass.join(";"))?;

    // 让系统立即生效（不加这一步要等几秒或重启浏览器）
    unsafe {
        InternetSetOptionW(None, INTERNET_OPTION_SETTINGS_CHANGED, None, 0)?;
        InternetSetOptionW(None, INTERNET_OPTION_REFRESH, None, 0)?;
    }
    Ok(())
}

pub fn clear_system_proxy() -> Result<()> {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let (key, _) = hkcu.open_subkey_with_flags(IE_SETTINGS, KEY_WRITE)?;
    key.set_value("ProxyEnable", &0u32)?;
    unsafe {
        InternetSetOptionW(None, INTERNET_OPTION_SETTINGS_CHANGED, None, 0)?;
        InternetSetOptionW(None, INTERNET_OPTION_REFRESH, None, 0)?;
    }
    Ok(())
}
```

**默认绕过列表**（与 macOS 版一致）：

```
localhost;127.*;10.*;172.16.*;172.17.*;...;192.168.*;100.64.0.0/10
```

### 6.5 TUN 模式

Windows 需要 **wintun.dll**（比 macOS 的 utun 复杂）：

1. 下载 `wintun.dll`（`https://www.wintun.net/`，amd64）
2. 放到 `%APPDATA%\ClashBar\core\wintun.dll`
3. mihomo 配置 `tun: { enable: true, stack: mixed }`
4. **必须以管理员权限运行**（否则 TUN 创建失败）

**提权方式**：manifest 声明 `requireAdministrator`，或者用任务计划程序（`schtasks`）注册一个高权限任务。

**推荐**：不强制全局管理员，而是像 macOS 版那样装一个「特权辅助服务」：首次启用 TUN 时弹 UAC 安装 Windows 服务，后续通过本地命名管道通信。

---

## 7. WebDAV 同步（严格按协议）

### 7.1 必读

`docs/sync-protocol.md`（与 macOS 版共用）

### 7.2 远端结构

```
<webdav-root>/ClashBar/
├── config/ClashBar.yaml     ← mihomo 配置，直接可用
├── settings.json            ← 跨平台设置
└── meta.json                ← SHA256 + 时间戳
```

### 7.3 实现要点

| 要点 | 说明 |
|---|---|
| 认证 | Basic Auth，密码是坚果云**应用密码** |
| **不要用 PROPFIND** | 坚果云限流，用 `HEAD` 代替 |
| **MKCOL 要逐级创建** | 父目录缺失返回 `409 Conflict` |
| **meta.json 最后写** | 作为无事务场景的提交标记 |
| 冲突判定 | `updatedAt` 30 秒容差 |
| 拉取前备份 | `ClashBar.yaml.bak-sync-<yyyyMMdd-HHmmss>` |

### 7.4 Rust 实现骨架

```rust
// src-tauri/src/sync/webdav.rs
use reqwest::{Client, Method};
use base64::{Engine, engine::general_purpose::STANDARD};

pub struct WebDAVClient {
    client: Client,
    root: Url,
    auth: String,
}

impl WebDAVClient {
    pub fn new(endpoint: &str, dir: &str, user: &str, pass: &str) -> Result<Self> {
        let root = Url::parse(endpoint)?.join(&format!("{}/", dir))?;
        let auth = format!("Basic {}", STANDARD.encode(format!("{user}:{pass}")));
        // 关键：禁用系统代理，避免与自身代理形成环路
        let client = Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self { client, root, auth })
    }

    pub async fn ensure_dir(&self, path: &str) -> Result<()> {
        // 逐级 MKCOL
        for segment in accumulate_segments(path) {
            let resp = self.request(Method::from_bytes(b"MKCOL")?, &segment).send().await?;
            // 201 Created / 405 Already Exists
            if !matches!(resp.status().as_u16(), 201 | 405) {
                bail!("MKCOL {} failed: {}", segment, resp.status());
            }
        }
        Ok(())
    }

    pub async fn head(&self, path: &str) -> Result<FileState> { /* ... */ }
    pub async fn put(&self, path: &str, data: &[u8]) -> Result<()> { /* ... */ }
    pub async fn get(&self, path: &str) -> Result<Vec<u8>> { /* ... */ }
}
```

---

## 8. 验收标准（必须逐条实测通过）

### 8.1 视觉一致性

- [ ] 面板宽度 **360px**，圆角 10px，半透明磨砂
- [ ] 5 个 Tab 顺序、图标、文案与 macOS 版一致
- [ ] 正文 13px，caption 10px，间距 4/6/8px
- [ ] 折叠卡片有 chevron 旋转 + spring 展开动画
- [ ] 浅色/深色主题切换正常

### 8.2 功能完整性

- [ ] 托盘图标三种状态（运行/停止/TUN）正确切换
- [ ] 点击托盘弹出面板，点击外部关闭
- [ ] 节点 Tab 能展示 987 个节点，滚动流畅（虚拟列表）
- [ ] 点击节点能切换策略组，延迟徽章着色正确
- [ ] 分流 Tab 展示 127 条规则，搜索过滤正常
- [ ] 连接 Tab 实时更新，能关闭单个/全部连接
- [ ] 日志 Tab 实时滚动，筛选/暂停/清空正常
- [ ] 设置页所有折叠卡片能展开收起
- [ ] 系统代理开关真正修改注册表，浏览器立即生效

### 8.3 配置与同步

- [ ] 能加载 macOS 版同步下来的 `ClashBar.yaml`（987 节点）
- [ ] 修改端口/模式后写回 YAML
- [ ] 配置同步「上传」成功，`meta.json` SHA256 正确
- [ ] 配置同步「下载」后自动备份旧文件
- [ ] 与 macOS 版双向同步无冲突（时间戳判定）

### 8.4 稳定性

- [ ] 内核崩溃后能自动重启
- [ ] 同步失败有明确错误提示（不是空泛的「失败」）
- [ ] 退出程序时恢复系统代理（如果用户选了「退出保留」则保留）

---

## 9. 分阶段实施

### P0 — 骨架与托盘（1-2 天）

1. `pnpm create tauri-app` 初始化
2. 托盘图标 + 360px 弹出面板 + 点击外部关闭
3. Header + 5 Tab 空壳（切换正常）
4. 主题变量 + Tailwind 配置

**验收**：点击托盘弹出 360px 面板，Tab 能切换，点外部关闭。

### P1 — 内核与基础控制（2-3 天）

1. mihomo sidecar（下载/启动/停止/日志转发）
2. mihomo API 客户端（9090：`/version` `/proxies` `/configs`）
3. 节点 Tab：订阅 provider + 策略组 + 节点列表（先不做虚拟化）
4. 模式切换（rule/global/direct）
5. 系统代理开关（注册表 + InternetSetOption）

**验收**：能启动内核，看到节点，切换模式，系统代理生效。

### P2 — 完整功能（3-4 天）

1. 虚拟列表（987 节点 60fps）
2. 延迟测试 + 延迟徽章着色
3. 分流 / 连接 / 日志三个 Tab
4. 设置页全部折叠卡片
5. 端口配置写回 YAML

**验收**：**§8.2 全部通过**

### P3 — 同步（2-3 天）

1. WebDAV 客户端（HEAD/PUT/GET/MKCOL）
2. `settings.json` 读写（严格按 schema）
3. push / pull / sync
4. 冲突判定 + 备份

**验收**：**§8.3 全部通过**

### P4 — 打磨（2 天）

1. TUN 模式（wintun + 提权服务）
2. 开机自启（注册表 Run 项）
3. 托盘图标速度文字
4. 安装包（NSIS / MSI）+ 自动更新

---

## 10. 已知陷阱（提前规避）

| 陷阱 | 后果 | 规避 |
|---|---|---|
| **WebView2 透明失效** | 面板出现黑边 | `tauri.conf.json` 里 `transparent: true` + CSS `background: transparent`，且 **必须** `decorations: false` |
| **`alwaysOnTop` 抢占焦点** | 点其他窗口后面板不消失 | 用 `window.blur` 事件监听，而不是轮询 |
| **托盘图标位置算错** | 面板跑偏到屏幕外 | 用 `tray.rect()` 拿图标矩形，按 `scaleFactor` 换算物理像素 |
| **mihomo 端口冲突** | 内核启动失败 | 启动前检查 9090/7890 是否占用，冲突时提示用户改端口 |
| **注册表代理不立即生效** | 用户以为没生效 | 必须调 `InternetSetOptionW` 两次（SETTINGS_CHANGED + REFRESH）|
| **TUN 需要管理员** | 静默失败 | 明确提示需要 UAC，或用特权服务 |
| **坚果云 409** | 同步失败 | MKCOL **逐级**创建，不要一次建多级 |
| **坚果云 503 限流** | 同步失败 | 用 HEAD 不用 PROPFIND；失败后指数退避 |
| **987 节点卡顿** | 面板卡死 | 必须虚拟列表，不要全量渲染 |
| **YAML 中文乱码** | 配置损坏 | 读写统一 UTF-8，不要 BOM |

---

## 11. 参考资源

| 资源 | 用途 |
|---|---|
| https://github.com/DoveLanLan/ClashBar | macOS 版源码（UI/逻辑参考） |
| `docs/sync-protocol.md` | **同步协议，必须严格实现** |
| https://github.com/MetaCubeX/mihomo | 内核 + API 文档 |
| https://wiki.metacubex.one/ | mihomo 配置文档 |
| https://github.com/clash-verge-rev/clash-verge-rev | Tauri 实现的成熟参考（结构可借鉴）|
| https://www.wintun.net/ | TUN 驱动 |

---

## 12. 交付物

1. 可运行的 Windows 安装包（NSIS）
2. 源码（含 Rust 后端 + React 前端）
3. `README.md`：构建步骤、已知限制
4. 与 macOS 版同步的实测截图（配置同步前后对比）

---

## 13. 第一条命令

```bash
pnpm create tauri-app clashbar-windows --template react-ts
cd clashbar-windows
pnpm install
pnpm tauri dev
```

第一个里程碑：**把面板做出来（360px，托盘弹出，5 Tab 空壳）**，再往下做功能。
