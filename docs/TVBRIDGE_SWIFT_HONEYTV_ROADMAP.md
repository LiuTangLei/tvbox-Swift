# TVBridge + SwiftTVBox 对齐蜂蜜 TV 开发文档

生成日期：2026-05-22

## 1. 结论

TVBridge + SwiftTVBox 这条路线是可行的，但当前还不能说“已经拥有蜂蜜 TV 的全部功能”。

原因分两层：

- 对 `type=3`、Jar/Py/QuickJS、Android 解析器、网盘授权、Android 本地代理这类 iOS/macOS 原生难以承载的能力，TVBridge 复用 Android/FongMi 运行时，技术上可以覆盖蜂蜜 TV 的核心内容获取与播放地址解析能力。
- 对播放器、直播、EPG/回看、弹幕字幕、DLNA/投屏、本地 HTTP 服务、备份同步、配置管理、TV 遥控体验等“产品功能”，SwiftTVBox 仍需要继续开发。Bridge 只能补动态源运行时，不能自动让 Swift UI、播放器和系统集成等价于 Android 客户端。

因此，正确目标应定义为：

1. TVBridge 作为 Android 兼容运行时，负责动态源、解析链、网盘授权、代理与 Android-only 能力。
2. SwiftTVBox 作为 iOS/macOS 播放与交互前端，负责配置、浏览、播放、直播、同步、远控和系统体验。
3. 两者通过稳定的 `PlayableItem` / Bridge API 合约衔接，而不是只传一个 URL 字符串。

## 2. 当前已具备的能力

### 2.1 TVBridge Android 端

本次已经强化 TVBridge 常驻运行能力：

- `BridgeServerService` 使用 `connectedDevice` 前台服务类型启动。
- 常驻通知使用 service category、低优先级、ongoing、immediate foreground behavior。
- 持有 `PARTIAL_WAKE_LOCK`、`WIFI_MODE_FULL_HIGH_PERF`、Wi-Fi multicast lock。
- 注册息屏/亮屏/解锁/电源变化动态广播，息屏时重确认 server 并重排 watchdog，不再默认启动 1 像素 Activity。
- 注册网络变化 callback，网络恢复后重确认 server。
- 使用 `AlarmManager.setAndAllowWhileIdle()` 做 9 分钟 watchdog，服务销毁或任务移除时 1 分钟内再拉起。
- 扩展开机、应用更新、解锁、部分 quick boot 自启动入口。
- Activity 提供通知权限、电池优化白名单、应用详情、厂商自启动/后台运行设置入口。

仍需实机验证的边界：Doze 深度空闲会暂停网络并忽略普通 wake lock；电池优化白名单是必须项，厂商后台策略仍可能杀进程。华为/Honor 的 `ZRHungService`/PowerGenie 类策略可能直接 force-stop 整个包；一旦进入 force-stop，普通 receiver、alarm 和 service 自恢复都不会运行，必须由用户重新打开 App 或使用设备级管理策略解除限制。

### 2.2 TVBridge API 面

Android Bridge 当前已经暴露以下关键能力：

- `/health`：版本、地址、端口、ABI、Jar/Chaquopy/QuickJS/native extractor 状态。
- `/api/v1/config/register`：注册配置 URL、顶层 `spider`、站点列表。
- `/api/v1/config/{configId}/sites`：返回 Bridge 可用站点。
- `/api/v1/site/{siteKey}/home`、`category`、`detail`、`search`：复用 `SiteApi` 或 Spider 对应方法。
- `/api/v1/site/{siteKey}/play`：执行 `playerContent`，并串起 `Source.fetch()`、Android parse、代理 URL 外部化。
- `/api/v1/site/{siteKey}/action`：执行 Spider action 或 Android 原生详情 UI fallback。
- `/api/v1/site/{siteKey}/token`：保存网盘 Token/Cookie。
- `/api/v1/site/{siteKey}/uiOpen`、`uiStatus`、`uiAction`、`uiClose`：Android Jar UI 截图、元素点击、输入、返回、刷新、关闭。
- `/bridge/local/*`、`/bridge/media/*`：本地代理与带 headers 的媒体代理，支持 Range/响应头透传。

