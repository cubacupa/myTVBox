# myTVBox — HarmonyOS NEXT 智慧屏 TVBox 客户端

一个跑在 **HarmonyOS NEXT 智慧屏电视**上的 TVBox 形态客户端：填入你自己的**配置地址**（JSON 接口），
即可浏览多站点海报墙、切换线路、选集播放，并解析直播频道表。

**v2.1.5 重点更新：直接支持 Kazumi 规则。** 除了 TVBox 配置，还可以在设置页填一个**规则名**
（如 `giriGiriLove`）或规则链接，把 Kazumi 生态里的站点接进来 —— 苹果CMS 采集站跑不了的那些
番剧 / 影视站，靠规则里的 XPath 与 API 路径也能搜索、出分类、选集、播放。详见[第三节](#三kazumi-规则站重点)。

> **本工程不包含任何影视内容、采集站地址、直播源或账号。** 仓库是干净的代码：
> 首次启动没有任何站点，需要你在设置页填入自己的配置地址。
> 请只接入你拥有合法授权的内容，使用风险自负（见文末「免责声明」）。

---

## 一、它做什么

| 模块 | 说明 |
|---|---|
| 配置地址 | 点播源 / 直播源**两个独立槽位**，可分别填写，互不影响；支持普通配置（`sites` / `parses` / `lives`）与多仓配置（`urls`）；本地落盘缓存，离线可打开 |
| 手机扫码推送 | 电视自己起一个 HTTP 服务，手机连同一 Wi-Fi 扫码打开网页，粘贴地址推送，电视自动填入。无后端、带一次性 token |
| Default 空容器 | 内置一个空的 `builtin://default`，用来**收纳你自己试出来的站点**。收的是站点本身（api / type / ext），不是配置地址，所以原接口失效也不影响 |
| 首页 | 整屏横版剧照 + 磨砂玻璃信息面板的主推位；下方「随机推荐」20 部（各分类轮流抽，**启动时抽一批**，之后只在你点「换一批」时才变），再往下是收藏与继续观看。列表未加载时按真实尺寸铺骨架占位，不会跳版 |
| 点播首页 | 两级分类、海报墙、滚动加载、切换站点 / 分类即时响应；排序（最新 / 评分 × 升序 / 降序）、地区 / 年份筛选 |
| **Kazumi 规则站** | 设置页填**规则名**（如 `giriGiriLove`，**不区分大小写**）/ 规则链接 / 整段规则 JSON，回车即载入、收进 Default 并直接切过去；支持纯 XPath、`api+xpath`、`api+api`（delimited / nested）三种规则；分类既能读站点网页列表，也能自动读规则后端的 `get_class / get_list`；播放页带 macCMS `player_aaaa` 静态解与无头 WebView 嗅探兜底 |
| 豆瓣评分 + 海报 | 站点没海报时从豆瓣补图并取评分，本地缓存；可登录豆瓣提高配额，**默认未登录** |
| 详情 / 播放 | 多线路切换、选集、收藏、看过的集变暗；`AVPlayer + XComponent` 播放，支持续播、点进度条跳转、倍速、快进退、上/下集、播完自动连播、实际大小 / 全屏切换 |
| 直播 | 解析 txt 频道表（`#genre#`）与 m3u；同名频道按 `tvg-id` 合并成多线路，点开自动试线路；频道收藏、已看标记 |
| 家长锁 | 4 位 PIN 隐藏分类名含敏感词的分类，解锁有效期 30 分钟；点播分类与播放历史两份独立解锁态。**PIN 不存明文**：本地只保存随机盐 + 迭代 SHA-256 摘要，连续错 5 次锁定 60 秒 |
| 历史 | 按影片去重的播放记录，设了 PIN 后自动隐藏敏感分类的记录 |
| 关于 | 版本与运行环境（从 `bundleManager` 实时读包名 / 版本）、数据来源说明、免责声明 |

---

## 二、能跑哪些站点

关键看配置里 `sites[].type` 和 `sites[].api`：

| 配置长相 | 能否运行 | 说明 |
|---|---|---|
| `"api": "https://xxx.com/api.php/provide/vod"` | ✅ | 苹果CMS V10 JSON 协议，本工程已实现 |
| `"api": "http://..."` | ✅ | 已通过 `network_config.json` 放行明文 HTTP |
| `"api": "csp_xxx"` / `js:...` / 带 `spider` jar | ❌ | 依赖 Android 侧的 `spider.jar` 运行时，鸿蒙没有 JVM，**无法执行** |

所以 `type 3 / 4`、`csp_*`、js/jar 这类站点会在加载配置时被**直接过滤**，不会列出来。

此外还有一种不进 TVBox 配置的站源：**Kazumi 规则**（下面单独一节）。

---

## 三、Kazumi 规则站（重点）

[Predidit/KazumiRules](https://github.com/Predidit/KazumiRules) 是另一个生态里的规则集：一条 JSON 描述
「怎么搜、片名/链接在哪个字段、剧集从哪来」。它刚好能补上 TVBox 的缺口 —— 大量番剧 / 影视站
既没有苹果CMS 接口，也不是 spider 型，只提供网页。

### 怎么加

设置页「点播源」卡片最下面有一行 **Kazumi 规则**，一个输入框三种吃法，回车（或点「载入」）即生效：

| 填什么 | 例子 |
|---|---|
| 规则名 | `giriGiriLove` |
| 规则链接 | `https://raw.githubusercontent.com/Predidit/KazumiRules/main/giriGiriLove.json`（GitHub blob 链接会自动转 raw） |
| 整段规则 JSON | 直接粘贴 `{ "name": "...", "searchURL": "..." }` |

规则名**不区分大小写**：先按原样去 GitHub raw 与 jsdelivr 两个镜像取，取不到就拉一次官方规则库的
文件清单（走 jsdelivr 包索引，进程内缓存），忽略大小写找到真名再重试 —— 所以 `girigirlove`、
`GIRIGIRILOVE` 都能命中。载入成功后规则会**收进 Default 资源站并直接切为当前站点**，重启仍在；
同一条规则重复添加按 `kazumi://<host>` 认定，不会堆出两个重复站点。

### 支持哪几种规则

规则之间差别很大，本工程的判定与支持度如下（`KazumiRuleApi.isApiRule / isXPathRule / isNested`）：

| 规则形态 | 判定 | 搜索 · 详情 · 选集 | 播放 |
|---|---|---|---|
| 纯 XPath（网页规则） | 有 `searchURL + searchList + searchResult`，没有 `searchAPI` | 隐藏 WebView 里对真页面求 XPath | 嗅探 |
| `api + xpath` | 有 `searchAPI`，剧集是播放页链接 | 列表走 JSON，选集解开页面取链接 | 嗅探 |
| `api + api`，`chapterFormat: delimited` | 剧集字段直接给 m3u8 串 | 全 JSON，**不经过 WebView** | 直链，最快 |
| `api + api`，`chapterFormat` 缺省（nested） | 剧集字段给的是播放页 | 全 JSON | 嗅探 |

字段默认值按 Kazumi 的 `ApiChapterConfig` 对齐（`format` 缺省 = nested、roadsPath `$.data.roads[*]`、
`episodeUrlPath` `$.url` 等），否则像只写了两个路径的规则一条线路都拼不出来。

### 分类是怎么来的

Kazumi 的规则格式里**根本没有分类字段**，所以按两条路补：

1. **站点网页分类**（MacCMS 系）：`/vodshow/{type}--------@page---.html` 这套地址服务端直出 HTML，
   隐藏 WebView 求 XPath 就能拿到列表与海报，滚动到底按 MacCMS 分页公式翻页。
   ⚠️ 这一路需要一份「分类 → 列表地址 + 四个 XPath」的映射，**开源版 `utils/RuleCategories.ets`
   的 `PRESETS` 是空的**（本工程不预置任何站点），所以默认只显示搜索、没有分类条；
   照该文件里的注释填一条就能启用。
2. **后端分类**（自动）：不少 m3u8 站的后端是自建 Vod API，把搜索地址里的 `/get_list` 换成
   `/get_class` 就是分类名列表，浏览时复制搜索请求、去掉搜索词、加 `vod_class`、按 `offset` 翻页。
   这条不需要任何配置，规则里带 `get_list` 就自动铺出分类栏（最前面补「全部」），总数直接显示。
   注意只认 `vod_class`：`type_id` / `class` / `cate` 实测都不起作用。

优先级：网页分类映射 > 后端分类 > 普通 CMS 接口。两者都没有时安静退回搜索。

### 三件必须做对的事

1. **网页一律用桌面 UA**。番剧站按 UA 分流，移动端 UA 会拿到手机版模板甚至直接 302，
   而规则里的 XPath 是作者在桌面浏览器按 PC 版 DOM 写的 —— 用默认 UA 会全落空。
2. **XPath 相对求值**。取片名 / 链接这类子项只允许 `"." + xpath` 在容器内求值，
   绝不退回绝对路径：`roads` 那种 XPath 会连页面标题栏一起匹配，一退回就把整站导航当剧集。
   只有顶层 `list / roads` 才允许「相对优先、空了退绝对」。
3. **macCMS 播放页先静态解**。页面里通常有 `var player_aaaa={...,"encrypt":2,"url":"..."}`，
   按 `encrypt` 0 / 1 / 2 处理（2 = base64 → percent decode）比嗅探快一个数量级；
   解出来还是网页就再抓一层（本站播放页 → 上游站播放页）。

### 播放：嗅探兜底

拿不到直链时，播放页会挂一个 2×2、透明度 0.01 的隐藏 WebView（`components/SniffWeb`）：文档开始就注入
脚本，劫持 `XHR` / `fetch`、包装 `Response.text` 判断 `#EXTM3U`、用 `MutationObserver` 扫
`video / iframe`，扫到的流地址与 `Referer` 一起回传（`__kzRef`）。起播时把 Referer 透传给播放器；
但 `dis_k=`、`x-amz-`、`auth_key=` 这类**自签名直链反而不能带 Referer**（参数里已含鉴权，
带上会命中防盗链，实测裸请求 200、带 Referer 404），由 `PlayUrlResolver.isSelfSigned()` 判定后传空。

嗅探是有代价的：这类站点起播比直链慢 5~10 秒，属正常。

### 规则站已知限制

- **要登录才能播的站跑不动**（页面写「登录后即可观看」那种）—— 客户端没有账号体系。
- **规则被标 deprecated 的别用**，通常是站点已改版或换域名。
- **纯 SPA 且没有 API 的站抓不到**：`ani.xxx.com` 这类 React SPA 的 HTML 只有几 KB 空壳，
  内容全由 JS 渲染，XPath 拿不到东西；除非它有 `get_list` 这类后端接口（那就是上面的「后端分类 + JSON」路径）。
- **规则里不带分类也不带 `get_list`** 时，就只有搜索，没有分类栏。

---

## 四、编译运行

**环境**

- DevEco Studio（配套 HarmonyOS SDK，本工程 `compatibleSdkVersion = 6.1.1(24)`）
- 设备：`deviceTypes: ["tv"]`，即智慧屏 / 电视；手机和平板默认装不上

**步骤**

1. 用 DevEco Studio 打开本目录；
2. 首次打开会提示未配置签名 —— 点 **自动签名**（`File > Project Structure > Signing Configs > Automatically generate signature`），
   这一步会用你自己的华为开发者账号生成调试证书与 Profile；仓库里**故意不含任何签名配置**；
3. 连上设备后直接运行。

命令行编译（需先按上面的方式配好签名）：

```bash
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物在 `entry/build/default/outputs/default/entry-default-signed.hap`。

> 鸿蒙 HAP **不能点击安装**，必须用 `hdc install -r <hap>` 或 DevEco Studio 安装。
> 调试包绑定了你账号下登记的设备 UDID，换设备需要重新自动签名。

---

## 五、首次使用

打开 App 后首页会提示「还没有配置片源」，点「去设置」：

1. 在「点播源」填一个配置地址（例如你自己的苹果CMS 接口，或一份 `{"sites":[...]}` 配置）；
2. 需要直播就单独填「直播源」，可填 m3u / txt / 带 `lives` 的配置；
3. 载入后回首页即可浏览。

想用规则站就不必找配置地址：点播源卡片底部的 **Kazumi 规则** 里填规则名（如 `giriGiriLove`）
回车即可，规则会收进 Default 并直接切过去（见第三节）。

也可用「手机推送」：点电视上的「手机推送」出二维码，手机扫码在网页里粘贴地址
（规则也可以这样推：规则那一行的「手机推送」选「Kazumi 规则」）。

---

## 六、已知限制

- **灵犀指向式遥控器（空鼠）在播放页收不到标准按键事件**：方向键、OK 键都到不了播放页。
  播放页的操作请用光标点控制条按钮；画面**长按**可播放 / 暂停，点一下显隐控制条。
  `Player.ets` 的 `handleKey()` 保留了完整的方向键 / 媒体键映射，换普通红外或蓝牙遥控器即生效。
- **MKV 内嵌字幕不显示，也无法切换内嵌音轨**：当前只把地址交给 AVPlayer 按默认轨播放。
  SDK 的字幕事件只对外挂字幕触发，且外挂字幕接口要求本地 fd，网络直链走不通。
- **不支持 spider 型站点**（见第二节）。
- **Kazumi 规则站有几类站跑不动**：需要登录才能播的、规则已标 deprecated 的、纯 SPA 又没有后端接口的
  （详见第三节「规则站已知限制」）。这类站起播要靠嗅探，比直链慢 5~10 秒。
- 豆瓣未登录时搜索配额较紧，补图较慢；设置页可填 Cookie 登录（自备账号）。

---

## 七、目录结构

```
entry/src/main/ets/
├── pages/          Home 首页 / Index 点播 / Live 直播 / Detail 详情 / Player 播放
│                   Search 搜索 / My 收藏 / History 历史 / Settings 设置 / About 关于
├── components/     SideNav 侧栏 / PosterCard 海报卡 / QrView 二维码
│                   SniffWeb 隐藏嗅探页（2×2 透明）/ PinPad 家长锁键盘
├── model/          TvBoxModels 配置模型 / VodItem 影片
└── utils/          ConfigStore 配置链路 / ConfigParser 解析 / SiteApi 采集站协议
                    KazumiRuleApi 规则站（取规则 / 搜索 / 分类 / 选集）
                    WebSniffer 隐藏 WebView 求值与流嗅探 / RuleCategories 网页分类映射
                    MacCmsPlayer macCMS 播放页静态解
                    LiveApi 直播解析 / PosterStore 刮削 / BackdropStore 横版剧照
                    RatingStore 评分 / PinStore 家长锁 / PlayProgress 进度
                    PushServer 手机推送
```

配置 JSON 的字段含义与原版 TVBox 一致，`model/TvBoxModels.ets` 里有完整注释。

---

## 八、免责声明

- 本工程**只提供客户端软件**，不提供、不托管、不推荐任何影视内容、采集接口或直播源。
- 仓库内不含任何第三方内容源地址。使用者自行填入的地址与本工程作者无关。
- 请遵守你所在地区的法律法规，仅将本软件用于你有权访问的内容。
- 软件按「现状」提供，不附带任何明示或暗示的担保。

## 许可

Apache License 2.0，见 [LICENSE](LICENSE)。
