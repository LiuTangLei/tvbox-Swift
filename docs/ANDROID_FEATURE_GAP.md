# tvbox-Swift 与蜂蜜影视 Android 大功能差异文档

生成日期：2026-04-30

## 1. 分析口径

本文对比对象是：

- Android 端：`TV/`，以蜂蜜影视/FongMi Android TV 当前代码为准，覆盖 `main`、`mobile`、`leanback` 三个 source set。
- Swift 端：`tvbox-Swift/`，覆盖 iOS 与 macOS target。

明确排除：

- `type=3` Spider/Jar 源本身。
- Java Jar、Py、QuickJS、动态脚本运行时及其桥接 API。

仍纳入差异：

- 不依赖动态脚本运行的配置、播放器、直播、局域网、投屏、备份同步、本地文件、解析嗅探、字幕弹幕、TV 体验等能力。
- `type=0` XML、`type=1` JSON、`type=4` Remote API 的支持完整度。
- 配置里可静态解析或由原生实现承载的 `headers`、`proxy`、`hosts`、`ads`、`doh`、`wallpaper`、`parses`、`lives`、`rules` 等字段。

## 2. Swift 端当前已有能力

Swift 端已经不是空壳，当前基础能力包括：

- 配置加载：支持输入点播/直播配置地址、GitHub raw/blob 规范化、多仓库入口解析、配置短时缓存，见 `tvbox/Services/ApiConfig.swift`。
- 源类型：显式支持 `type=0` XML、`type=1` JSON、`type=4` Remote，过滤 `type=3`，见 `tvbox/Models/SourceBean.swift` 与 `tvbox/Services/SourceService.swift`。
- 点播：有首页分类、分页列表、详情、线路/剧集、HLS master 清晰度解析、播放历史续播和收藏，见 `HomeViewModel.swift`、`DetailViewModel.swift`、`CacheStore.swift`。
- 搜索：支持多源并发搜索、搜索历史，见 `SearchViewModel.swift`。
- 直播：能解析 m3u/txt 和内嵌频道，支持分组、频道、多线路、请求头、XMLTV EPG、回看、频道收藏、最近频道恢复与 AVPlayer/VLC 播放，见 `LiveModels.swift`、`XMLTVService.swift`、`LiveViewModel.swift`、`LiveView.swift`。
- 播放器：提供系统 AVPlayer 和 VLC 两种内核，VLC 有缓存策略、软硬解设置、播放速度、音量和直播失败回调，见 `PlayerEngine.swift` 与 `VLCPlayerView.swift`。
- 持久化：用 SwiftData 存收藏、播放历史和通用缓存，见 `CacheStore.swift`。
- 平台：已有 iOS 与 macOS target，未见 tvOS target，见 `project.yml`。

## 3. 大功能差异总览

