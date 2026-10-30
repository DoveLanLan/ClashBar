# ClashBar 跨平台配置同步协议

> 版本：`schemaVersion = 1`
> 适用：ClashBar for macOS（Swift）↔ ClashBar for Windows（待实现）
> 传输：WebDAV（首个目标服务商：坚果云 Nutstore）

---

## 1. 设计目标

| 目标 | 说明 |
|---|---|
| **配置可移植** | mihomo 的 `ClashBar.yaml` 在 macOS / Windows 上格式完全一致，直接同步 |
| **设置可解释** | 各平台的原生设置存储不同（UserDefaults vs 注册表/JSON），通过 `settings.json` 做中间层 |
| **低流量** | 只同步 2 个文件，避免把订阅缓存、规则缓存、mmdb 推到云端 |
| **无锁依赖** | 坚果云不支持 `LOCK`/`UNLOCK`，冲突靠时间戳而非 WebDAV 锁 |

### 明确不同步的内容

```
config/ASN.mmdb          8.3 MB   各平台 geo 数据自动下载
config/cache.db          256 KB   mihomo 运行时缓存
config/proxy/*.yaml      数百 KB   订阅节点缓存，各平台各自拉取
config/rule/*.yaml       数 MB     规则缓存，各平台各自拉取
core/mihomo              56 MB     内核二进制，各平台自行安装
logs/*                            本地日志
```

**这些文件平台相关或体积过大，同步会导致流量超限和版本错乱。**

---

## 2. 远端目录结构

```
<webdav-root>/ClashBar/
├── config/
│   └── ClashBar.yaml          # mihomo 主配置（必需）
├── settings.json              # 跨平台设置（必需）
└── meta.json                  # 元信息，用于冲突判定（必需）
```

> 建议 `<webdav-root>` 使用独立目录，例如 `https://dav.jianguoyun.com/dav/ClashBar/`。
> 不要把文件直接放在 WebDAV 根目录，避免和用户其他文件混淆。

---

