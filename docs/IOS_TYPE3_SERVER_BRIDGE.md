# iOS 支持 type=3 Spider/Jar/Py/JS 动态源的服务端桥接开发文档

生成日期：2026-04-30

## 1. 背景与目标

Swift 端当前主动排除了 `type=3` Spider/Jar/Py/JS 源，以及 Android DEX Jar、chaquopy、QuickJS、动态脚本运行时和桥接 API。这个限制符合 iOS/macOS 客户端现实：iOS 不适合在 App 内加载第三方 Android Jar，也不应在 App 内运行配置下发的 Java/Python/QuickJS 动态代码。

本方案的目标不是把这些运行时塞进 iOS，而是在仓库最外层新增一个服务端程序，由服务端运行 Android 生态里的动态源能力，再把 iOS 能消费的标准 HTTP 结果返回给客户端：

- 能解析成直连媒体地址时，服务端返回直连 URL、headers、format、字幕等元数据，iOS 直接播放。
- 不能直连或需要特殊 Cookie、签名、Range、反盗链、二次请求时，服务端返回代理播放 URL，由服务端转发流量。
- iOS 第一阶段尽量少改，只增加 Bridge 配置、保留 `type=3` 源入口、调用服务端统一 API、播放服务端给出的 URL。
- Android DEX Jar、chaquopy Python、QuickJS、动态脚本与桥接 API 都在服务端隔离执行，iOS 不直接接触动态代码。

## 2. 总体原则

- 服务端补齐能力，客户端只做展示、调用和播放。
- API 尽量复用 TVBox/FongMi 语义：home、category、detail、play、search、action。
- iOS 不解析 Jar、不执行 Python、不执行 QuickJS、不下载动态脚本运行。
- 服务端返回结果必须是稳定 JSON，不把内部运行时异常、堆栈、宿主路径暴露给客户端。
- 播放地址优先直连，必要时代理；代理必须支持 Range、headers 透传、重定向、分片流和超时控制。
- 服务端按源、用户、任务做隔离和限流，避免某个 Spider 阻塞全局服务。

## 3. 后端技术选型

推荐第一版使用 **Android Runtime + 现有 NanoHTTPD 服务框架** 落地，而不是裸 JVM 服务器。运行位置可以是 Android 真机/盒子，也可以是 Linux/KVM 上的无头 Android Docker/Emulator；如果目标是长期常驻服务，优先把 Docker Android 作为稳定部署目标来设计。

选择原因（必须正视的事实）：

- TVBox/FongMi 生态里的 `csp_*` Jar 在本仓库中按 **Android DEX 字节码**处理：`TV/app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java` 用 `dalvik.system.DexClassLoader` 加载，而不是普通 `URLClassLoader`。常见公开 spider jar 以 Android 运行时为目标，标准 OpenJDK 不能直接 `loadClass` 这种 DEX jar。
- Spider 基类 `com.github.catvod.crawler.Spider` 直接 `import android.content.Context`，`init(Context, String ext)` 需要 Android `Context`，许多 Spider 内部还会调用 `App.get()`、`SharedPreferences`、`AssetManager`、`Path.cache()` 等 Android API。
- FongMi 的 QuickJS Spider（`TV/quickjs/.../Spider.java`）也持有 `DexClassLoader`，注入了 dex 形式的 JS 桥接助手；FongMi 的 Python 集成基于 **Chaquopy**，脚本里普遍出现 `from com.github.catvod import Proxy` 这类跨语言调用，依赖 chaquopy 的 Java↔Python 桥。

Python 路线需要单独澄清：`.py` 源不是通过 `jar` 字段加载，也不是 Jar Spider 的补充包，而是 `type=3` 下与 Jar/DEX、QuickJS 并列的第三种运行时。源码里 `BaseLoader.getSpider(key, api, ext, jar)` 先判断 `api.contains(".py")`，命中后直接调用 `PyLoader.getSpider(key, api, ext)`，`jar` 参数不会传入 Python 分支。`PyLoader` 再通过 `com.fongmi.chaquo.Loader` 启动 Chaquopy，`chaquo/src/main/python/app.py` 下载或写入 `api` 指向的 `.py` 脚本，并用 `SourceFileLoader(...).load_module().Spider()` 创建 Python Spider。Python 的依赖脚本通过 `getDependence()` 返回 `.py` 名称，再按当前 `api` 相对路径下载；这仍然是 Python 脚本依赖，不是 jar 依赖。相反，QuickJS 分支会接收 `jar`，并用 `BaseLoader.get().dex(jar)` 给 JS Spider 提供可选 dex helper，例如尝试加载 `com.github.catvod.js.Function`。

联网核查 CatVod 相关仓库后的结论：**不能把“jar 生态整体开源、可直接标准 OpenJDK 化”当作前提**。

- FongMi/TV 本仓库是 GPL-3.0，宿主接口和加载逻辑可查；CatVodTVOfficial 的 `TVBoxOSC` 元数据显示 AGPL-3.0。
- CatVodTVOfficial/CatVodTVJarLoader 是 public Java 仓库，但 GitHub API 元数据 `license = null`；CatVodTVOfficial/CatVodTVSpider 也是 public Java 仓库、已 archived，元数据同样 `license = null`。公开可见不等于有明确开源许可证，也不等于可以放心改造、再分发或作为产品依赖。
- 更关键的是，用户配置里的 `jar` 往往指向第三方编译产物。即使 CatVod 的接口工程可见，也不能推出“每个外部 spider jar 都有源码和许可证”。
- 即便某个 spider 有源码，OpenJDK 也不是直接换运行时：现有接口依赖 Android `Context`，运行产物常是 DEX，QuickJS/Python 还依赖 Android 侧 dex 助手与 chaquopy Java 桥。迁到 OpenJDK 需要逐源改源码、重建 JVM jar、替换 Android API/Path/Proxy/Asset/SharedPreferences 等宿主能力。

因此 OpenJDK 路线只能定义为“**受控白名单/纯 JVM Spider 子集**”：仅对源码可获得、许可证明确、且能移除 Android 依赖的少量源单独适配。它不是第一版的兼容性路线，也不能承诺覆盖现有 type=3 生态。

### 3.1 主流配置样本静态分析

为避免只基于理论判断，已对 4 个常见配置入口做过一次工具化静态分析：`http://www.饭太硬.com/tv`、`http://mitvbox.xyz/%E5%B0%8F%E7%B1%B3/DEMO.json`、`http://tvbox.xn--4kq62z5rby2qupq9ub.top/`、`https://gh-proxy.net/https://raw.githubusercontent.com/yoursmile66/TVBox/refs/heads/main/XC.json`。分析只下载配置和 jar/zip/txt/jpg 产物，不执行任何动态代码。

配置解析需要复现 FongMi 的 `Decoder` 行为，而不是普通 JSON 解析：饭太硬入口在 `okhttp` 风格请求下返回带 `**` marker 的伪装内容，需要取 marker 后 base64 解码；小米入口是 `2423...` AES/CBC/PKCS5Padding 格式；王二小入口在 `okhttp` 风格 HTTP 请求下跳转到网易 NOS 的 `.txt` 配置；南风给出的 `gh-proxy.net` 地址在本次网络环境下跳到 HTML 页面，因此静态分析使用其等价的 GitHub raw 地址读取当前 `XC.json` 内容。Yoursmile 配置文件开头有 `//` 注释，分析时按配置文本清洗后解析 JSON。