| 功能域 | Swift 当前状态 | Android 成熟能力 | 主要缺口 | 建议优先级 |
| --- | --- | --- | --- | --- |
| 配置与源管理 | 基础可用 | 多配置历史、本地导入、DoH、壁纸、配置备份恢复、源主页切换 | 本地文件导入、配置历史 UI、备份恢复、DoH/hosts/proxy/rules 应用、壁纸应用 | 高 |
| 点播数据与筛选 | 基础可用 | 分类筛选、站点 action、热门词、源级搜索策略、复杂结果字段 | 筛选 UI、`parses` 实际播放链、`playUrl/playerType/timeout` 等字段落地、搜索热词 | 高 |
| 播放解析与协议提取 | 明显缺失 | WebView 嗅探、解析接口、`.strm`、push/video、Thunder、TVBus、YouTube 提取 | ParseManager、Web 嗅探、特殊协议 extractor、播放请求头/DRM/字幕弹幕模型 | 高 |
| 播放器高级控制 | 部分可用 | ExoPlayer/Media3 服务、音轨/字幕轨、外挂字幕、DRM、片头片尾、外部播放器、媒体会话 | 轨道选择、外挂字幕、DRM/ClearKey、请求头传递、片头片尾跳过、系统媒体控制 | 高 |
| 弹幕与字幕体验 | 基础不足 | 弹幕加载/选择/渲染、字幕大小/位置、SRT/SSA/ASS/VTT 文件选择 | Danmaku 层、外挂字幕解析、字幕样式与位置控制 | 中高 |
| 直播高级能力 | 基础可用，EPG/回看/收藏已接入 | EPG/XMLTV、回看 catchup、直播头/UA/DRM、频道收藏、密码分组、直播源历史 | DRM/ClearKey、隐藏/密码分组、直播源历史和主页直播源管理、更多播放控制 | 高 |
| 局域网服务与远程控制 | 缺失 | 内置 NanoHTTPD，支持推送、搜索、设置、遥控、媒体状态、上传/下载、同步 | 本地 HTTP server、Web 控制台、局域网文件管理、远程推送/遥控 | 高 |
| DLNA 投屏/接收 | 缺失 | 移动端投屏发送，TV 端 DLNA Renderer 接收 | DLNA/UPnP 发现、投屏发送、接收端 Renderer、AVTransport 控制 | 中高 |
| 数据同步与备份 | 基础历史/收藏 | Room 多实体、配置/历史/收藏/轨道/设备，自动备份、设备同步 | 备份包、恢复、设备发现同步、轨道/设置/直播收藏持久化 | 高 |
| 本地文件与系统入口 | 基础不足 | ACTION_SEND/ACTION_VIEW、m3u 打开、本地文件选择、局域网上传、APK/字幕处理 | iOS document picker、m3u/file 配置导入、URL scheme/share extension、字幕文件入口 | 中 |
| TV/遥控体验 | iOS/macOS 基础 | Leanback 焦点、遥控键、软键盘、语音搜索、直播快捷方式、开机直播 | tvOS target、焦点系统、遥控按键、语音搜索、App Shortcuts | 中 |

## 4. 分功能域详情

### 4.1 配置与源管理

Android 端能力：

- `VodConfig`、`LiveConfig`、`WallConfig` 分别管理点播、直播、壁纸配置，并会解析 `headers`、`proxy`、`rules`、`doh`、`hosts`、`ads`、`wallpaper`、`lives`、`sites`、`parses`。
- `BaseConfig` 支持远程配置中的数组字段继续引用外部 URL。
- `Config` 和配置 DAO 支持多份配置记录、历史记录、主页源选择。
- 设置页支持点播/直播/壁纸配置的选择、编辑、历史、从本地文件导入、DoH 选择、缓存清理、备份与恢复。
- `AppDatabase.backup()` 会生成 gzip 备份并保留最近 7 份，`restore()` 能全量恢复配置、收藏、历史等。

Swift 端状态：

- `ApiConfig` 能解析远程配置、多仓库入口、站点列表、解析器列表、DoH 列表、壁纸字段和直播列表。
- `SettingsView` 能编辑点播/直播 URL、选择主页源、调整播放器设置、清缓存。

主要缺口：

- 配置只保存当前 URL 和 API 历史，没有 Android 那种点播/直播/壁纸多配置管理、配置历史弹窗、长按编辑和本地文件导入。
- `dohList`、`wallpaper` 已解析但未落地到网络层和 UI 壁纸系统；`hosts`、`proxy`、`headers`、`ads`、`rules` 基本未应用。
- 缺少自动备份/恢复、备份版本浏览、备份压缩和保留策略。
- 缺少配置驱动的壁纸下载、图片/GIF/视频壁纸识别和应用。

建议拆分：

1. 先做 `ConfigStore`：保存点播/直播/壁纸配置历史、主页选择、配置描述和最后更新时间。
2. 再做 `BackupManager`：导出 SwiftData、UserDefaults 和配置历史为 gzip JSON，支持恢复前预览。
3. 最后做 `NetworkPolicy`：把 DoH、hosts、proxy、headers、ads/rules 逐步接入 `NetworkManager` 与播放器请求。

### 4.2 点播数据、分类筛选与搜索

Android 端能力：