## 3. `settings.json` Schema

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-10-30T15:45:00Z",
  "updatedBy": "macbook-air",
  "selectedConfig": "ClashBar.yaml",

  "core": {
    "mode": "rule",
    "allowLan": true,
    "ipv6": false,
    "tcpConcurrent": true,
    "tunEnabled": false,
    "logLevel": "info",
    "ports": {
      "http": 0,
      "socks": 0,
      "mixed": 7890,
      "redir": 0,
      "tproxy": 0
    }
  },

  "subscriptions": [
    {
      "name": "ikuuu",
      "url": "https://example.com/sub?token=xxx",
      "autoUpdate": true,
      "intervalHours": 6,
      "lastUpdateAt": "2026-10-30T14:20:00Z"
    }
  ],

  "systemProxy": {
    "enabledOnQuit": false,
    "exceptions": [
      "localhost",
      "127.*",
      "10.*",
      "172.16.*",
      "192.168.*",
      "100.64.0.0/10"
    ]
  },

  "ui": {
    "language": "zh-Hans",
    "appearance": "system"
  },

  "ssidRules": [
    {
      "ssid": "CompanyWiFi",
      "action": "direct"
    }
  ]
}
```

### 字段说明

| 字段 | 类型 | 必需 | 平台差异 |
|---|---|---|---|
| `schemaVersion` | Int | ✅ | 协议版本，当前 `1` |
| `updatedAt` | ISO8601 | ✅ | 写入时间，用于冲突判定 |
| `updatedBy` | String | ✅ | 设备名（`hostname`） |
| `selectedConfig` | String | ✅ | 当前激活的配置文件名 |
| `core.mode` | String | ✅ | `rule` / `global` / `direct` |
| `core.allowLan` | Bool | ✅ | mihomo `allow-lan` |
| `core.ipv6` | Bool | ✅ | mihomo `ipv6` |
| `core.tcpConcurrent` | Bool | ✅ | mihomo `tcp-concurrent` |
| `core.tunEnabled` | Bool | ✅ | TUN 模式 |
| `core.logLevel` | String | ✅ | `silent`/`error`/`warning`/`info`/`debug` |
| `core.ports.*` | Int | ✅ | `0` 表示不监听 |
| `subscriptions[]` | Array | ✅ | 空数组表示无订阅 |
| `subscriptions[].name` | String | ✅ | 显示名，作为唯一键 |
| `subscriptions[].url` | String | ✅ | 订阅地址（含 token） |
| `subscriptions[].autoUpdate` | Bool | ✅ | 是否自动更新 |
| `subscriptions[].intervalHours` | Int | ✅ | 更新间隔，最小 1 |
| `subscriptions[].lastUpdateAt` | ISO8601? | ❌ | 可为 null |
| `systemProxy.enabledOnQuit` | Bool | ✅ | 退出时是否保留系统代理 |
| `systemProxy.exceptions[]` | Array<String> | ✅ | 绕过列表，支持 `*` 通配 |
| `ui.language` | String | ✅ | `zh-Hans` / `en` |
| `ui.appearance` | String | ✅ | `system` / `light` / `dark` |
| `ssidRules[]` | Array | ✅ | macOS 专属逻辑，Windows 可忽略 |
| `ssidRules[].ssid` | String | ✅ | Wi-Fi 名称 |
| `ssidRules[].action` | String | ✅ | `direct` / `proxy` |

### 兼容性原则

- **新增字段**：必须带默认值，旧版本读到未知字段应忽略（不要报错）
- **删除字段**：不删除，标记 `deprecated`，保留至少 2 个版本
- **枚举值**：未知值按默认值处理（例如未知 `mode` 按 `rule`）
- **时间格式**：统一 ISO8601 UTC，`2026-10-30T15:45:00Z`

---

## 4. `meta.json`

用于快速冲突判定，避免每次都下载全量内容。

```json
{
  "schemaVersion": 1,
  "deviceName": "macbook-air",
  "updatedAt": "2026-10-30T15:45:00Z",
  "configSha256": "3f2a...",
  "settingsSha256": "9c1b...",
  "appVersion": "0.3.6",
  "platform": "macOS"
}
```

| 字段 | 用途 |
|---|---|
| `updatedAt` | **冲突判定主依据** |
| `configSha256` | 检测内容是否真的变化（避免无意义传输） |
| `settingsSha256` | 同上 |
| `deviceName` | UI 显示"最后修改设备" |
| `platform` | `macOS` / `Windows` |

> **为什么用 SHA256**：`updatedAt` 会因"打开设置页点保存"而变化，但内容可能没变。用哈希可以跳过无变化的同步，节省坚果云流量。

---

## 5. 同步协议

### 5.1 上传（Push）

```
1. HEAD meta.json           → 拿到远端 updatedAt
2. 收集本地快照              → config + settings
3. 计算 sha256
4. 若 sha256 == 远端 sha256  → 跳过（无变化）
5. MKCOL ClashBar/          → 忽略 405（已存在）
6. MKCOL ClashBar/config/   → 同上
7. PUT ClashBar/config/ClashBar.yaml
8. PUT ClashBar/settings.json
9. PUT ClashBar/meta.json   ← 最后写，作为"提交标记"
```

> **`meta.json` 最后写的意义**：如果中途失败，远端 `meta.json` 仍是旧的，下次同步能检测到不一致并重传。这是 WebDAV 无事务的补偿手段。

### 5.2 下载（Pull）

```
1. GET meta.json            → 404 则视为远端为空
2. GET settings.json
3. GET config/ClashBar.yaml
4. 校验 sha256
5. 备份本地到 config/ClashBar.yaml.bak-<timestamp>
6. 写入本地
7. 按 settings.core.* 应用运行参数（端口/模式等）
```

### 5.3 双向同步（Sync）

```
本地 mtime = max(config/ClashBar.yaml mtime, settings 快照 mtime)
远端 mtime = meta.json 的 updatedAt

若 远端不存在:                 → Push
若 本地 > 远端 + 30s:          → Push
若 远端 > 本地 + 30s:          → Pull
若 差值 ≤ 30s:                 → 视为已同步，跳过
```

> **30 秒容差**：文件系统时间精度 + 网络延迟会导致误判，需要容差。

### 5.4 冲突处理

坚果云不支持 `LOCK`，所以采用**「后写覆盖 + 本地备份」**策略：

```
检测到冲突（双向都有修改）
  → 保留本地副本: settings.local-backup.json
  → 下载远端覆盖本地
  → UI 提示用户："检测到其他设备修改，已下载远端版本，本地备份保留"