| 配置源 | 解析结果 | 主 jar 字段 | 站点级额外 jar | 关键静态结构 |
| --- | --- | --- | --- | --- |
| 饭太硬 | 51 个 `type=3` 站点，顶层 `spider` fallback | `.jpg;md5;bb41630d...`，下载 md5 匹配 | 无 | 实际是 ZIP 容器：`classes.dex` + `assets/ftyguard_v7.so` + `assets/ftyguard_v8.so` + guard 资源；无 `.class` |
| 小米 | 34 个 `type=3` 站点，顶层 `spider` fallback | `.zip;md5;4f72b8...`，下载 md5 匹配 | `追剧达人` 单站覆盖 `.jar;md5;a4f403...`，下载 md5 匹配 | 主包是 `classes.dex`，无 `.class`；DEX 中有大量 `android.*`、`okhttp3`、`org.json`、`com.github.catvod.*` 引用和 parser 类 |
| 王二小 | 78 个 `type=3` 站点，顶层 `spider` fallback | `.txt;md5;69aaa8...`，下载 md5 匹配 | 无 | 实际是 ZIP 容器：`classes.dex` + `assets/wexguard_v7.so` + `assets/wexguard_v8.so` + guard 资源；无 `.class` |
| 南风 / Yoursmile | 82 个 `type=3` 站点，顶层 `spider` fallback | `Yoursmile.jar;md5;c6aaf6...`，本次下载 md5 为 `73ba90...`，与配置声明不一致 | `弹幕` 单站覆盖 `custom_spider.jar` | 主包是 `classes.dex` + `assets/libs/arm64-v8a/libstub.so` + `assets/libs/armeabi-v7a/libstub.so`；站点包也带 ARM/ARM64 `.so`；无 `.class` |

这 4 个样本给出的结论非常一致：主流配置里的“jar”并不是标准 OpenJDK jar，而是可被 Android `DexClassLoader` 打开的 ZIP/DEX 容器，扩展名可以伪装成 `.jpg`、`.txt`、`.zip` 或 `.jar`。样本中所有主包都只有 `classes.dex`，没有 JVM `.class`；多数还带 ARM/ARM64 原生库和 guard/stub 资源。DEX 字符串表里可以看到 `android.app.Application`、`android.content.Context`、`android.os.*`、`android.net.*`、`androidx.*`、`com.github.catvod.spider.Init`、`Proxy`、`Path`、`com.github.catvod.parser.*`、QuickJS helper 等引用。

所以，“重写一个尽量通用的 OpenJDK jar 包”不能理解为写一个 JVM jar 来直接加载这些现成产物。标准 OpenJDK 不认识 DEX，也没有 Android `Context` / `Application` / `Looper` / `SharedPreferences` / `AssetManager` / `android.util.Base64` 等运行时；更不能运行样本里的 ARM `.so` 保护/桥接库。即便使用 dex2jar 或 Android API stub，仍会遇到混淆、native guard、宿主 API、`Spider.proxy` 本地代理、QuickJS dex helper、配置级 parser 等兼容点。

可行的 OpenJDK 工作应拆成两类：

- 可以做：配置下载/解码、JSON 解析、CatVod Spider 接口的纯 JVM 定义、HTTP/代理/缓存/结果 DTO、以及少量源码明确且不依赖 Android/native 的自有 Spider。这个可以成为“纯 JVM 白名单运行时”。
- 不应承诺：对任意主流配置 jar 的通用 OpenJDK 兼容加载。以上 4 个样本已经足以证明，第一版若追求现有生态兼容，应继续选择 Android Runtime + Bridge Server，而不是裸 OpenJDK。

因此可行的部署形态按推荐度排序：

1. **Linux/KVM 无头 Android Docker/Emulator 常驻服务**（服务端首选）：在容器里启动 Android Emulator，安装 Bridge APK，Bridge APK 复用 `JarLoader` / `BaseLoader` / `Spider` / quickjs / chaquo 模块，并通过 NanoHTTPD 暴露 HTTP API。官方 Android Emulator 支持 `-no-window`，Linux 上通过 KVM 跑 x86/x86_64 系统镜像才有可接受性能。容器要做 AVD 数据持久化、开机自启、健康检查和失败自动重启。
2. **Android 设备 / 盒子上的常驻服务**（兼容性最高、运维较弱）：直接复用现有 Android Runtime，最接近 FongMi 运行环境。适合开发、家庭试用和兜底，但手机/盒子保活、网络、电源、系统清理都比服务器容器更不可控。
3. **裸 JVM（OpenJDK）+ Android 运行时垫片**：理论上可探索 Robolectric / 自实现 `android.jar` 桩 + dex2jar 转换 + 自实现 `Context`，但每个 spider 都要逐源验证，公开 jar 命中率不可保证，仅适合特别选型过的少量源。
4. **裸 JVM + 仅支持新写的“纯 JVM Spider”**：要求 spider 作者交付 JVM `.class` jar，并不依赖 Android API。这个路线会放弃大量现成 Android spider 生态，仅适合自有源。

第一版结论：直接走 Android Runtime 路线，把 Bridge Server 做成 Android APK/服务，iOS 端通过 HTTP 调用。开发期跑真机/盒子即可；长期常驻优先跑 Linux/KVM 无头 Android Emulator/Docker。这样可以复用 `JarLoader`、`BaseLoader`、`SiteApi`、`ParseJob`、QuickJS、chaquo Python；如未来支持纯 OpenJDK，应按方案 3/4 单独立项并建立源白名单。

### 3.2 x86 / x86_64 APK 打包判断

源码和依赖静态检查及本次落地后的判断：**完整 Android App 可以新增 x86_64 flavor 作为无头 Bridge Server APK，但必须在 x86_64 上隔离 ARM-only 原生解析器；不要承诺完整 Android 播放端能力在 x86_64 上等价。**

- `app/libs` 里的 `forcetech-release.aar` 只有 `armeabi-v7a`，`jianpian-release.aar` 和 `thunder-release.aar` 只有 ARM/ARM64。x86_64 包不能加载这些 native so，因此服务端运行时会禁用 ForceTech、JianPian、Thunder 解析器，并从 x86_64 APK 中移除这些 AAR 带入的 ARM native 中间产物和 `assets/libmitv.so`。
- x86_64 无头 Bridge Server 仍复用完整 app 的 `Server` / `Bridge` / `SiteApi` / `JarLoader` / `BaseLoader`，所以 Jar Spider、QuickJS、Chaquopy、普通 HTTP 播放代理路径可以保留。TVBus 依赖配置下发的动态 so，只有拿到对应 x86_64 so 时才应视为可用。
- `catvod` 模块本身未锁 ABI；`quickjs` 使用的 `wang.harlon.quickjs:wrapper-android:3.2.3` AAR 静态检查包含 `arm64-v8a`、`armeabi-v7a`、`x86`、`x86_64` 四套 `libquickjs-android-wrapper.so`。
- `chaquo` 官方 17.0 文档支持 `arm64-v8a`、`x86_64`，当前项目使用 Python 3.10。本次已经为 `app` 与 `chaquo` 增加 `x86_64` flavor/`abiFilters`，并验证 `requirements.txt` 中 `lxml`、`ujson`、`pycryptodome` 等包可下载 x86_64 Android wheel 并打入 APK。
- 推荐只承诺 `x86_64`，不优先做 32-bit `x86`。Android Emulator 当前主流是 x86_64，32-bit x86 价值低，还会增加 Chaquopy/依赖包验证面。