- `SiteApi` 覆盖首页、分类、详情、播放、搜索、action。
- `Class`、`Filter`、`Value` 支持分类筛选条件，移动端有 `FilterDialog`，TV 端有对应 presenter。
- `Site` 存储 `playUrl`、`timeout`、`playerType`、`searchable`、`filterable`、`quickSearch` 等源级策略。
- 搜索页有热门词缓存、搜索历史、多源并发搜索、源开关。
- 详情页正文中的可点击链接可继续展开为文件夹/合集。

Swift 端状态：

- `SourceService` 能请求分类、列表、详情和搜索。
- `MovieSort.SortData` 已预留 `filters`，但 UI 和服务层解析还不完整。
- `SearchViewModel` 支持多源并发搜索和历史。

主要缺口：

- 筛选条件没有完整从配置/接口解析到 UI，也没有在首页分类页形成 Android 的筛选弹窗体验。
- `ParseBean` 只被解析和统计，没有参与播放解析链。
- 源的 `playUrl`、`timeout`、`playerType`、`categories`、`click` 等字段尚未系统落地。
- 搜索缺少热门词、按源开关搜索、快速搜索策略和 Android 的源级搜索开关状态持久化。
- XML 解析仍是轻量正则路径，够用但不等价于 Android 的结构化解析能力。

建议拆分：

1. 先打通 `filters` 模型、解析和首页筛选 UI。
2. 给 `SourceService` 增加源级策略对象，统一处理 `timeout`、`quickSearch`、`playUrl`、`playerType`。
3. 增加 `HotWordService` 与搜索源开关，复刻 Android 的热门词和搜索记录体验。

### 4.3 播放解析与特殊协议提取

Android 端能力：

- `Parse` 模型支持解析接口、`cat_ext`、默认解析和用户选择。
- `CustomWebView` 能打开解析页、执行 click/script、拦截请求并嗅探真实视频地址。
- 本地 `/parse` 页面可辅助解析接口播放。
- `Source` 聚合了多个不依赖 type=3 的原生 extractor：`.strm`、`push://`、`video://`、magnet/ed2k/torrent、TVBus、YouTube、Force/JianPian 等。
- 播放前会通过 `PlayerManager` 和 `Source.fetch()` 将特殊 URL 转成真实可播地址。

Swift 端状态：

- 当前详情页拿到播放 URL 后基本直接交给 AVPlayer/VLC。
- 对 HLS master 做了清晰度解析，但没有通用播放解析链。

主要缺口：

- 缺少 `ParseManager`：无法使用配置中的 `parses`、无法切换解析接口、无法处理 `cat_ext`。
- 缺少 WebView 嗅探：很多 `parse=1` 或需要页面拦截的非 type=3 源仍不可用。
- 缺少特殊协议提取：`.strm`、`push://`、`video://`、magnet/ed2k/torrent、TVBus、YouTube 播放列表/视频提取都没有对应 Swift 实现。
- 播放 URL 没有携带统一的 headers、format、DRM、subtitle、danmaku 元数据对象。

建议拆分：

1. 设计 `PlayableItem`，包含 `url`、`headers`、`mimeType`、`drm`、`subtitles`、`danmakus`、`startPosition`。
2. 实现 `ExtractorRegistry`，先做低成本项：`.strm`、`push://`、`video://`、YouTube URL 外部降级。
3. 实现 `ParseManager` 与 WebKit 嗅探，覆盖普通解析接口和可拦截媒体 URL 的场景。
4. magnet/ed2k/torrent、TVBus 依赖较重，建议作为独立里程碑评估原生库、App Store 风险和平台限制。

### 4.4 播放器高级控制与播放偏好

Android 端能力：

- `PlaybackService` 基于 Media3 `MediaLibraryService`，有媒体通知、外部媒体客户端、播放控制、前后台生命周期。
- `PlayerManager` 支持解析、重试、软硬解切换、弹幕、字幕、音轨、速度、比例、片头片尾、循环、下一集。
- `TrackDialog` 能列出音频/视频/字幕轨，并支持选择外挂字幕文件。
- `Track` 表会按播放 key 记住轨道偏好。
- `History` 记录播放线路、剧集、倒序、片头、片尾、进度、时长、速度、画面比例等。
- `ExoUtil` 支持字幕配置、DRM/ClearKey、请求 headers、AAC 偏好、隧道模式、buffer 倍率。
- 播放页支持外部播放器打开、锁定方向、旋转、画面比例、速度快捷切换、片头片尾跳过。