```

**不实现自动合并**：配置合并语义复杂（例如两边都改了端口），自动合并容易产生非法配置。宁可让用户手动选。

---

## 6. 坚果云（Nutstore）适配要点

### 6.1 认证

```
端点: https://dav.jianguoyun.com/dav/
认证: HTTP Basic Auth
用户名: 坚果云登录邮箱
密码:   ⚠️ 应用密码（不是登录密码）
```

获取应用密码：坚果云网页 → 账户信息 → 安全选项 → 添加应用 → 生成密码

### 6.2 限制与对策

| 限制 | 数值 | 对策 |
|---|---|---|
| 免费版月上传流量 | 1 GB | 只同步 2 个文件（配置 ~24KB + settings ~2KB），单次同步 <30KB |
| 免费版月下载流量 | 3 GB | 同上 |
| `PROPFIND` 频率限制 | 较严 | **优先用 `HEAD`**，只在需要列目录时用 `PROPFIND` |
| 不支持 `LOCK`/`UNLOCK` | — | 用时间戳 + SHA256 判冲突 |
| `MKCOL` 已存在返回 | `405` | 视为成功 |
| 单文件大小 | 有限制 | 不适用（文件都很小） |

### 6.3 请求频率建议

- 自动同步间隔 **≥ 5 分钟**
- 连续失败后指数退避（1min → 5min → 15min → 1h）
- 遇到 `503` / `429` 立即停止本次同步，等下一轮

---

## 7. 各平台实现映射

### 7.1 macOS（Swift）

| settings.json 字段 | 本地来源 |
|---|---|
| `core.*` | `AppViewModel.EditableSettingsSnapshot` |
| `subscriptions[]` | `clashbar.config.remote.subscriptions.v2`（UserDefaults JSON） |
| `systemProxy.exceptions[]` | `clashbar.system_proxy.exceptions.v1` |
| `ui.language` | `clashbar.ui.language` |
| `ui.appearance` | `clashbar.ui.appearance.mode` |
| `ssidRules[]` | `clashbar.ssid.strategy.rules.v1` |
| `selectedConfig` | `clashbar.config.selected.filename` |

### 7.2 Windows（待实现）

| settings.json 字段 | 建议本地来源 |
|---|---|
| `core.*` | 与 mihomo `config.yaml` 双向映射 |
| `subscriptions[]` | 应用自己的 `subscriptions.json` |
| `systemProxy.exceptions[]` | Windows 注册表 `ProxyOverride` |
| `ui.language` / `ui.appearance` | 应用设置文件 |
| `ssidRules[]` | 忽略（Windows 无对应概念）|

### 7.3 mihomo 配置处理

`config/ClashBar.yaml` **直接原样同步**，不做任何转换：

- macOS 和 Windows 上的 mihomo 使用**完全相同的 YAML 格式**
- 但要注意 **端口一致性**：`mixed-port` 等字段在 `settings.core.ports` 里也有，必须保持一致
- 同步后需重启内核才能生效

---

## 8. 安全说明

> **当前决策：不加密**（与 v2rayN 备份行为一致）

同步到云端的文件包含：

- 订阅 URL 及 token
- 节点密码 / UUID
- 系统代理配置

**必须遵守的约束：**

1. 坚果云**应用密码单独保管**，不要复用登录密码
2. 不要把同步目录设为公开分享
3. 传输层由 HTTPS 保护（坚果云强制 TLS），但**静态存储是明文**
4. 若未来需要加密，建议在 `settings.json` 外层加 AES-GCM 封装，文件改为 `settings.json.enc`

---

## 9. 版本演进

| schemaVersion | 变更 |
|---|---|
| 1 | 初始版本 |

**升级规则**：
- 高版本写入、低版本读取时，忽略未知字段，保留原值回写（防止降级丢失数据）
- `schemaVersion` 不兼容变更时才 +1；新增可选字段不 +1