因此，x86_64 Bridge APK 的合理落地方式是：在 `TV/app` 保持完整 Bridge 能力，新增 `x86_64` ABI flavor 和前台无头 `HeadlessServerService`；运行时通过 `/health` 上报 ABI 与被禁用的 native 解析器；用 Linux/KVM x86_64 emulator 跑一次 `/health`、Jar Spider、QuickJS、Python 初始化验收。本文后续 Docker 部署、Phase 0 和验收标准中的 x86_64 要求，均指这个无头 Bridge Server 用法，不代表 x86_64 上具备 ARM 盒子完整播放协议能力。

第一版不建议的形态：

| 形态 | 优点 | 第一版问题 |
| --- | --- | --- |
| 纯 OpenJDK + URLClassLoader 加载 jar | 部署简单 | DEX 不能直接加载，常见 Android spider jar 无法直接运行；Spider 基类依赖 Android |
| Node.js | Web/JS 生态强 | DEX/Jar 完全外接，不能复用 FongMi 现有代码 |
| Python/FastAPI | Python 源看似自然 | 现有 chaquopy `.py` 源依赖 Java 桥，纯 CPython 不能跑 |
| Go | 部署轻 | 三种动态运行时全部外接，桥接成本最高 |
| Spring Boot 直接运行 jar | JVM 生态成熟 | 同 OpenJDK，仍卡在 DEX 与 Android Context |
| Ktor Server on Android | Kotlin API 现代 | 仓库未使用 Ktor；已有 NanoHTTPD 与 `/proxy` 能直接复用，第一版引入新 server 框架会增加集成风险 |

推荐结构（在 Android 工程中落地）：

```text
TV/
  app/                          # 现有 Android App（保留）
  catvod/, quickjs/, chaquo/    # 现有 Spider/QuickJS/Python 模块（直接复用）
tvbox-Swift/
type3-bridge-server/
  build.gradle.kts              # Android application/library，复用 TV/app 的 server 思路
  AndroidManifest.xml
  src/main/kotlin/
    server/                     # NanoHTTPD Process：Bridge HTTP API、鉴权、限流
    site/                       # 复用 com.fongmi.android.tv.api.SiteApi / BaseLoader
    spider/                     # 复用 JarLoader / JsLoader / PyLoader 适配层
    media/                      # 直连判定、解析结果、代理 URL 签名
    proxy/                      # Range/M3U8/分片代理 + Spider.proxy() 透传
    model/                      # 与 iOS 交互的 DTO
  README.md
```

说明：服务端运行在 Android Runtime 上，可以是后台 Service、Foreground Service 或独立 Activity App。首版建议直接复用现有 NanoHTTPD server：`Server.start()` 会在 `9978..9998` 之间自动选择端口，`Proxy.set(i)` 记录端口，`/proxy` 已经能转发到 `BaseLoader.get().proxy(params)`。

## 4. 服务端能力边界

### 4.1 需要服务端承接的内容

- `type=3` 的全部三种实现（FongMi 在 `BaseLoader.getSpider` 里按 api 字符串分派）：
  - api 含 `.py` → chaquopy Python Spider（`pyLoader`）。
  - api 含 `.js` → QuickJS Spider（`jsLoader`）。
  - api 以 `csp_` 开头 → Jar/DEX Spider（`jarLoader`）。
- Android DEX Jar 下载、md5 校验（`jar;md5;<hash>` 语法）、`DexClassLoader` 加载、反射调用、卸载与缓存。
- chaquopy Python 运行时及其 `com.github.catvod.*` Java 桥；不能用裸 CPython 直接替换。
- QuickJS 运行时及其 dex 形式的桥接助手（HTTP、加解密、`Local`、`Global`、`Console`、`Module` 等）。
- Spider 公共桥接能力：`Spider.proxy(Map)` 本地代理、`liveContent`、`manualVideoCheck`、`isVideoFormat`、`action`。
- 解析接口（`parses`）、Web 嗅探或动态脚本最终得到的播放结果归一化。
- 无法直连时的媒体代理、M3U8 重写、分片代理、Range 下载。

### 4.2 iOS 第一阶段只需要承接的内容

- 设置页新增 Bridge Server 地址与连通性检测。
- `SourceBean.isSupportedInSwift` 改为：`type=0/1/4` 本地支持，`type=3` 在 Bridge 可用时显示为“服务端支持”。
- `SourceService` 遇到 `type=3` 时调用 Bridge API，不再本地解析。
- `DetailViewModel` 播放前调用 Bridge `play`，接收直连或代理 URL。
- `DetailViewModel` / `PlayerView` 使用 `PlayableItem` 承接 Bridge 播放结果，已接 URL、headers、format、字幕、弹幕、DRM 元数据，播放器能力按内核逐步消费。

## 5. 架构流程

### 5.1 配置加载

```text
iOS 加载原始配置
  -> type=0/1/4 保持现有逻辑
  -> type=3 不丢弃，标记 requiresBridge=true
  -> iOS 将源 key/api/ext/jar 信息交给 Bridge Server
  -> Bridge Server 下载或读取 Jar/Py/JS 资源，初始化源运行时
```

服务端需要支持两种初始化方式：

- iOS 把完整配置 URL 传给服务端，由服务端自己解析配置并初始化所有动态源。
- iOS 只把单个 `SourceBean` 传给服务端，由服务端按需初始化该源；这种模式必须携带站点 `jar`，或者携带顶层 `spider` 作为默认 jar。Android 的 `Site.objectFrom(element, spider)` 会在站点 `jar` 为空时用顶层 `spider` 补齐。

第一版建议采用“配置 URL 注册”为主：服务端能看到完整 `sites`、`parses`、`rules`、`headers` 等上下文，和 Android 行为更接近。

### 5.2 数据请求

```text
iOS Home/Search/Detail
  -> 如果 source.type != 3：走现有 SourceService
  -> 如果 source.type == 3：走 BridgeClient
      /api/v1/site/{siteKey}/home
      /api/v1/site/{siteKey}/category
      /api/v1/site/{siteKey}/detail
      /api/v1/site/{siteKey}/search
      /api/v1/site/{siteKey}/action
  -> Bridge Server 调 Spider/Py/QuickJS
  -> 返回 iOS 现有 Movie/VodInfo 可映射 JSON
```

### 5.3 播放请求

```text
iOS 选择剧集 URL
  -> Bridge Server /api/v1/site/{siteKey}/play
  -> 服务端执行 Spider playerContent / parse / extractor / 嗅探
  -> 如果得到可直连媒体：返回 mode=direct
  -> 如果需要服务端保持上下文或转发：返回 mode=proxy
  -> iOS 播放 response.url
```

播放返回示例：