Swift 端状态：

- 已有 AVPlayer/VLC 内核选择、VLC 缓冲策略、软硬解设置、速度/音量、全屏、自动下一集、播放进度保存。
- `VodPlaybackState` 目前只保存线路、剧集索引和进度。

主要缺口：

- 播放器只接收 URL 字符串，未建立类似 Android `PlaySpec` 的播放请求对象，headers、DRM、字幕、弹幕、format 不能完整传递。
- 没有音轨/视频轨/字幕轨选择 UI，也没有轨道偏好持久化。
- 外挂字幕选择、SRT/SSA/ASS/VTT 多格式处理、字幕大小/位置设置不足。
- 缺少片头片尾跳过、播放比例按影片记忆、速度按影片记忆、倒序播放等历史偏好。
- 没有 Android MediaLibraryService 对应的系统媒体会话、远程媒体状态查询、通知控制完整链路。
- 外部播放器打开、方向锁定/旋转、类似 Android 手势控制体系还未完整覆盖。

建议拆分：

1. 先把 `PlayerView` 入参从 `urlString` 升级为 `PlayableItem`。
2. 扩展 `VodPlaybackState`，记录速度、比例、清晰度、字幕、音轨、片头片尾。
3. 给 VLC/AVPlayer 分别实现 headers、字幕、DRM 的能力矩阵，不支持项需要 UI 明确降级。
4. 增加轨道/字幕/播放偏好弹窗。

### 4.5 弹幕与字幕

Android 端能力：

- `DanmakuDialog` 可选择配置内弹幕或本地弹幕文件。
- `DanPlayer`、`Loader`、`Parser` 负责弹幕加载、解析和渲染。
- `PlaySpec` 和 `Result` 能携带 `danmaku` 与 `subs`。
- `SubtitleDialog` 支持字幕大小/位置重置，`TrackDialog` 支持手动选择字幕文件。

Swift 端状态：

- 未见弹幕模型、加载器或渲染层。
- AVPlayer/VLC 可以播放部分内嵌字幕，但没有统一字幕管理 UI。

主要缺口：

- 配置中的弹幕字段未解析/未显示。
- 缺少 XML/JSON 弹幕解析、时间轴同步、透明 overlay 渲染、开关和样式设置。
- 缺少本地字幕/弹幕文件选择、编码转换、字幕样式控制。

建议拆分：

1. 字幕优先：`SubtitleManager` 支持本地/远程字幕文件，至少覆盖 SRT、VTT。
2. 弹幕后置：`DanmakuManager` 加载配置与本地文件，`DanmakuOverlayView` 做 SwiftUI overlay。
3. ASS/SSA 样式复杂，可考虑 libass 或先转纯文本字幕降级。

### 4.6 直播高级能力

Android 端能力：

- `LiveParser` 完整解析 m3u/txt/json：`tvg-url`、`url-tvg`、`tvg-id`、`tvg-logo`、`tvg-name`、`tvg-chno`、`group-title`、`catchup`、`catchup-source`、`catchup-replace`、`http-user-agent`、`header`、`format`、`origin`、`referer`、DRM/ClearKey 等。
- `LiveApi` 会解析 XMLTV EPG，按昨天/今天/明天拉取节目单，并在回看时按 `Catchup` 格式生成播放 URL。
- `LiveActivity` 有 EPG 列表、频道分组宽度自适应、隐藏分组、频道收藏、直播源切换、线路切换、缩放/速度/音轨/字幕/解码/外部播放器。
- `LiveConfig` 管理直播配置历史、主页直播源和收藏频道合并。

Swift 端状态：

- `ApiConfig.parseLiveContent` 支持 m3u/txt 和内嵌 channels，并已解析 `tvg-url`、`tvg-id`、`tvg-logo`、频道号、UA/header、format、catchup 等常用直播扩展属性。
- `XMLTVService` 支持 JSON EPG、XMLTV、gzip XMLTV、六小时缓存和昨天/今天/明天日期窗口。
- `LiveViewModel` 有分组、频道、多线路、EPG 日期切换、回看播放、频道收藏、隐藏分组过滤和最近频道恢复。
- `LiveView` 有频道抽屉、当前频道信息、节目单列表、回看入口、VLC/AVPlayer 播放和部分失败切线逻辑。