这说明动态源和播放解析链路已经有较完整的 Android 端基础。

### 2.3 SwiftTVBox 端

Swift 端当前已经接入了 Bridge 的主路径：

- 设置页有 Type=3 Bridge 开关、地址和连通性检测。
- 配置解析时保留 `type=3` 源，并把站点级 `jar` 或顶层 `spider` fallback 传给 Bridge。
- `SourceService` 对 `type=3` 的首页、分类、详情、搜索走 `BridgeClient`。
- `DetailViewModel` 对 `type=3` 播放走 Bridge `play`，支持 Token prompt 和 Android Jar UI prompt。
- 首页 action 已能走 Bridge `action`，支持 Token prompt / Jar UI sheet。
- Swift 有 Android Jar UI sheet，可显示截图、元素 overlay、输入、提交、返回、刷新、轮询完成。

主要短板是：Bridge 播放结果在 Swift 端仍基本压缩成一个 URL 字符串，`headers`、`format`、`subtitles`、`danmakus`、`DRM`、`jxFrom` 等元数据还没有成为播放器输入模型。

## 3. 功能矩阵

| 功能域 | 当前状态 | 是否可通过 TVBridge 补齐 | 主要缺口 | 优先级 |
| --- | --- | --- | --- | --- |
| `type=3` Jar/Py/QuickJS 点播源 | 已接首页/分类/详情/搜索/播放/action | 可以 | 真机长期稳定性、异常恢复、批量样本回归 | P0 |
| Android 解析链、Web 嗅探、特殊协议 | Bridge 端已有 `ParseJob`、`Source.fetch()`、代理外部化 | 可以 | Swift 端缺 `PlayableItem`，未消费 subtitles/danmaku/format 等字段 | P0 |
| 网盘 Token/Cookie 与 Jar UI | 已有 prompt、保存、截图/元素操作 | 可以 | UI 操作容错、授权状态同步、自动重试和过期提示需加强 | P1 |
| 配置源管理 | Swift 能加载配置和保留 type=3 | 部分可补 | 多配置管理、本地导入、DoH/hosts/proxy/rules/ads/wallpaper 应用不足 | P1 |
| VOD 浏览与筛选 | 分类、分页、筛选、文件夹已有基础 | 主要在 Swift 端补 | 热门词、源级搜索开关、action 入口一致性、复杂字段展示 | P1 |
| 播放器 | AVPlayer/VLC 可播 URL，已有内嵌音轨/字幕部分能力 | Bridge 只能给数据，播放器需 Swift 补 | headers/DRM/subtitle/danmaku 入参、外挂字幕、轨道偏好、片头片尾、外部播放器、媒体会话 | P0/P1 |
| 弹幕与字幕 | 内嵌轨和字幕样式有基础 | Bridge 可返回字段，渲染需 Swift | 弹幕模型/overlay、远程外挂字幕、ASS/SSA/SRT/VTT 管理 | P2 |
| 直播 | Swift 已有 m3u/txt 分组播放、主页直播源选择、XMLTV EPG、catchup、headers/DRM 元数据、台标/频道号、收藏和隐藏分组解锁 | 需要新增 Bridge live API | DRM 播放支持、直播源历史/多配置管理 | P1/P2 |
| 本地 HTTP 服务/远控 | Android 有 Nano 服务，Swift 无本地 server | 不能只靠 TVBridge | Swift 本地 server、Web 控制台、push/search/control/media/upload/sync | P2 |
| DLNA/投屏 | Swift 缺失 | 需 Swift 原生或桥接扩展 | DLNA sender/renderer、UPnP 发现、AVTransport 控制 | P3 |
| 数据同步与备份 | Swift 有 SwiftData 基础历史/收藏 | 主要 Swift 补 | 备份包、恢复、跨设备同步、与 Android/Bridge 数据交换 | P2 |
| 本地文件/分享入口 | 部分基础能力 | 主要 Swift 补 | Document picker、URL scheme、Share Extension、字幕/配置/直播文件导入 | P2 |
| TV/tvOS/遥控体验 | 当前 iOS/macOS，无 tvOS target | 需 Swift 补 | tvOS target、焦点、遥控按键、语音搜索、快捷入口 | P3 |
| Bridge 部署运维 | Android 手机 APK 可用，保活已增强 | 需继续工程化 | mDNS/二维码配对、日志、升级、x86_64/emulator appliance、健康巡检 | P1 |