```json
{
  "mode": "direct",
  "url": "https://example.com/video/index.m3u8",
  "headers": {
    "User-Agent": "Mozilla/5.0",
    "Referer": "https://example.com/"
  },
  "format": "hls",
  "parse": 0,
  "subtitles": [],
  "danmakus": [],
  "expiresAt": 1777555200
}
```

代理返回示例：

```json
{
  "mode": "proxy",
  "url": "https://bridge.example.com/proxy/media/eyJhbGciOi.../index.m3u8",
  "headers": {},
  "format": "hls",
  "parse": 1,
  "expiresAt": 1777555200
}
```

## 6. Bridge Server API 设计

### 6.1 基础接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/health` | 健康检查，返回版本、运行时状态 |
| `POST` | `/api/v1/config/register` | 注册配置 URL 或配置 JSON，服务端解析并初始化动态源 |
| `GET` | `/api/v1/config/{configId}/sites` | 返回服务端可用的动态源列表 |
| `POST` | `/api/v1/site/{siteKey}/home` | 首页推荐、分类列表 |
| `POST` | `/api/v1/site/{siteKey}/category` | 分类分页与筛选 |
| `POST` | `/api/v1/site/{siteKey}/detail` | 详情与线路剧集 |
| `POST` | `/api/v1/site/{siteKey}/search` | 搜索 |
| `POST` | `/api/v1/site/{siteKey}/play` | 播放解析，返回直连或代理 URL |
| `POST` | `/api/v1/site/{siteKey}/action` | Spider action 扩展能力 |
| `POST` | `/api/v1/site/{siteKey}/token` | 提交网盘 Token/Cookie，写入 Android Bridge 运行时后重试播放 |
| `GET` | `/proxy/media/{token}/{path...}` | Bridge 自有媒体代理与分片代理 |
| `GET/POST` | `/proxy?...` | 兼容 FongMi Spider 本地代理，直接转发到 `BaseLoader.get().proxy(params)` |

### 6.2 注册配置请求

```json
{
  "configUrl": "https://example.com/tvbox.json",
  "client": "tvbox-swift",
  "platform": "iOS",
  "preferredLocale": "zh-Hans"
}
```

返回：

```json
{
  "configId": "md5:...",
  "sites": [
    {
      "key": "jar-site-key",
      "name": "示例 Jar 源",
      "type": 3,
      "searchable": 1,
      "filterable": 1,
      "quickSearch": 0,
      "status": "ready"
    }
  ],
  "runtimes": {
    "jarDex": "ready",
    "chaquopy": "ready",
    "quickjs": "ready"
  }
}
```

### 6.3 分类请求

```json
{
  "configId": "md5:...",
  "categoryId": "movie",
  "page": 1,
  "filters": {
    "area": "内地",
    "year": "2026"
  }
}
```

返回结构尽量贴近 Swift 现有模型：

```json
{
  "page": 1,
  "pageCount": 20,
  "limit": 20,
  "total": 400,
  "list": [
    {
      "vod_id": "123",
      "vod_name": "影片名",
      "vod_pic": "https://example.com/poster.jpg",
      "vod_remarks": "1080P",
      "sourceKey": "jar-site-key"
    }
  ]
}
```

### 6.4 播放请求

```json
{
  "configId": "md5:...",
  "flag": "线路一",
  "id": "https://origin.example.com/play?id=123",
  "vipFlags": [],
  "clientCapabilities": {
    "acceptDirect": true,
    "acceptProxy": true,
    "acceptHeaders": false,
    "acceptHlsRewrite": true
  }
}
```

Swift 端已用 `PlayableItem` 承接 headers，直连仍要按播放器内核能力判断；如果直连依赖当前内核无法稳定消费的能力，服务端仍应降级为 `mode=proxy` 或返回明确原因。

服务端内部可以直接复用 Android `Result`，但对 iOS 返回时要稳定映射字段：Android 原字段是 `header`、`subs`、`danmaku`、`drm`，Bridge DTO 可以对外命名为 `headers`、`subtitles`、`danmakus`、`drm`，但映射关系必须固定并写测试。

### 6.5 网盘 Token 与 Jar 弹窗交互

部分网盘类 Jar 会在 `playerContent` 内部直接弹 Android 原生输入框、扫码框或 provider 选择框。Bridge 模式下不能按“夸克二维码”“UC Cookie”这类 provider 分支硬编码，否则很容易串登录态，也无法适配 Jar 后续新增的登录方式。当前实现采用两层处理：播放前仍用服务端预检返回结构化 `token_required` prompt；用户选择扫码/登录时，客户端进入通用 `androidJarUi` 远程弹窗桥接。

`androidJarUi` 不复制 Android 原生控件样式，而是由 Android Bridge 截取当前 Jar 弹窗根 View 为 PNG，并输出可交互元素的坐标、角色和文本。Swift 端显示截图，在可点区域上覆盖轻量点击层；点按、输入、返回、刷新通过 `/qrAction` 发回 Android。这样 Quark、UC、阿里、百度或未来新 provider 都走同一个 Jar 弹窗路径，登录态只存在 Android Runtime 内。

返回示例：

```json
{
  "ok": false,
  "code": "token_required",
  "mode": "tokenRequired",
  "message": "当前网盘播放需要先配置 Token 或 Cookie",
  "prompt": {
    "provider": "quark",
    "title": "夸克网盘 Token",
    "message": "当前网盘播放需要先配置 Token 或 Cookie",
    "submitPath": "/api/v1/site/YpanSo/token",
    "login": {
      "type": "androidJarUi",
      "title": "夸克网盘 Jar 登录",
      "url": "/api/v1/site/YpanSo/qrLogin",
      "cookieKey": "token",
      "domains": ["quark.cn", "pan.quark.cn", "drive-pc.quark.cn"]
    },
    "fields": [
      {
        "key": "token",
        "label": "Token / Cookie",
        "placeholder": "粘贴夸克 Cookie 或 Token",
        "secure": true,
        "multiline": true
      }
    ],
    "retry": {
      "flag": "夸父盘",
      "id": "原始剧集 JSON"
    }
  }
}
```

客户端提交：

```json
{
  "provider": "quark",
  "token": "用户粘贴的 token 或 cookie",
  "values": {
    "token": "用户粘贴的 token 或 cookie"
  }
}
```

Bridge 会把值写入 Android 默认偏好、`userData` 和 Bridge 自有偏好，并同时写入常见 key 变体，例如 `quark_cookie`、`quarkToken`、`UCCookie`、`refresh_token` 等。保存成功后客户端重试原来的 `/play` 请求。这个流程保留 Android Jar 的真实运行环境，但把用户交互迁移到 iOS/macOS。

`login.type = androidJarUi` 表示客户端应调用 `/api/v1/site/{siteKey}/qrLogin`，请求体携带 `provider`、`flag`、`id`。成功响应会返回 `mode=androidJarUi`、`image`、`width`、`height` 和 `elements`；`elements` 中的 `button` / `input` 坐标用于 Swift 覆盖交互层。Bridge 截图器必须过滤 Android `TYPE_TOAST`、输入法窗口和小型 text-only transient root，不能把 toast 截成远程页面；如 Jar 弹出短 toast，应以独立 `toast` 字段返回 `{ "type": "toast", "message": "...", "durationMs": 2200 }`，客户端只做临时提示，不替换弹窗画布。