主要缺口：

- 直播 DRM/ClearKey 字段仍未进入播放器能力矩阵。
- 隐藏/密码分组已能解析并默认隐藏，但还没有解锁 UI；直播源历史和直播主页切换体验不足。
- 直播音轨/字幕轨/解码/比例等高级控制没有完整对齐 Android。

建议拆分：

1. 为直播补 DRM/ClearKey 模型和播放器降级提示。
2. 实现隐藏/密码分组解锁 UI、直播源历史和主页直播源管理。
3. 把直播播放也切到 `PlayableItem`，与点播共享 headers/DRM/字幕/format 处理。
4. 补直播音轨/字幕轨/解码/比例等 Android 高级播放控制。

### 4.7 局域网服务、Web 控制台与设备同步

Android 端能力：

- `Server` 启动本地 NanoHTTPD，端口在 9978 到 9998 之间探测。
- `Nano` 挂载静态 Web 资源，并开放 `/action`、`/media`、`/file`、`/upload`、`/newFolder`、`/delFile`、`/cache`、`/proxy`、`/parse`、`/device` 等端点。
- `/action` 支持 push、search、setting、refresh、control、cast、sync。
- `/media` 输出当前播放状态、速度、时长、进度、URL、标题、封面。
- `/file` 和 `/upload` 支持局域网文件浏览、上传、Range 下载、zip 解压。
- `SyncDialog` 通过设备扫描和 `/action?do=sync` 同步历史与收藏，支持覆盖/双向/发送模式。

Swift 端状态：

- 未见本地 HTTP server、局域网设备发现、Web 控制台或设备同步实现。

主要缺口：

- 无法从局域网浏览器推送播放地址、配置地址、字幕/弹幕文件。
- 无法作为 Web 控制台暴露播放状态和遥控命令。
- 无历史/收藏跨设备同步。
- 无局域网文件上传管理。

建议拆分：

1. macOS 优先实现 `LocalControlServer`，iOS 根据后台限制做前台启用。
2. 第一版只做 `/device`、`/media`、`/action?do=push/control/search`。
3. 第二版做 `/upload`、字幕/弹幕刷新、历史/收藏同步。
4. Web 控制台可复用 Android 静态资源思路，但要重写 Swift 端协议适配层。

### 4.8 DLNA 投屏与接收

Android 端能力：

- mobile source set：`DLNACastManager` 发现局域网 MediaRenderer，`CastDialog` 发送投屏并控制播放。
- leanback source set：`DLNARendererService` 注册本机为 MediaRenderer，`DLNAAvTransportImpl` 处理播放、暂停、停止、seek、下一首等 AVTransport 指令。
- `CastActivity` 用 Android 播放器承接投屏内容。

Swift 端状态：

- 未见 DLNA/UPnP 相关模块。

主要缺口：

- 没有发现 DLNA 设备。
- 没有投屏发送端。
- 没有作为接收端注册 MediaRenderer。
- 没有 AVTransport/RenderingControl 状态同步。

建议拆分：

1. macOS/tvOS 优先于 iOS：平台限制更少，更适合作为接收端。
2. 先做投屏发送端，发现设备后把当前 `PlayableItem` 投给外部 Renderer。
3. 再做接收端 Renderer，复用本地播放页和 `PlayableItem`。
4. 需要提前评估 Swift UPnP 库质量、沙盒网络权限和 App Store 合规。

### 4.9 数据持久化、历史收藏与同步对象

Android 端能力：

- Room 数据库实体包括 `Keep`、`Site`、`Live`、`Track`、`Config`、`Device`、`History`，版本号已到 35。
- `History` 保存播放线路、剧集、进度、时长、速度、比例、片头片尾、倒序等。
- `Keep` 同时覆盖点播收藏和直播收藏，并支持设备同步。
- `Track` 按播放 key 保存轨道偏好。
- `Device` 支持局域网设备发现和同步。