## 4. 开发路线

### P0：先把“能播”稳定住

目标：真机息屏后 Bridge 不断，`type=3` 源从浏览到播放可连续使用。

- 完成保活真机测试矩阵：亮屏、按 Home、锁屏 10 分钟、锁屏 1 小时、插电/不插电、Wi-Fi 切换、强制 Doze、重启后自启。
- 为 TVBridge 增加可视化日志页或导出日志：最近启动原因、watchdog 时间、锁状态、端口、最近 `/health`、最近异常。
- Swift `BridgeClient` 增加失败分类：未配置、不可达、server 5xx、Bridge 返回业务错误、播放解析超时、Jar UI 等待超时。
- Swift 播放不再只返回 `String` URL，新增 `PlayableItem`：`url`、`headers`、`format`、`subtitles`、`danmakus`、`drm`、`jxFrom`、`sourceKey`、`flag`、`episodeId`。
- `DetailViewModel`、`PlayerView`、`VLCPlayerView` 改用 `PlayableItem`，先消费 URL 和 headers/proxy，保留字段向后兼容。
- 建立 5 到 10 个公开配置样本的回归脚本：注册配置、列 sites、home/category/detail/search/play、验证返回 URL 或明确的 token/ui required。

验收标准：在已授予电池白名单和通知权限的 Android 手机上，Swift 连续播放 type=3 源，锁屏 30 分钟后 `/health` 可访问，继续点播不需要手动打开 Android App。

### P1：补齐 VOD/解析/授权体验

目标：点播体验接近蜂蜜 TV 常用路径。

- Bridge 播放结果完整映射：`subtitles`、`danmakus`、`format`、`parse`、`jxFrom`、`flag`、`headers`。
- Swift 播放器 headers 支持：AVPlayer 评估 `AVURLAssetHTTPHeaderFieldsKey` 可行性；VLC 走 media options；不可靠时强制 Bridge media proxy。
- Parse 选择与失败重试：展示当前解析来源，失败时可重试或切换解析器。
- Jar UI 授权加强：保存授权状态、过期检测、自动提交已保存凭据、授权失败时展示 provider 和字段。
- 首页 action 统一入口：文件夹、action、Android 原生详情 fallback、Jar UI 操作都要有一致提示。
- 搜索增强：热门词、源级搜索开关、多源搜索结果按源折叠/过滤、quick search 策略持久化。
- 配置增强：多配置历史、本地文件导入、配置描述、主页源可用性随 Bridge 开关自动重算。

验收标准：常见 type=3 源的普通播放、解析播放、网盘授权播放、Jar UI 授权播放均有明确 UI 闭环。

### P2：直播、字幕弹幕、同步与本地服务

目标：从“点播可用”扩展到蜂蜜 TV 的核心日常能力。

- 新增 Bridge live API：直播配置注册、频道列表、`liveContent`、直播代理、headers/DRM/catchup 元数据返回。
- Swift 直播模型扩展：补 DRM/ClearKey 播放支持、直播源历史和多配置管理。
- XMLTV/EPG 服务：继续完善多日缓存策略、日期导航体验和不同源格式兼容性。
- 字幕管理：远程/本地 SRT、VTT，样式、延迟、编码；ASS/SSA 评估 libass 或降级。
- 弹幕管理：Bridge 返回 danmaku 字段，Swift 实现弹幕解析和 overlay。
- Swift 本地 HTTP server：`/device`、`/media`、`/action?do=push/control/search`、`/upload`、历史/收藏同步。
- 备份恢复：导出 SwiftData、UserDefaults、配置历史、Bridge 设置；支持恢复前预览。