后续操作统一调用 `/api/v1/site/{siteKey}/qrAction`：`action=click` 可携带 `elementId` 或坐标，`action=input` 携带 `elementId` 与文本，`action=back` 发送 Android Back，`action=refresh` 重新抓取当前弹窗，`action=cancel` 取消 Android 端 QR 任务并尽量关闭 Jar 弹窗。`/qrStatus` 只负责轮询 Jar 登录是否完成，默认不抓取 UI；如客户端确实需要同步当前弹窗，可在请求体携带 `includeUi=true`。`/qrConfirm` 只按当前 provider 写入 Jar-QR-ready 标记并重试播放，不再写死 Quark。

### 6.6 云盘配置 Action 桥接

`MDrive` / “我的云盘┃我配置”这类站点的 `vod` 卡片会携带 `action` 字段。Android 原版点击后通常调用 `SiteApi.action`，部分 Jar 会直接依赖当前 Android `Activity` 弹原生登录、扫码或清除 Cookie 对话框。Bridge 模式下不能让这些 UI 副作用留在 Android 端，否则 iOS/macOS 只会看到空 JSON 或无响应。

当前实现对常用云盘配置 action 做结构化拦截：

- `LoginShow`、`pushCkShow` 返回 `mode=cloudLogin`，并携带多个 `BridgeTokenPrompt`。Swift 端展示 provider 选择，再打开 Android Jar 远程弹窗或手动粘贴 Token/Cookie；最终凭据只提交到 Android Bridge 运行时。
- `quarkClean`、`ucClean`、`aliClean`、`BdClean` 返回 `mode=message`，Bridge 在 Android 偏好、常见 provider key 和 WebView Cookie 中清除对应授权，并同步清理 loader 缓存。
- 未识别的 action 继续回落到原始 `SiteApi.action` / `Spider.action`，保持普通站点扩展能力。

示例返回：

```json
{
  "ok": true,
  "mode": "cloudLogin",
  "action": "LoginShow",
  "message": "选择网盘登录方式，登录状态只保存到 Android Bridge",
  "prompts": [
    { "provider": "quark", "title": "夸克网盘 Token" },
    { "provider": "uc", "title": "UC 网盘 Token" },
    { "provider": "ali", "title": "阿里云盘 Token" },
    { "provider": "baidu", "title": "百度网盘 Token" }
  ]
}
```

Swift 端处理规则是：`Movie.Video.action` 非空时不进入详情页，而是调用 `/api/v1/site/{siteKey}/action`。这让 iOS 成为 Android Bridge 的远程操作面板，登录态和清理动作都留在 Android 运行时，不把网盘登录状态长期保存到 iOS 客户端。

## 7. Spider 适配设计

服务端 Spider 适配层负责把 `com.github.catvod.crawler.Spider` 的全部方法归一成 Bridge API：

| Bridge 行为 | Spider 方法 |
| --- | --- |
| 初始化 | `init(Context)` / `init(Context, String ext)` |
| 首页 | `homeContent(boolean filter)` |
| 首页视频 | `homeVideoContent()` |
| 分类 | `categoryContent(String tid, String pg, boolean filter, HashMap<String,String> extend)` |
| 详情 | `detailContent(List<String> ids)` |
| 搜索（旧） | `searchContent(String key, boolean quick)` |
| 搜索（带分页） | `searchContent(String key, boolean quick, String pg)` |
| 播放 | `playerContent(String flag, String id, List<String> vipFlags)` |
| 直播 | `liveContent(String url)` |
| 嗅探辅助 | `manualVideoCheck()` / `isVideoFormat(String url)` |
| 本地代理 | `proxy(Map<String,String> params) -> Object[]` |
| 扩展 | `action(String action)` |
| 销毁 | `destroy()` |

关键实现点（Jar/DEX 路径，对应 `JarLoader`）：

- 仅在 Android Runtime 上工作。每个 jar 用独立 `DexClassLoader`，按 `md5(jar)` 缓存。
- 类名约定：`com.github.catvod.spider.<api 在 "csp_" 之后的部分>`，反射 `newInstance()` 后调用 `init(context, ext)`。
- `jar` 字段支持 `http(s)://...`、`assets://...`、`file://...`，以及 `<url>;md5;<hash>` 形式校验。
- 初始化必须传入有效 Android `Context`（推荐用 Bridge Server 自身的 `Application`）。
- Spider 调用必须有超时；FongMi 的默认 `Constant.TIMEOUT_PLAY` 可作参考，文档建议首页/分类/搜索 15s、详情 20s、播放 30s。
- 反射异常统一转换为 Bridge 错误码，不能让 iOS 处理 Java 堆栈。
- 对返回 JSON 做兼容清洗：注释、非标准字段、空数组/空对象、字符串数字混用（FongMi `Result.fromType` 已有部分处理，可参考）。
- 卸载时调用 `Spider.destroy()` 释放线程池/连接。

QuickJS（`.js`，对应 `JsLoader` / `quickjs/Spider.java`）要点：

- 仍依赖 `DexClassLoader` 加载 dex 形态的 JS 桥接助手；脱离 Android Runtime 需要重写整套桥接（`Console`、`Global`、`Local`、`Module`、`Async`、`Asset`、`UriUtil` 等）。
- 单 `QuickJSContext` 单线程串行执行（FongMi 用 `Executors.newSingleThreadExecutor()`），适配层必须保留串行语义，不要并发触发同一个 spider。

Python（`.py`，对应 `PyLoader` / chaquo）要点：

- FongMi 走 chaquopy；脚本可以 `from com.github.catvod import Proxy` 直接调用 Java 类，依赖 Java↔Python 双向桥。
- 入口在 `chaquo/src/main/python/trigger.py` 与 `app.py`，所有 Spider 方法都通过它转发。
- 在 Android Runtime 上运行 chaquopy 是最低成本路径。若未来要用纯 CPython，需要把 `com.github.catvod.*` 关键类用 Python 重写或通过 JSON-RPC 远程代理；这是另一个独立项目，不在第一版范围。

## 8. Python 与 QuickJS 运行时

第一版（Android Runtime 部署）：直接复用 FongMi 现有 `quickjs` 和 `chaquo` 模块，不引入额外进程：

```text
Bridge Server (Android 进程)
  -> BaseLoader
    -> JarLoader  (DexClassLoader)
    -> JsLoader   (QuickJS + dex 助手)
    -> PyLoader   (chaquopy)
```

这样可以最大兼容现有 jar/py/js 源，无需重新设计跨进程协议。

隔离与稳定性要求依然成立：

- 每次 Spider 调用包一层超时、最大输出大小、异常吞咬。
- 每个 site 有独立缓存目录（参考 FongMi 的 `Path.jar()`、`Path.cache()` 约定）。
- Spider 生命周期在请求维度复用同实例；卸载时调用 `destroy()`。
- QuickJS 必须串行调用同一个 ctx；并发请求由 Bridge 上层排队。
- 频繁崩溃的 spider 触发熔断，下次请求短路返回错误。

第二版（如需脱离 Android Runtime）才考虑 sidecar runner 方案：CPython 进程 + 重写的 `com.github.catvod.*` 桥；服务端 QuickJS 引擎（quickjs-go / Rhino / GraalJS）+ 重写的 dex 助手。两者实现量都比第一版大，列入未来工作而不是 Phase 0/1。