Swift 端状态：

- `VodCollect`、`VodRecord`、`CacheItem` 已有。
- `VodPlaybackState` 保存线路、剧集索引和进度。

主要缺口：

- 持久化对象少于 Android：缺少配置实体、直播实体、轨道实体、设备实体、备份实体。
- 历史信息不够完整，缺少速度、比例、片头片尾、倒序、清晰度、字幕/音轨偏好。
- 收藏只覆盖点播，直播频道收藏未落地。
- 缺少跨设备同步协议和冲突合并策略。

建议拆分：

1. 扩展 `VodPlaybackState`，并提供旧数据迁移兼容。
2. 新增 `ConfigRecord`、`LiveCollect`、`TrackPreference`、`KnownDevice`。
3. 备份/同步都基于这些模型序列化，不直接绑定 SwiftData 内部格式。

### 4.10 本地文件、系统入口与平台体验

Android 端能力：

- `HomeActivity` 处理系统 `ACTION_SEND`、`ACTION_VIEW`、`ACTION_SEARCH`：分享 URL、打开本地 m3u、打开本地媒体、系统搜索。
- `FileActivity` 提供应用内文件选择器。
- `Local` server 支持局域网文件浏览、上传、删除、Range 下载。
- mobile 有 PiP 与后台策略；leanback 有遥控键、焦点、软键盘、语音输入、直播快捷方式、开机直播。
- `project` 分为 mobile/leanback 两套 UI，TV 体验不是简单拉伸手机 UI。

Swift 端状态：

- iOS/macOS target 已有，macOS 做了窗口全屏适配。
- 未见 tvOS target、document picker、share extension、URL scheme、AppIntent、Now Playing、PiP 或本地 HTTP 文件管理。

主要缺口：

- 缺少系统分享入口和 URL scheme，不能像 Android 一样从其它 App 直接推送 URL 或配置。
- 缺少本地 m3u/配置/字幕/弹幕文件选择导入。
- 缺少 tvOS target、遥控焦点体系、遥控快捷键和电视端软键盘。
- 缺少语音搜索和系统快捷方式。

建议拆分：

1. iOS 先做 document picker 与 share extension。
2. macOS 做菜单栏/文件打开入口。
3. tvOS 单独建 target，优先处理焦点、遥控器、全屏播放和直播频道切换。
4. AppIntents 和语音搜索可作为平台增强项。

## 5. 建议实施路线

### Phase 1：补齐基础互通能力

目标：让更多非 type=3 配置在 Swift 端可用。

- 建立 `PlayableItem`，让播放器支持 headers、format、DRM、字幕、弹幕元数据。
- 实现 `ParseManager`，接入配置中的 `parses`，支持普通解析接口和 cat_ext。
- 完成分类筛选 UI 与 `filters` 参数传递。
- 实现配置历史、本地文件导入、备份/恢复。
- 扩展直播 m3u 属性解析，至少覆盖 UA/header/logo/tvg-id/tvg-url。

### Phase 2：补齐播放体验

目标：把 Android 用户最常用的播放控制迁过来。

- 轨道选择、外挂字幕、字幕样式控制。
- 播放偏好记忆：速度、比例、清晰度、片头片尾、倒序。
- EPG/XMLTV 与直播频道收藏。
- 弹幕加载与 overlay 渲染。
- 外部播放器、系统媒体控制、Now Playing/Remote Command。

### Phase 3：补齐生态能力

目标：实现 Android 端成熟的局域网与电视端生态。

- 本地 HTTP server：推送、遥控、媒体状态、文件上传、历史/收藏同步。
- DLNA 投屏发送与 macOS/tvOS 接收端。
- tvOS target：焦点、遥控器、直播快捷操作。
- 特殊 extractor：`.strm`、`push://`、`video://`、YouTube，重型协议如 torrent/TVBus 单独评估。

## 6. 优先级建议