验收标准：直播带 EPG 和回看可用；远程浏览器可推送 URL/搜索/遥控 Swift 播放；历史收藏可备份恢复。

### P3：生态功能和平台体验

目标：补蜂蜜 TV 的高级外围能力和 Apple 平台体验。

- DLNA sender/renderer：发现、投屏、接收、AVTransport 控制。
- 外部播放器入口：按平台支持 VLC/IINA/Infuse/系统 URL scheme，保留回退。
- DRM/ClearKey：Bridge/配置返回 DRM 字段，Swift 播放器能力矩阵和失败提示。
- 播放偏好持久化：音轨、字幕轨、速度、比例、片头片尾、清晰度、线路、倒序。
- tvOS target：焦点系统、遥控器按键、直播快捷入口、语音搜索可行性评估。
- Bridge appliance：x86_64 Android emulator/KVM 部署、开机自启、健康巡检、自动升级、mDNS/二维码配对。

验收标准：macOS/iOS/tvOS 至少两个平台具有一致的配置、浏览、播放、直播和远控主路径；Bridge 可作为家庭局域网 appliance 长期运行。

## 5. 关键工程任务清单

### Android TVBridge

- 增加 Bridge 状态页：端口、IP、前台服务、WakeLock、WifiLock、multicast lock、watchdog、最近错误。
- 增加 `/health` 保活字段：`foregroundService`、`batteryOptimized`、`notificationGranted`、`watchdogNextAt`、`screenInteractive`、`networkType`。
- 增加日志 ring buffer，并提供 `/api/v1/logs` 或 Activity 导出。
- 增加 live endpoints，复用 Android `LiveConfig` / `LiveParser` / `LiveApi`。
- 为 media proxy 增加 token 续期和主动清理统计。
- 对 Bridge server APK 做 arm64/armeabi-v7a 真机包和将来的 x86_64 appliance 包能力矩阵。

### SwiftTVBox

- 新建 `PlayableItem`，替换 `DetailViewModel.playUrl: String?` 的核心传递路径。
- `BridgePlayResponse` 解码完整字段，不再只接受 `mode == "direct"` + `url`。
- AVPlayer/VLC 分别实现 headers、字幕、DRM、format 的能力矩阵，不支持时走 Bridge proxy 或显示降级原因。
- Live 模型扩展和 XMLTVService。
- LocalControlServer 和 Web 控制台协议。
- BackupManager/ConfigStore/DeviceSync。
- Bridge discovery：mDNS、扫码输入、历史地址健康状态。

## 6. 风险与限制

- Android 系统不允许普通应用无条件永久后台运行。前台服务、wake lock、Wi-Fi lock、watchdog 都不能绕过所有厂商策略；长期稳定必须让用户手动授予电池白名单/自启动/后台运行权限。1 像素 Activity 已从默认链路移除，因为在华为真机上会把可恢复的服务停止升级为整包 force-stop。
- Doze 深度空闲会暂停网络；电池优化豁免后才更接近常驻服务，但不同厂商仍可能限制。
- Jar UI 流程需要 Android 端可见或至少能截图/操作对应窗口；纯后台状态下并非所有 Jar UI 都可完成。
- x86_64 emulator appliance 不能默认承诺 ARM-only native extractor 等价能力，必须按 ABI 做能力上报。
- Swift 播放器和 Android ExoPlayer/Media3 能力不完全一致，尤其是 DRM、字幕格式、headers、外部播放器、媒体会话。

## 7. 推荐下一步

1. 用刚改好的 TVBridge APK 做真机保活测试，记录机型、系统、电池设置、锁屏时长、`/health` 是否可达。
2. 开发 `PlayableItem`，这是 Swift 端从“能播 URL”升级到“能承接 Bridge 完整播放结果”的关键前置。
3. 给 Bridge `/health` 增加保活诊断字段，方便排查真机熄屏断连到底是进程、网络、端口还是厂商策略问题。
4. 选 5 个常用 type=3 配置做自动化回归，先把点播主路径跑稳，再扩直播和远控。