## 9. 直连与代理判定

服务端 `PlayResolver` 应按以下顺序处理播放结果：

1. Spider/脚本返回可播放 URL，且不依赖特殊 headers/cookie，返回 `mode=direct`。
2. URL 依赖 headers，但 iOS 当前播放器不能传递，优先交给 Bridge/Spider 本地代理；若返回值已是 `/proxy?...`，对 iOS 视为可直接播放的 `mode=direct` 代理 URL。
3. URL 是 M3U8，分片也依赖 headers、签名、相对路径或跨域跳转，服务端重写 M3U8 并代理分片。
4. URL 需要短时 Cookie、一次性 token、Referer 校验，返回 `mode=proxy`，代理 token 绑定过期时间。
5. URL 是无法由 iOS 直接播放的中间协议，服务端 extractor 转换；转换失败时返回结构化错误。

代理必须支持：

- `Range` 请求和 `206 Partial Content`。
- `HEAD`、`GET`。
- 上游 redirects。
- 上游 headers 注入和敏感 headers 过滤。
- HLS 主列表、媒体列表、Key URI、分片 URI 重写。
- 代理 token 过期、签名、防盗链和请求来源限制。
- **Spider 本地代理透传**：FongMi 生态里 spider 可返回 `proxy://` 或 `http://127.0.0.1:<port>/proxy?...` URL，运行时由 `BaseLoader.get().proxy(params)` 分派到 Jar/JS/Python 的 `proxy(Map)`。现有 `TV/app/src/main/java/com/fongmi/android/tv/server/process/Proxy.java` 约定返回值为 `Object[]{ status, contentType, InputStream }`，可选第 4 项为 `Map<String,String>` 响应头。Bridge Server 必须保留兼容 `/proxy` 入口，把 query、请求头和 POST body 合并后转给 `BaseLoader.get().proxy(params)`；否则这类源在播放或封面加载阶段会失败。返回给 iOS/macOS 时，`127.0.0.1` 本地代理地址必须按请求 `Host` 外化，例如 BlueStacks 开发期应返回 `http://127.0.0.1:9978/proxy?...`，而不是 Android 虚拟机内部 IP。

## 10. iOS 最小改动清单

第一阶段建议只改这些点：

| 文件 | 改动 |
| --- | --- |
| `tvbox/Models/SourceBean.swift` | 增加 `jar`、`requiresBridge`、`isPlayableWithBridge`，不要直接把 `type=3` 当作完全不可用 |
| `tvbox/Services/ApiConfig.swift` | 配置加载时保留 `type=3` 源；把 `SiteConfig.jar` 和顶层 `spider` fallback 写入 Bridge 注册 DTO；Bridge 未配置时 UI 标记不可用，不隐藏数据 |
| `tvbox/Services/BridgeClient.swift` | 新增轻量客户端，封装 register/home/category/detail/search/play |
| `tvbox/Services/SourceService.swift` | 遇到 `type=3` 分派到 `BridgeClient`，其它类型保持原逻辑 |
| `tvbox/ViewModels/DetailViewModel.swift` | 播放 `type=3` 剧集前调用 Bridge `play`，把返回 URL、headers、format、字幕、弹幕、DRM 映射进 `PlayableItem` |
| `tvbox/Views/Settings/SettingsView.swift` | 增加 Bridge Server 地址、测试连接、启用开关 |

`PlayableItem` 已落地，服务端返回的 `headers`、`subtitles`、`danmakus`、`drm` 会进入 Swift 播放对象。仍需继续补播放器能力矩阵，尤其是 DRM 解密、弹幕渲染和复杂字幕格式。

## 11. 部署与发现

第一版配置方式：

- 用户手动输入 Bridge Server 地址，例如 `http://192.168.1.10:9978`。Android 现有 `Server.start()` 会从 `9978..9998` 自动探测可用端口，UI 不应写死单一端口。
- 设置页提供 `/health` 检测，显示 Jar/DEX、chaquopy、QuickJS runtime 状态。
- iOS 保存最近使用的 Bridge 地址。

第二阶段增强：

- mDNS/Bonjour 发现局域网 Bridge Server。
- 二维码配对。
- 多服务端选择和延迟测试。
- HTTPS 和访问 token。

部署摘要：

- 开发期跑 Android 真机/盒子或模拟器；长期服务端优先 Linux/KVM + 无头 Android Emulator/Docker。
- 生产目标是 §3.2 的裁剪 `x86_64` Bridge APK，不是完整 Android App。
- Docker Desktop on macOS/Windows 不作为生产目标；NAS/软路由/VPS 只有具备 KVM 或可接受 nested virtualization 时才推荐。
- 公网暴露必须启用 HTTPS、访问 token、请求限流和日志脱敏。

Docker Android 启动/运维顺序：

```text
docker start type3-android-emulator
  -> emulator -no-window ... -gpu swiftshader/lavapipe -no-boot-anim
  -> adb wait-for-device
  -> adb shell getprop sys.boot_completed == 1
  -> adb install/pm path Bridge APK（首次或版本变化时）
  -> adb shell am start-foreground-service ...BridgeService
  -> adb forward tcp:<publishedPort> tcp:<bridgePort>
  -> GET http://127.0.0.1:<publishedPort>/health
```

`<bridgePort>` 不能写死为 `9978`：现有 Android `Server.start()` 会在 `9978..9998` 之间选择可用端口。Bridge APK 应把实际端口写入日志、通知或 ADB 可读位置，运维脚本再建立转发。

### 11.1 Waydroid 部署可行性（x86 Linux 服务端方案）

事实结论：**Waydroid 可以作为 x86 Linux 服务端运行 Bridge APK，但 iOS 不能"直接连 APK 端口"，必须由宿主机做端口转发；是否额外写后端取决于功能需求，不是必需。**

依据（来自 Waydroid 官方文档、`waydroid-net.sh` 源码、Arch Wiki、LXC 容器模型）：

1. 运行模型：Waydroid 用 Linux namespaces（user/pid/uts/**net**/mount/ipc）跑一个基于 LineageOS 的 Android 13 系统，本质是 LXC 容器，不是虚拟机。
2. 网络拓扑：`waydroid-net.sh` 在宿主机创建 `waydroid0` 网桥，子网 `192.168.240.0/24`，网关 `192.168.240.1`，容器拿 `192.168.240.x` 通过 `iptables -t nat -A POSTROUTING ... -j MASQUERADE` 出网。**只配置了出向 NAT，没有入向 DNAT。**
3. 因此 APK 内 NanoHTTPD 监听 `0.0.0.0:9978` 只在 Android 命名空间生效：
   - 宿主机本机：可直接访问 `http://192.168.240.<容器IP>:9978`（网桥在 host 上）。
   - 宿主同网段其他机器（含 iOS）：**默认不可达**，必须显式做以下之一：
     - `iptables -t nat -A PREROUTING -p tcp --dport 9978 -j DNAT --to-destination 192.168.240.x:9978` + `FORWARD ACCEPT`；
     - 或 `socat TCP-LISTEN:9978,fork,reuseaddr TCP:192.168.240.x:9978`；
     - 或用 nginx/caddy 在 host 反代到容器 IP。