| 优先级 | 功能 | 原因 |
| --- | --- | --- |
| P0 | `PlayableItem` + headers/format/DRM/subtitle 基础模型 | 这是播放解析、直播扩展、字幕轨和特殊协议的共同底座 |
| P0 | `ParseManager` 接入 `parses` | 很多非 type=3 源仍依赖解析接口或 Web 嗅探 |
| P0 | 配置历史、本地导入、备份恢复 | 用户迁移和排障最需要，且不依赖复杂播放器能力 |
| P1 | 分类筛选与源级策略 | 直接影响点播可用性和找片效率 |
| P1 | EPG/XMLTV 与直播扩展属性 | 直播端从“能播”变成“好用”的关键 |
| P1 | 轨道/外挂字幕/播放偏好 | 直接提升播放体验，范围可控 |
| P2 | 本地 HTTP server 与设备同步 | Android 特色能力，工作量中等偏大 |
| P2 | DLNA 投屏 | 价值高，但协议和平台限制较多 |
| P2 | 弹幕系统 | 体验增强明显，但渲染与格式兼容成本较高 |
| P3 | tvOS target、语音搜索、App Shortcuts | 平台增强，适合在核心播放链稳定后推进 |

## 7. 关键证据索引

Android 端：

- 配置加载：`../../TV/app/src/main/java/com/fongmi/android/tv/api/config/VodConfig.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/api/config/LiveConfig.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/api/config/WallConfig.java`
- 设置页：`../../TV/app/src/mobile/java/com/fongmi/android/tv/ui/fragment/SettingFragment.java`、`../../TV/app/src/mobile/java/com/fongmi/android/tv/ui/fragment/SettingPlayerFragment.java`
- 数据库/备份：`../../TV/app/src/main/java/com/fongmi/android/tv/db/AppDatabase.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/bean/History.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/bean/Keep.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/bean/Track.java`
- 播放服务：`../../TV/app/src/main/java/com/fongmi/android/tv/service/PlaybackService.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/PlayerManager.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/engine/PlaySpec.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/exo/ExoUtil.java`
- 播放页：`../../TV/app/src/mobile/java/com/fongmi/android/tv/ui/activity/VideoActivity.java`、`../../TV/app/src/mobile/java/com/fongmi/android/tv/ui/activity/LiveActivity.java`
- 轨道/字幕/弹幕：`../../TV/app/src/main/java/com/fongmi/android/tv/ui/dialog/TrackDialog.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/ui/dialog/SubtitleDialog.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/ui/dialog/DanmakuDialog.java`
- 直播解析：`../../TV/app/src/main/java/com/fongmi/android/tv/api/LiveApi.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/api/parser/LiveParser.java`
- 本地服务：`../../TV/app/src/main/java/com/fongmi/android/tv/server/Server.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/server/Nano.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/server/process/Action.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/server/process/Media.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/server/process/Local.java`
- DLNA：`../../TV/app/src/mobile/java/com/fongmi/android/tv/dlna/DLNACastManager.java`、`../../TV/app/src/leanback/java/com/fongmi/android/tv/service/DLNARendererService.java`
- 特殊协议：`../../TV/app/src/main/java/com/fongmi/android/tv/player/Source.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/extractor/Strm.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/extractor/Thunder.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/extractor/TVBus.java`、`../../TV/app/src/main/java/com/fongmi/android/tv/player/extractor/Youtube.java`

Swift 端：

- 配置：`../tvbox/Services/ApiConfig.swift`、`../tvbox/Models/AppConfig.swift`、`../tvbox/Models/SourceBean.swift`
- 数据服务：`../tvbox/Services/SourceService.swift`、`../tvbox/Services/NetworkManager.swift`
- 播放器：`../tvbox/Models/PlayerEngine.swift`、`../tvbox/Views/Player/PlayerView.swift`、`../tvbox/Views/Player/VLCPlayerView.swift`
- 详情/首页/搜索/直播：`../tvbox/ViewModels/HomeViewModel.swift`、`../tvbox/ViewModels/DetailViewModel.swift`、`../tvbox/ViewModels/SearchViewModel.swift`、`../tvbox/ViewModels/LiveViewModel.swift`、`../tvbox/Views/Live/LiveView.swift`
- 持久化：`../tvbox/Persistence/CacheStore.swift`
- 平台 target：`../project.yml`