4. 容器 IP 由 dnsmasq DHCP 在 `192.168.240.2-254` 分配，不固定。生产部署需要：在 Bridge APK 启动后通过 `waydroid shell ip -4 addr show` 或固定 MAC + `dhcp-host` 静态绑定取到容器 IP，再写入宿主转发规则。
5. ADB：Waydroid 提供 `waydroid shell`，也可在容器里启用 `adbd` 后从 host `adb connect 192.168.240.x:5555` 安装/管理 APK。
6. 宿主前提（事实硬约束）：
   - 必须真实 Linux 主机，**不能跑在 Docker 里**（Waydroid 自身就是 LXC，且需要 binder/binderfs、`/dev/binder`、`CONFIG_PSI=1`、IPv6、`ip_forward=1` 等内核能力）。
   - GPU 对 NVIDIA 支持差；Bridge 是后端无 UI，可用 `swiftshader` 软渲染绕开。
   - 仍需要一个 Wayland session（headless 服务器可用 `cage` 嵌套或 `weston --backend=headless`），因为 Waydroid 的 `show-full-ui` 走 Wayland；但 Bridge 不需要 UI，只跑 `waydroid session start` + `waydroid app launch` 即可，不必显示。
   - x86_64 上 ARM-only 的 spider/jar 需要 libndk/libhoudini 翻译层；这正好是 §3.2 要求把 jar 走 DEX、播放/协议 native 模块裁掉的原因。
7. 性能/稳定性：Waydroid 是容器级，不是 emulator，CPU 几乎裸跑，比 KVM + Android Emulator 轻很多；代价是内核耦合更深，发行版/内核升级容易踩坑。

部署形态二选一（基于以上事实，不是空想）：

- **方案 A：APK 直接暴露 + 宿主一层端口转发（推荐第一版）。**
  - 组件：Waydroid 容器跑 Bridge APK（NanoHTTPD），host 上一条 DNAT 或 `socat`/nginx。
  - iOS 端：直连 `http://<host-ip>:9978`，等价于直连 APK。
  - 优点：零额外后端代码；HTTP 协议、`/health`、Spider/Py/JS 全部在 APK 内完成；故障面最小。
  - 缺点：要在 host 上动态拿容器 IP 并写转发；TLS、鉴权、多实例、版本灰度都要手工脚本化。

- **方案 B：APK + 一个轻量宿主后端（运维/合规需要时再上）。**
  - 组件：Waydroid + Bridge APK 仍提供完整 type=3 能力；宿主侧再跑一个 nginx/caddy 或自写 Go/Rust 小服务。
  - 后端职责（仅当需要时）：TLS 终止、Bearer token 鉴权、限流、mDNS/Bonjour 广播、容器 IP 自动发现并热更转发、多 Bridge 实例负载、URL 重写（部分 Spider 返回相对路径或 `127.0.0.1` 链接需替换成对外可达地址）、APK 健康监测/自动重启 `waydroid session restart`。
  - 关键事实：这一层**不参与 type=3 协议解析**，不替代 APK；它是网关，不是桥接器。把 Spider/Jar/Py/JS 解析放进自写后端等于重做 §3 已经否决的事。

判定：

- 如果只是家庭/局域网自用，**方案 A 已经够用**，iOS 直接打 host:port 就能拿到 APK 的 NanoHTTPD 响应，无需再写后端。
- 如果需要公网暴露、多人共享、零信任鉴权、动态发现，**走方案 B**，但后端只做反代/治理，不做协议层。
- 不论 A/B，**不能跳过 Bridge APK 直接用宿主后端跑 type=3**：DEX jar、Chaquopy、QuickJS 必须在 Android Runtime 里运行（§3、§3.1 已论证）。

未实测项（诚实声明）：本机已完成 x86_64 APK 构建和 APK 内容校验，但还未在真实 Linux/KVM x86_64 VPS 上启动 Android Runtime、安装 APK 并执行 iOS 直连测试。落地时需先在一台符合上述硬约束的 x86_64 Linux 上做一次 `/health` + Jar Spider + QuickJS + Python 端到端验证。

## 12. 安全与合规

动态源在服务端运行后，安全风险从 iOS 转移到服务端，不能忽略：

- 默认只允许用户主动配置的服务端，不内置公共动态源服务。
- Jar/Py/JS 资源按 hash 缓存，并记录来源 URL。
- 服务端提供源级启停、缓存清理、运行时日志和错误统计。
- 限制文件系统访问范围，禁止读取服务端敏感路径。
- 限制内网请求策略，避免被动态源用作 SSRF 跳板；家庭部署可提供“信任局域网”开关。
- 代理 URL 必须签名且短期有效，避免被公开盗链。
- 日志不得记录完整播放 token、Cookie、Authorization。

## 13. 分阶段实施路线

### Phase 0：协议和骨架

- 新建 `type3-bridge-server` Android 工程（application 或 library 形态），或在 `TV/app` 现有 `server` 包旁新增 Bridge `Process`。
- 复用 NanoHTTPD 的 `Process` 分发模型，新增 `/api/v1/...` JSON API；保留现有 `/proxy` 行为。
- 复用 `:catvod`、`:quickjs`、`:chaquo` 模块依赖，准备好可注入 `Application` Context。
- 为服务端 Bridge 建立 x86_64 APK：`TV/app` 和 `chaquo` 增加 `x86_64` flavor；x86_64 运行时禁用 `forcetech`、`thunder`、`jianpian` 等 ARM-only native 解析器；确认 APK 内只包含 x86_64 native 库，并在目标 emulator ABI 上验证 QuickJS/chaquopy 可启动。
- 准备 Linux/KVM 无头 Android Docker 启动脚本：持久化 AVD userdata，等待 boot completed，启动 Bridge Service，建立端口转发，检查 `/health`。
- 实现 `/health`、配置注册、基础 DTO、错误码。
- iOS 增加 Bridge Server 设置和连通性检测。

### Phase 1：Jar Spider 可用

- 服务端复用 `JarLoader`：Jar 下载、md5 校验、`DexClassLoader` 加载、`Spider.init(Context, ext)` 调用。
- 通过 `SiteApi` / 新封装的 SpiderAdapter 打通 home/homeVideo/category/detail/search/play/action。
- iOS 保留 `type=3` 源，并通过 `BridgeClient` 展示列表、详情和播放。
- 播放优先直连；headers 场景由服务端代理。

### Phase 2：代理能力完善

- 实现 Range 代理、M3U8 重写、分片代理、Key URI 代理。
- 暴露 `Spider.proxy(Map)` HTTP 入口，处理 spider 自带的 `127.0.0.1` 代理 URL。
- 增加代理 token、过期时间、上游 headers、错误重试。
- 服务端自动判断 direct/proxy。

### Phase 3：Python / QuickJS 全面接入

- 复用 `JsLoader`（QuickJS + dex 助手），单 ctx 串行调度。
- 复用 `PyLoader`（chaquopy），保留 `from com.github.catvod import Proxy` 类桥接。
- 对 Py/QuickJS 源接入同一套 Bridge API。

### Phase 4：能力回填 Swift 播放器

- 继续扩展 `PlayableItem` 消费路径。
- Swift 播放器支持 headers、字幕、弹幕、DRM 元数据的完整能力矩阵。
- Bridge 返回更丰富播放信息；可直连的场景减少代理流量。

## 14. 优先级建议

| 优先级 | 任务 | 原因 |
| --- | --- | --- |
| P0 | Android/NanoHTTPD Bridge API 骨架 | 后续所有动态源能力的承载层，且能复用现有 `/proxy` 与端口管理 |
| P0 | 裁剪 Bridge APK 与 x86_64 ABI 验证 | Docker Android 长期运行必须避开 ARM-only native 依赖 |
| P0 | Linux/KVM 无头 Android Docker 启动脚本 | 比手机/盒子更适合常驻，但必须有 boot、端口、健康检查和持久化 |
| P0 | Jar Spider 加载与 play 链路 | `type=3` 最核心能力，价值最高 |
| P0 | iOS Bridge 设置与 `type=3` 分派 | 最少客户端改动即可看到效果 |
| P1 | 代理播放、M3U8 重写、Range | 解决不能直连和 headers 场景 |
| P1 | 配置注册与源状态管理 | 让服务端掌握完整配置上下文 |
| P2 | chaquopy / QuickJS 全面接入 | 覆盖 Py、QuickJS 动态脚本源 |
| P2 | mDNS 发现、HTTPS、访问 token | 提升部署体验和安全性 |
| P3 | Swift 播放器高级元数据消费 | 减少代理依赖，提升字幕/DRM/弹幕体验 |

## 15. 验收标准

- iOS 设置 Bridge Server 后，`type=3` 源不再被隐藏，并能显示服务端可用状态。
- 单源注册时，iOS 不会丢失站点 `jar` 或顶层 `spider` fallback；服务端能拿到与 Android `Site.getJar()` 等价的值。
- 至少一个 Jar Spider 源可以完成首页、分类、详情、搜索、播放全链路。
- 对可直连播放结果，iOS 能直接播放服务端返回的媒体 URL。
- 对需要 headers/cookie 的播放结果，iOS 能播放服务端代理 URL，拖动进度时 Range 正常。
- 服务端单个源执行超时不会拖垮其它源。
- Docker Android 部署在 Linux/KVM 上可冷启动、自动启动 Bridge Service、通过 `/health` 上报 runtime 状态，并在重启后保留 jar/cache。
- `x86_64` Bridge APK 不包含已知 ARM-only native 播放模块；如启用 chaquopy/QuickJS，必须在目标 ABI emulator 上实际完成一次初始化测试。
- Bridge Server 关闭或不可达时，iOS 现有 `type=0/1/4` 能力不受影响，`type=3` 给出明确不可用提示。

## 16. 与现有差异文档的关系

`ANDROID_FEATURE_GAP.md` 中把 `type=3` Spider/Jar、Java Jar、Py、QuickJS 和动态脚本运行时明确排除在 Swift 端差异分析之外。本文件专门补充这部分能力的可行落地路线：不要求 iOS 原生支持这些运行时，而是通过最外层 Bridge Server 把动态源能力转换成 iOS 可消费的 HTTP 数据和媒体播放地址。

## 17. 已核查后的确定开发计划

基于本仓库当前代码，第一版不再新建独立 `type3-bridge-server` 工程作为起点，而是先在现有 Android `:app` 内落地 Bridge API。原因已经由代码核实：`Server.start()`、`Nano`、`Process`、`/proxy`、`BaseLoader`、`JarLoader`、`JsLoader`、`PyLoader`、`SiteApi` 都已经在 `TV/app` 内可用；Swift 端也已经能解码 `AppConfigData.SiteConfig.jar` 和顶层 `spider`，只是没有保留到 `SourceBean`，并且 `SourceService` 主动拒绝 `type=3`。因此，第一批开发目标是最小闭环，而不是先拆 APK 或重做工程结构。

确定切入点如下：

1. Android 先新增 `Bridge` server process，注册到现有 `Nano.addProcess()`，提供 `/health` 与 `/api/v1/...` JSON API。`/proxy` 继续使用现有 `Proxy` process，不改协议。
2. Android 首批支持两种注册方式：`POST /api/v1/config/register` 接收 `configUrl` 时调用现有 `VodConfig.load` 体系；接收 `sites` 时只注册 Bridge 自有站点表，用于 Swift 已加载配置后的按需调用。
3. Android 首批数据接口只承诺 `home`、`category`、`detail`、`search`、`play`。实现时优先直接调用现有 `SiteApi`；当站点来自 Bridge 自有站点表而未进入 `VodConfig` 时，使用 `BaseLoader.getSpider(key, api, ext, jar)` 直接调 Spider，并把返回 JSON 归一成现有 `Result` JSON。
4. Android `play` 返回稳定 Bridge JSON：`mode`、`url`、`headers`、`format`、`parse`、`subtitles`、`danmakus`、`drm`、`expiresAt`。如果直连需要当前 Swift 播放内核无法消费的能力，应返回代理 URL 或结构化失败原因；已有 Spider 本地代理仍由 `/proxy` 保持可用。
5. iOS 新增 `BridgeClient`，只负责 HTTP 调用、健康检查和把 Bridge 返回的 `Result` 映射到现有 `MovieSort.SortData`、`Movie.Video`、`VodInfo`、播放 URL。
6. iOS `SourceBean` 保留 `jar` 和配置顶层 `spider` fallback，新增 `requiresBridge`、`isPlayableWithBridge`。`isSupportedInSwift` 保持“本地支持”语义，不把 `type=3` 伪装成本地支持。
7. iOS `ApiConfig.parseConfig` 在构造 `SourceBean` 时写入 `jar: site.jar ?? config.spider`，并在配置加载成功后，如果 Bridge 已启用，异步注册当前配置 URL 与站点元数据。
8. iOS `SourceService` 对 `type=3` 分派到 `BridgeClient`：首页/分类/详情/搜索走 Bridge，其它类型保持现有逻辑。
9. Swift `DetailViewModel` 播放 `type=3` 剧集前调用 Bridge `play`，把返回的 URL、headers、format、字幕、弹幕、DRM 写入 `PlayableItem`。
10. iOS 设置页增加 Bridge Server 地址、启用开关、`/health` 测试结果，并保存到 `UserDefaults`。未配置或不可达时，`type=0/1/4` 不受影响，`type=3` 返回明确错误。

本轮编码完成标准：

- Android 编译能通过，`GET /health` 返回 JSON，`/api/v1/site/{key}/home|category|detail|search|play` 有稳定成功/失败 JSON。
- Swift 编译能通过，设置页能保存和测试 Bridge 地址。
- Swift 加载配置后不丢弃 `type=3` 的 `jar`/`spider` 信息。
- Swift 在 Bridge 可用时能把 `type=3` 首页、分类、详情、搜索请求发到 Bridge；播放前能调用 Bridge `play` 并使用返回 URL。
- Bridge 不可达时，错误只影响 `type=3`，不破坏现有 XML/JSON/Remote 源。

暂不进入的问题，留到第一闭环跑通后再问或单独立项：

- 是否新建裁剪 Bridge-only APK 与 x86_64 flavor。
- 是否为公网部署加入 HTTPS、token、限流和 mDNS。
- 如何继续完善 `PlayableItem` 对 headers、字幕、弹幕、DRM 的播放器消费矩阵。
- 是否实现 Bridge 自有 Range/M3U8 媒体代理。
