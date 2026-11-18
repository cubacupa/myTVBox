import { router } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { KeyCode } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PlayProgress } from '../utils/PlayProgress';
import { PlayUrlResolver } from '../utils/PlayUrlResolver';
import { PosterStore } from '../utils/PosterStore';
import { RatingStore } from '../utils/RatingStore';
import { LiveMarkStore } from '../utils/LiveMarkStore';
import { LocalPrefetch } from '../utils/LocalPrefetch';
import { AppState } from '../utils/AppState';
import { SniffWeb } from '../components/SniffWeb';
import { sniffer } from '../utils/WebSniffer';

const DOMAIN: number = 0x0000;
const TAG: string = 'TVBoxPlayer';
const SPEEDS: number[] = [1.0, 1.25, 1.75, 2.0];
/**
 * 快进退：短按一次 60s；按住超过 SEEK_HOLD_MS 进入「预览找点」，
 * 期间完全不 seek，每 SEEK_TICK_MS 走一格（同样 60s），屏幕中间实时显示目标时间，
 * 松手才真正跳一次。固定步进不做加速：预览模式下越按越快很容易一下冲过片尾，
 * 1 分钟 / 300ms 约等于 1 秒扫 3 分钟片长，45 分钟的剧集按住 3 秒能走 10 分钟，
 * 够快也还能微调。
 */
const SEEK_BASE: number = 60000;
const SEEK_STEP: number = 60000;
const SEEK_HOLD_MS: number = 450;
const SEEK_TICK_MS: number = 300;
/** Up 事件偶发丢失时的兜底：最多预览 40 格（12 秒）就自动收口并跳转 */
const SEEK_MAX_TICKS: number = 40;
/**
 * 主动 seek 后的缓冲豁免窗口（毫秒）。
 * AVPlayer seek 完必须重新拉目标位置的分片、必然抛 BUFFERING_START，
 * 这是预期行为而非网络卡顿。4 秒足够覆盖一次正常的重新缓冲，
 * 超时还没缓出来才按真卡顿计；连续快进会不断刷新这个窗口。
 */
const SEEK_BUFFER_GRACE_MS: number = 4000;
/** 长按 OK 判定为「播放/暂停」的时长（仅普通方向键遥控器；灵犀遥控器的 KeyEvent 到不了播放页） */
const OK_LONG_MS: number = 600;
/** 长按画面空白判定为「播放/暂停」的时长：触摸事件在灵犀遥控器上是可靠的 */
const SCREEN_LONG_MS: number = 500;
/** 控制栏自动隐藏延时 */
const UI_HIDE_MS: number = 5000;

interface PlayerParams {
  url: string;
  title: string;
  flag: string;
  progId: string;
  isLive: boolean;
  /** 直播：同一频道的全部线路（源站常给同频道好几条地址） */
  lines?: string[];
  /** 直播：从第几条线路开始（直播页会优先放「上次能放的」那条） */
  lineIdx?: number;
  /** 直播：频道身份（tvg-id 或频道名），用来记住「最后能放的线路」 */
  liveKey?: string;
  /** 点播剧集：整条线路的全部集地址（多集时带，用于控制条上的上/下集） */
  eps?: string[];
  /** 点播剧集：与 eps 一一对应的集名（"第01集"） */
  epNames?: string[];
  /** 点播剧集：当前播的是第几集（0 起） */
  epIdx?: number;
  /** 点播剧集：每集 progId 的前缀（siteKey_vodId_线路名_），切集时拼播放进度用 */
  progBase?: string;
  /** 点播剧集：片名，切集后重建标题「片名 · 集名」 */
  nameBase?: string;
}

/**
 * 播放页：支持点播 / 直播。
 *
 * 交互（本机遥控器是「指向式」air mouse：方向键被系统转成光标移动，OK 转成鼠标点击，
 * 应用侧收不到任何 KeyEvent，所以控制必须走指针语义，不能靠焦点导航）：
 *   移动遥控器   → 光标移动，按钮高亮
 *   点按钮       → 执行（播放/暂停、快退、快进、倍速、退出）
 *   长按快退/快进 → 不真跳，屏幕中间实时显示目标时间，松手才跳一次
 *   点空白       → 显隐控制层（片名 / 进度条 / 按钮）
 *   返回键       → 保存进度退出
 *
 * 键盘/按键路径仍然保留（handleKey），以便换成带方向键的遥控器时可直接用。
 */
@Entry
@Component
struct Player {
  private xcController: XComponentController = new XComponentController();
  @State surfaceId: string = '';
  @State title: string = '';
  @State isPlaying: boolean = false;
  @State resolving: boolean = false;
  @State curTime: number = 0;
  @State durTime: number = 0;
  @State speedIdx: number = 0;
  @State isLive: boolean = false;
  @State errMsg: string = '';
  /**
   * 是否已经真正播起来过。
   *
   * 以前 UI 只有「解析中 / 有错误 / 否则=已暂停」三态，于是从解析完成到
   * prepare+play 成功这几秒（真机实测有 19 秒的）会显示「已暂停」，
   * 让人以为是自己按错了。现在多一个连接中状态，只有播起来之后停住才叫暂停。
   */
  @State connecting: boolean = true;
  /** 直链预取进度（0-100）：-1 表示当前不走预取，界面不显示 */
  @State fetchPct: number = -1;
  /** 直播线路序号（1 起）与总数，用于「线路 2/5」和换线路按钮 */
  @State lineNo: number = 1;
  @State lineCount: number = 0;
  /** 控制层（片名 / 进度条 / 按钮）是否显示 */
  @State uiVisible: boolean = true;
  /** 快进快退、倍速这类操作的即时提示，独立于控制层 */
  @State tipText: string = '';
  /** 长按快进退的居中大提示：主行目标时间、副行偏移量；独立于 tipText 与控制层 */
  @State seekPreviewOn: boolean = false;
  @State seekPreviewMain: string = '';
  @State seekPreviewSub: string = '';
  // ---- 遥控器是「光标 / 鼠标」语义：用指针事件驱动 ----
  /** 当前光标悬停的按钮 key，用于高亮反馈（air mouse 一定要有视觉反馈） */
  @State hoverKey: string = '';
  /** 「实际大小 / 全屏」：true = 画面按片源原始像素 1:1 显示（XComponent 缩到视频宽高） */
  @State actualSize: boolean = false;
  /** 片源原始分辨率（物理像素）；0 = 拿不到，此时不允许切实际大小 */
  @State videoW: number = 0;
  @State videoH: number = 0;
  private player: media.AVPlayer | null = null;
  private rawUrl: string = '';
  /** 点播多集：整条线路的地址 / 集名，上/下集就靠这两个数组切（直播不填） */
  private epUrls: string[] = [];
  private epNames: string[] = [];
  private progBase: string = '';
  private nameBase: string = '';
  /** 当前集序号（0 起）；-1 = 没有剧集信息，控制条不显示上/下集 */
  @State epIdx: number = -1;
  @State epCount: number = 0;
  private playUrl: string = '';
  private flag: string = '';
  private progId: string = '';
  private preparedReady: boolean = false;
  private surfaceReady: boolean = false;
  private started: boolean = false;
  /** 有一次跳转正在等本地缓存追上：期间不再接受新的跳转，避免连环 seek */
  private pendingSeek: boolean = false;
  /** 预取到本地的文件：路径与文件句柄（播放器要用 fdSrc 播它） */
  private localPath: string = '';
  private localFd: number = -1;
  private inited: boolean = false;
  private prepareCalled: boolean = false;
  private savedProgress: number = 0;
  /** 最近一次「一集播完」的时间戳：completed 会重复上报，用它去重，免得连跳两集 */
  private completedTs: number = 0;
  /** 本集是否已经处理过「播完」：切集时归零。没有它，最后一集会每 1.5s 重新提示一次 */
  private completedFired: boolean = false;
  private timer: number = -1;
  private ctx: common.Context | null = null;

  // ---- 按键状态 ----
  private holdKey: number = 0;        // 当前按住的左右方向（-1 左 / 1 右 / 0 无）
  private holdLong: boolean = false;  // 是否越过判定阈值、进入「预览找点」
  private holdBase: number = 0;       // 按下瞬间的播放位置（目标以它为基准，不随播放漂移）
  private holdTarget: number = 0;     // 当前预览目标时间
  private holdTicks: number = 0;
  private holdDelayTimer: number = -1; // 短按 / 长按判定
  private holdTimer: number = -1;      // 预览步进
  private previewHideTimer: number = -1;
  /** 最近一次快进退松手的时间戳，用于抑制长按松开后紧跟的 onClick 重复跳 */
  private lastSeekEndTs: number = 0;
  /** 最近一次点击按钮的时间戳：ClickEvent 不能 stopPropagation，用它把冒泡到根容器的点击排除掉 */
  private lastBtnTapTs: number = 0;
  /** 同一次点击可能被「控制层」和「透明点击层」各收一次，用它去重 */
  private lastTapTs: number = 0;
  private okTimer: number = -1;
  private okLongFired: boolean = false;
  /** 画面长按：短按显隐 / 长按播放暂停 */
  private screenHoldTimer: number = -1;
  private screenLongFired: boolean = false;
  private lastSpeedTs: number = 0;
  private uiTimer: number = -1;
  private tipTimer: number = -1;
  /** 进度条可点击区域的实际宽度(vp)：把 ClickEvent.x 换算成目标时间 */
  private barWidth: number = 0;
  /** 最近一次点进度条的时间戳：touch / mouse / click 可能重复到达，用它去重 */
  private lastBarTapTs: number = 0;
  /** setPlaybackStrategy 完成前不能 prepare（策略只允许在 initialized 状态设置） */
  private strategyReady: boolean = false;
  /** 30s 窗口内的缓冲次数，用于提示换线路 */
  private bufferStalls: number = 0;
  private firstStallTs: number = 0;
  /** 本次播放缓存水位的峰值(ms)：用来判断 20 秒水箱到底蓄起来过没有 */
  private cachePeak: number = 0;
  /** 同一次卡顿会被拆成多个 BUFFERING_START，1.5s 内只算一次 */
  private lastStallTs: number = 0;
  /** 主动 seek 引起的预期缓冲，豁免到这个时刻为止（见 markUserSeek） */
  private seekBufferUntilTs: number = 0;
  /** 直播多线路：同一频道的全部地址，以及当前用第几条 */
  private liveUrls: string[] = [];
  private linePos: number = 0;
  /** 频道身份，用于记住「最后能放的线路」 */
  private liveKey: string = '';
  /** 本次进入已经自动试过几条线路，避免在全部是死链时无限重试 */
  private autoTried: number = 0;
  /** 播放器代次：换线路会重建 AVPlayer，旧实例的异步回调必须丢掉 */
  private gen: number = 0;
  /** 连接看门狗：prepare 卡住时 AVPlayer 可能几十秒都不报错 */
  private watchdog: number = -1;

  aboutToAppear(): void {
    const p = router.getParams() as PlayerParams;
    this.rawUrl = p.url ?? '';
    this.title = p.title ?? '';
    this.flag = p.flag ?? '';
    this.isLive = p.isLive ?? false;
    this.progId = p.progId ?? '';
    // 直播多线路：直播页把同一频道的所有地址一起带过来
    const ls: string[] | undefined = p.lines;
    if (this.isLive && ls !== undefined) {
      for (const u of ls) {
        if (typeof u === 'string' && u.startsWith('http')) {
          this.liveUrls.push(u);
        }
      }
    }
    if (this.liveUrls.length === 0 && this.rawUrl.length > 0) {
      this.liveUrls.push(this.rawUrl);
    }
    const at: number = p.lineIdx ?? 0;
    this.linePos = (at >= 0 && at < this.liveUrls.length) ? at : 0;
    this.lineCount = this.liveUrls.length;
    this.lineNo = this.linePos + 1;
    this.liveKey = p.liveKey ?? '';
    // 点播多集：详情页把整条线路一起带过来，切集不用再回详情页拉一次接口
    const eu: string[] | undefined = p.eps;
    const en: string[] | undefined = p.epNames;
    if (!this.isLive && eu !== undefined) {
      for (const u of eu) {
        if (typeof u === 'string' && u.length > 0) {
          this.epUrls.push(u);
        }
      }
      if (en !== undefined) {
        for (const n of en) {
          this.epNames.push(typeof n === 'string' ? n : '');
        }
      }
      while (this.epNames.length < this.epUrls.length) {
        this.epNames.push('');
      }
      this.epCount = this.epUrls.length;
      const ei: number = p.epIdx ?? -1;
      this.epIdx = (ei >= 0 && ei < this.epCount) ? ei : -1;
      this.progBase = p.progBase ?? '';
      this.nameBase = p.nameBase ?? '';
    }
    const ctx = getContext(this) as common.Context;
    this.ctx = ctx;
    // 播放期间停掉后台刮削：豆瓣评分 / 按名搜索 / 海报下载都会跟视频分片抢带宽
    PosterStore.pause();
    RatingStore.pause();
    this.prepareAndStart();
  }

  /**
   * 按线路名匹配解析接口；没有匹配则退到第一个「有效」的解析。
   * 配置里的 parses 常有 {"name":"Json聚合","url":"Demo"} 这类占位项，
   * 必须过滤掉，否则会拼出 Demohttps://... 这种非法地址，播放器报 unsupported type。
   */
  private pickJx(): string {
    if (PlayUrlResolver.isDirect(this.rawUrl)) {
      return '';
    }
    const flag = (this.flag ?? '').toLowerCase();
    if (flag) {
      for (const p of AppState.cfg.parses) {
        if (PlayUrlResolver.isValidJx(p.url) && p.flags.length > 0 && p.flags.includes(flag)) {
          return p.url;
        }
      }
    }
    for (const p of AppState.cfg.parses) {
      if (PlayUrlResolver.isValidJx(p.url)) {
        return p.url;
      }
    }
    return '';
  }

  private async prepareAndStart(): Promise<void> {
    if (this.isLive && this.linePos >= 0 && this.linePos < this.liveUrls.length) {
      // 换线路时也走这里：当前线路地址就是这次要播的地址
      this.rawUrl = this.liveUrls[this.linePos];
    }
    this.connecting = true;
    if (!this.isLive && this.ctx !== null && this.progId) {
      this.savedProgress = await PlayProgress.get(this.ctx, this.progId);
      // 每次起播都记一笔：详情页据此把看过的集标暗、把最近一集标出来。
      // 换上/下集也走 prepareAndStart，所以这一处就够了。
      PlayProgress.mark(this.ctx, this.progId).catch(() => {});
    }
    // 非直链、也没有可用解析接口时，解析器会去抓网页 / 猜 index.m3u8，需要时间
    const needResolve: boolean = !PlayUrlResolver.isDirect(this.rawUrl);
    this.resolving = needResolve;
    let playUrl = this.rawUrl;
    try {
      if (needResolve) {
        playUrl = await PlayUrlResolver.resolve(this.rawUrl, this.pickJx());
      } else {
        // 直链也过一遍：接口/规则站给的地址可能把 ? 写成了 &
        playUrl = PlayUrlResolver.normalizeMediaUrl(this.rawUrl);
      }
    } catch (e) {
      this.resolving = false;
      this.connecting = false;
      this.errMsg = '解析播放地址失败：' + (e as Error).message + '\n原始地址：' + this.rawUrl;
      return;
    }
    this.resolving = false;
    if (!playUrl) {
      this.connecting = false;
      this.errMsg = '这条线路取不到播放地址，换一条线路试试\n' + this.rawUrl;
      return;
    }
    this.playUrl = playUrl;
    let target: string = playUrl;
    if (!this.isLive && this.ctx !== null && LocalPrefetch.canPrefetch(playUrl)) {
      target = await this.prefetchLocally(playUrl);
    } else {
      LocalPrefetch.cancel();
      this.fetchPct = -1;
    }
    await this.initPlayer(target);
  }

  /**
   * 直链 mp4 先拉到本地再播。
   *
   * 这类签名直链的 CDN 卡的是「请求次数」：一次要 24MB 没问题，
   * 一分钟要十几次就 403（等一分钟才恢复）。播放器正好是按小块狂要的那种，
   * 于是播一两分钟就断流、每帧报 stream is unsupported。
   * 换成 App 自己用几次大块请求拉下来，播放器只读本地文件，问题就不存在了。
   *
   * 拉不到就回落成网络直连，功能不因此变差。
   */
  private async prefetchLocally(url: string): Promise<string> {
    const ctx: common.Context | null = this.ctx;
    if (ctx === null) {
      return url;
    }
    this.fetchPct = 0;
    try {
      const path: string = await LocalPrefetch.begin(ctx, url,
        (done: number, total: number) => {
          this.fetchPct = total > 0 ? Math.min(99, Math.round(done * 100 / total)) : 0;
        });
      this.fetchPct = -1;
      hilog.info(DOMAIN, TAG, 'prefetch ready: %{public}s', path);
      return path;
    } catch (e) {
      this.fetchPct = -1;
      hilog.warn(DOMAIN, TAG, 'prefetch failed, fallback to network: %{public}s',
        (e as Error).message);
      return url;
    }
  }

  private async initPlayer(url: string): Promise<void> {
    const isLocal: boolean = url.startsWith('/');
    if (!PlayUrlResolver.isHttpUrl(url) && !isLocal) {
      // 交给 AVPlayer 只会得到 "unsupported type"，先拦下来给出可读原因
      this.connecting = false;
      this.errMsg = '播放地址不是 http(s) 链接，播放器无法识别：\n' + url;
      return;
    }
    try {
      // 换线路会重建播放器：用代次号让旧实例的异步回调全部失效
      this.gen++;
      const g: number = this.gen;
      const p: media.AVPlayer = await media.createAVPlayer();
      if (g !== this.gen) {
        p.release().catch(() => {});
        return;
      }
      this.player = p;
      p.on('stateChange', (state: string) => {
        if (g !== this.gen) {
          return;
        }
        hilog.info(DOMAIN, TAG, 'state: %{public}s', state);
        if (state === 'initialized') {
          this.inited = true;
          // 策略只允许在 initialized 状态设置，且必须设完再 prepare；
          // prepare 太早还会报 "Please obtain the surface from XComponentController"
          this.applyStrategyAndPrepare();
        } else if (state === 'prepared') {
          this.preparedReady = true;
          this.errMsg = '';
          try {
            this.durTime = p.duration;
          } catch (e) {
            this.durTime = 0;
          }
          this.applyScaleMode();
          this.tryPlay();
        } else if (state === 'playing') {
          this.errMsg = '';
          this.isPlaying = true;
          this.connecting = false;
          this.clearWatchdog();
          this.rememberLine();
        } else if (state === 'paused' || state === 'completed'
          || state === 'stopped' || state === 'idle') {
          // 由播放器自己转的状态（片尾结束、系统打断）也要同步，否则按钮文字会错
          this.isPlaying = false;
          if (state === 'completed') {
            this.onCompleted();
          }
        }
      });
      p.on('error', (err: BusinessError) => {
        if (g !== this.gen) {
          return;
        }
        hilog.error(DOMAIN, TAG, 'player error: %{public}s / code %{public}d', err.message, err.code);
        // 401 = surface 还没就绪，重新走一次「挂 surface + prepare」
        if (err.code === 401 && this.surfaceId && this.inited && this.prepareCalled) {
          this.prepareCalled = false;
          this.attachSurfaceAndPrepare();
          return;
        }
        this.onPlayFail(url, err.message, String(err.code));
      });
      // 缓冲诊断：区分「网络断档」和「解码慢」，并在频繁缓冲时提示换线路
      this.player.on('bufferingUpdate', (type: media.BufferingInfoType, value: number) => {
        if (type === media.BufferingInfoType.BUFFERING_START) {
          // 起播预缓冲阶段 currentTime 还是 -1/0，AVPlayer 会在几十毫秒内
          // 连抛多次 START/END（真机实测同毫秒 6 次）。这不是卡顿，计入 stall
          // 会立刻误报「频繁缓冲，建议换线路」，还会弹提示挡住刚出来的画面。
          if (this.curTime <= 0) {
            hilog.info(DOMAIN, TAG, 'buffer prime at start (ignored)');
            return;
          }
          const now: number = Date.now();
          // 主动跳转（快进/快退/点进度条/续播起跳）后重新拉流抛出的 START 是预期缓冲：
          // 不计入 stall、也不弹「网络缓冲中…」盖掉「快进 60 秒」/「跳转至 mm:ss」。
          // 窗口内即使被拆成多个 START 也一律豁免；超时仍在缓冲才按真卡顿处理。
          if (now < this.seekBufferUntilTs) {
            hilog.info(DOMAIN, TAG, 'buffer after user seek (ignored) at %{public}dms',
              this.curTime);
            return;
          }
          this.seekBufferUntilTs = 0;
          // 一次卡顿常被拆成多个 START，1.5s 内只算一次
          if (now - this.lastStallTs < 1500) {
            return;
          }
          this.lastStallTs = now;
          if (now - this.firstStallTs > 30000) {
            this.firstStallTs = now;
            this.bufferStalls = 0;
          }
          this.bufferStalls++;
          hilog.info(DOMAIN, TAG, 'buffer START #%{public}d at %{public}dms',
            this.bufferStalls, this.curTime);
          if (this.bufferStalls >= 3) {
            this.bufferStalls = 0;
            this.showTip('这条线路频繁缓冲，建议返回换一条线路');
          } else {
            this.showTip('网络缓冲中…');
          }
        } else if (type === media.BufferingInfoType.BUFFERING_END) {
          hilog.info(DOMAIN, TAG, 'buffer END at %{public}dms (peak %{public}dms)',
            this.curTime, this.cachePeak);
        } else if (type === media.BufferingInfoType.CACHED_DURATION) {
          // 记峰值：只按「跨过整秒」打点，既能看出水位到底到过多少，又不会刷屏
          if (value > this.cachePeak) {
            const grew: boolean = Math.floor(value / 1000) > Math.floor(this.cachePeak / 1000);
            this.cachePeak = value;
            if (grew) {
              hilog.info(DOMAIN, TAG, 'buffer peak: %{public}dms', value);
            }
          }
          if (value < 3000) {
            // 剩余可播时长不足 3 秒，快见底了
            hilog.info(DOMAIN, TAG, 'buffer low: %{public}dms', value);
          }
        }
      });
      // 抓来的流地址大多验 Referer（直接请求会 410），把嗅探时记录的页面带上。
      // 例外：带签名的 CDN 直链（腾讯 dis_k、天翼云 X-Amz-* 等）鉴权已在 URL 里，
      // 再带 Referer 反而命中防盗链返回 404（播放器报 5411007），实测确认。
      const ref: string = PlayUrlResolver.isSelfSigned(url) ? '' : sniffer.refererOf(url);
      if (isLocal) {
        // 本地预取文件：AVPlayer 的 url 只认网络地址或 fd://，本地文件必须走 fdSrc
        this.closeLocalFd();
        const f: fs.File = fs.openSync(url, fs.OpenMode.READ_ONLY);
        this.localPath = url;
        this.localFd = f.fd;
        let size: number = 0;
        try {
          size = fs.statSync(url).size;
        } catch (e) {
          size = 0;
        }
        const src: media.AVFileDescriptor = { fd: f.fd, offset: 0, length: size };
        p.fdSrc = src;
        hilog.info(DOMAIN, TAG, 'play local, %{public}d bytes', size);
      } else if (ref.length > 0) {
        const hs: Record<string, string> = JSON.parse('{}') as Record<string, string>;
        hs['Referer'] = ref;
        try {
          const src: media.MediaSource = media.createMediaSourceWithUrl(url, hs);
          // 这版 SDK 的 setMediaSource 实际返回 undefined，不能直接 .catch
          const pr: Object | undefined = p.setMediaSource(src) as Object | undefined;
          if (pr !== undefined && pr !== null) {
            (pr as Promise<void>).catch((e: BusinessError) => {
              hilog.error(DOMAIN, TAG, 'setMediaSource failed: %{public}s / %{public}d',
                e.message, e.code);
            });
          }
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'createMediaSource threw: %{public}s', (e as Error).message);
          p.url = url;
        }
      } else {
        p.url = url;
      }
      // 直播也跑计时器：curTime 用来分辨「起播预缓冲」和「真卡顿」，
      // 顺便让直播中途的缓冲提示也能出来
      this.startTimer();
      // 保底：onLoad 有时晚于 initialized，定时再查一次 surface
      setTimeout(() => {
        if (g === this.gen) {
          this.attachSurfaceAndPrepare();
        }
      }, 400);
      // prepare 卡死时 AVPlayer 可能几十秒都不报错（真机见过 19 秒没动静），
      // 用看门狗兜住。只给直播用：点播的 prepare 偶发慢一点但能成功，
      // 用超时去判死会把「慢但能放」误判成失败。
      if (this.isLive) {
        this.startWatchdog();
      }
    } catch (e) {
      this.connecting = false;
      this.errMsg = '初始化播放器失败：' + (e as Error).message + '\n地址：' + url;
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', (e as Error).message);
    }
  }

  // ---------------- 直播多线路 ----------------

  /**
   * 一次「这条播不出来」的收口。
   *
   * 直播源里同一频道常挂 5 条地址，其中几条早就失效（真机日志：找不到主机、
   * IO 错误、容器格式不支持）。以前每条都要用户手动返回、再点下一个同名格子，
   * 现在就自动顺着往下试，试到能放为止；全试完才报错。
   */
  private onPlayFail(url: string, msg: string, code: string): void {
    this.clearWatchdog();
    if (this.isLive && this.liveUrls.length > 1
      && this.autoTried < this.liveUrls.length - 1) {
      this.autoTried++;
      const next: number = (this.linePos + 1) % this.liveUrls.length;
      this.showTip('这条线路连不上，自动换下一条（' + (next + 1) + '/' + this.liveUrls.length + '）');
      hilog.info(DOMAIN, TAG, 'line %{public}d failed, try %{public}d', this.linePos + 1, next + 1);
      this.restartAt(next, false);
      return;
    }
    this.connecting = false;
    this.resolving = false;
    this.errMsg = '播放出错：' + msg + (code.length > 0 ? '（code ' + code + '）' : '') + '\n'
      + '地址：' + url + '\n'
      + (this.isLive
        ? '这个频道的 ' + this.liveUrls.length + ' 条线路都试过了，返回换个频道试试'
        : '可返回上一页换一条线路，或换一个站点再试');
  }

  /** 换成第 pos 条线路重新起播 */
  private restartAt(pos: number, manual: boolean): void {
    if (pos < 0 || pos >= this.liveUrls.length) {
      return;
    }
    this.linePos = pos;
    this.lineNo = pos + 1;
    if (manual) {
      this.autoTried = 0;
    }
    this.releasePlayer();
    // 整族「准备状态」都要重置，否则 inited/prepareCalled 这些幂等守卫
    // 会把第二次初始化直接挡掉，表现为换线路后永远黑屏
    this.inited = false;
    this.strategyReady = false;
    this.prepareCalled = false;
    this.preparedReady = false;
    this.started = false;
    this.isPlaying = false;
    this.connecting = true;
    this.errMsg = '';
    this.resolving = false;
    this.durTime = 0;
    this.curTime = 0;
    this.videoW = 0;   // 新线路分辨率要重新取，取不到就退回适应屏幕
    this.videoH = 0;
    // 新线路重新观察，别把上一条线路攒下的 stall 次数带过来凑够 3 次误报
    this.bufferStalls = 0;
    this.firstStallTs = 0;
    this.lastStallTs = 0;
    this.cachePeak = 0;
    this.seekBufferUntilTs = 0;
    this.rawUrl = this.liveUrls[pos];
    this.playUrl = '';
    hilog.info(DOMAIN, TAG, 'switch to line %{public}d/%{public}d',
      this.linePos + 1, this.liveUrls.length);
    this.initPlayer(this.rawUrl);
  }

  private switchLine(): void {
    if (!this.isLive || this.liveUrls.length <= 1) {
      return;
    }
    this.restartAt((this.linePos + 1) % this.liveUrls.length, true);
    this.showTip('线路 ' + this.lineNo + '/' + this.lineCount);
  }

  /** 是否显示/允许上/下集：多集且当前集定位成功 */
  private canSwitchEp(): boolean {
    return this.epCount > 1 && this.epIdx >= 0;
  }

  /**
   * 一集播完：多集剧自动接下一集；电影（单条链接）和最后一集什么都不做。
   *
   * completed 会被重复上报（同一个实例连抛多次），1.5 秒内只处理一次；
   * 切集后旧实例的代次已过期，它的回调进不来，所以不会一跳两集。
   */
  private onCompleted(): void {
    if (this.completedFired) {
      return;                 // 本集只认一次：兜底轮询会反复进来
    }
    const now: number = Date.now();
    if (now - this.completedTs < 1500) {
      return;
    }
    this.completedTs = now;
    this.completedFired = true;
    if (this.isLive || !this.canSwitchEp()) {
      return;                 // 直播没有「播完」，单集电影也没下一集
    }
    const next: number = this.epIdx + 1;
    if (next >= this.epCount) {
      this.showTip('已播完最后一集');
      return;
    }
    hilog.info(DOMAIN, TAG, 'completed, auto next ep %{public}d/%{public}d',
      next + 1, this.epCount);
    this.startEp(next, true);
  }

  private switchEp(delta: number): void {
    if (!this.canSwitchEp()) {
      return;
    }
    const want: number = this.epIdx + delta;
    if (want < 0) {
      this.showTip('已经是第一集');
      return;
    }
    if (want >= this.epCount) {
      this.showTip('已经是最后一集');
      return;
    }
    this.startEp(want);
  }

  /**
   * 切到第 idx 集（0 起）。
   * 和换线路是同一套路子：整个 AVPlayer 重建，所以「准备状态」这一族重置守卫
   * 必须一次性全部归位，否则 inited / prepareCalled 会把新一次初始化挡掉，表现为切集后黑屏。
   */
  private startEp(idx: number, auto: boolean = false): void {
    if (idx < 0 || idx >= this.epUrls.length) {
      return;
    }
    this.cancelSeek();            // 切集时丢弃未松手的预览，别拿上一集的时间去跳
    this.saveProgress();          // 先把当前集的进度落盘，再换
    this.completedFired = false;  // 新的一集要重新允许「播完自动接下一集」
    this.releasePlayer();
    this.epIdx = idx;
    this.inited = false;
    this.strategyReady = false;
    this.prepareCalled = false;
    this.preparedReady = false;
    this.started = false;
    this.isPlaying = false;
    this.connecting = true;
    this.errMsg = '';
    this.resolving = false;
    this.durTime = 0;
    this.curTime = 0;
    this.videoW = 0;   // 下一集分辨率可能不同，重新取
    this.videoH = 0;
    this.bufferStalls = 0;
    this.firstStallTs = 0;
    this.lastStallTs = 0;
    this.cachePeak = 0;
    this.seekBufferUntilTs = 0;
    this.savedProgress = 0;
    this.playUrl = '';
    this.rawUrl = this.epUrls[idx];
    const nm: string = this.epNames[idx];
    if (nm.length > 0 && this.progBase.length > 0) {
      this.progId = this.progBase + nm;
    }
    if (this.nameBase.length > 0) {
      this.title = nm.length > 0 ? this.nameBase + ' · ' + nm : this.nameBase;
    }
    this.showTip((auto ? '自动播放 ' : '') + '第 ' + (idx + 1) + '/' + this.epCount + ' 集');
    hilog.info(DOMAIN, TAG, 'switch ep %{public}d/%{public}d (auto=%{public}s)',
      idx + 1, this.epCount, String(auto));
    this.prepareAndStart();
  }

  private releasePlayer(): void {
    const p = this.player;
    this.player = null;
    // 代次 +1：旧实例随后抛出的 stateChange / error 全部按过期丢弃
    this.gen++;
    if (p) {
      p.release().catch(() => {});
    }
    // 本地预取文件的句柄要跟着播放器一起放掉，不然下次打开会占着文件
    this.closeLocalFd();
  }

  private closeLocalFd(): void {
    if (this.localFd >= 0) {
      try {
        fs.closeSync(this.localFd);
      } catch (e) {
        // 已关闭
      }
      this.localFd = -1;
    }
  }

  /** 播起来之后记下这条线路，下次点同一频道直接用它 */
  private rememberLine(): void {
    if (!this.isLive || this.ctx === null || this.liveUrls.length <= 1) {
      return;
    }
    LiveMarkStore.setLastGood(this.ctx, this.liveKey, this.liveUrls[this.linePos]);
  }

  private startWatchdog(): void {
    this.clearWatchdog();
    const g: number = this.gen;
    this.watchdog = setTimeout(() => {
      this.watchdog = -1;
      if (g !== this.gen || this.isPlaying || this.errMsg.length > 0) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'watchdog: still no picture, treat as failed');
      this.onPlayFail(this.rawUrl, '12 秒内没有画面，这条线路可能已失效', '');
    }, 12000) as number;
  }

  private clearWatchdog(): void {
    if (this.watchdog !== -1) {
      clearTimeout(this.watchdog);
      this.watchdog = -1;
    }
  }

  /**
   * 挂 surface + prepare。两者顺序不能反：AVPlayer 的 prepare 依赖 surface 存在，
   * 否则底层取 surfaceId 失败，返回 401 且只有声音没有画面。
   */
  /**
   * 播放前设置缓冲策略 —— 这是「低画质也老卡」最有效的一处改动。
   *
   * 采集站的 m3u8 是单码率 + 2~3 秒的超短分片，每片一次独立请求且首字节要等
   * 0.42s；默认缓冲区只有几秒，连续几次抖动就见底停播。华为官方《在线视频
   * 播放卡顿优化》建议：媒体 >20MB 时把 preferredBufferDuration 设为 20（秒，
   * 取值 [1,20]），把水箱加大来吸收抖动。
   *
   * 起播/恢复门槛取 8 秒：实测这个源站单分片只换回 1.5~5.4 秒内容、慢片下载要
   * 6~8 秒，3 秒余量连一次慢片都扛不住，起播几十秒就见底。起播阶段没有播放消耗，
   * 是攒水最便宜的时刻，多等约 3 秒换 5 秒余量，比反复小卡更划算。
   *
   * setPlaybackStrategy 只允许在 initialized 状态调用，所以必须 await 完再 prepare。
   */
  private async applyStrategyAndPrepare(): Promise<void> {
    // 万一策略接口迟迟不返回，3 秒后也要放行，不能把播放卡死在 prepare 之前
    setTimeout(() => {
      if (!this.strategyReady) {
        this.strategyReady = true;
        this.attachSurfaceAndPrepare();
      }
    }, 3000);
    const p = this.player;
    if (p) {
      const core: media.PlaybackStrategy = {
        preferredBufferDuration: 20,
        preferredBufferDurationForPlaying: 8
      };
      try {
        await p.setPlaybackStrategy(core);
        hilog.info(DOMAIN, TAG, 'playbackStrategy ok: buffer=20s start=8s');
      } catch (e) {
        // 个别机型不认起播水位字段，退回单字段再试，缓冲 20s 一定要保住
        try {
          await p.setPlaybackStrategy({ preferredBufferDuration: 20 });
          hilog.info(DOMAIN, TAG, 'playbackStrategy fallback ok: buffer=20s');
        } catch (e2) {
          hilog.error(DOMAIN, TAG, 'setPlaybackStrategy failed: %{public}s', (e2 as Error).message);
        }
      }
    }
    this.strategyReady = true;
    this.attachSurfaceAndPrepare();
  }

  private attachSurfaceAndPrepare(): void {
    if (!this.player || !this.inited || !this.strategyReady || this.prepareCalled) {
      return;
    }
    const sid: string = this.surfaceId.length > 0
      ? this.surfaceId
      : this.xcController.getXComponentSurfaceId();
    if (sid.length === 0) {
      return; // 等 onLoad/下一帧再试
    }
    this.surfaceId = sid;
    this.prepareCalled = true;
    try {
      this.player.surfaceId = sid;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'set surfaceId failed: %{public}s', (e as Error).message);
    }
    try {
      this.player.prepare();
    } catch (e) {
      this.prepareCalled = false;
      this.connecting = false;
      this.errMsg = '准备播放失败：' + (e as Error).message;
    }
  }

  /**
   * 画面比例。
   *
   * 坑：media.VideoScaleType 的默认值 VIDEO_SCALE_TYPE_FIT 名字看着像"适应窗口"，
   * SDK 注释的实际语义是 "stretched to fit the window"，即**拉伸填满**。
   * 非 16:9 的片源（2.0:1 / 2.35:1 的剧集、4:3 的老片）会被纵向硬撑成屏幕高，
   * 人物变瘦长 —— 就是"上下撑满、比例失调"的来源。
   *
   * 三个可选值：
   *   FIT = 0                 拉伸填满（默认，会变形）
   *   FIT_CROP = 1            保持比例，裁掉溢出部分（不变形，但切画面）
   *   SCALED_ASPECT = 2       保持比例居中，空缺处留黑（API 20+，正确做法）
   *
   * 这里用 SCALED_ASPECT。若片源本身就是 16:9，效果等同于全屏无黑边。
   */
  private applyScaleMode(): void {
    const p = this.player;
    if (!p) {
      return;
    }
    let w: number = 0;
    let h: number = 0;
    try {
      w = p.width;
      h = p.height;
    } catch (e) {
      // prepared 刚切过来时个别机型取不到，留 0 即可
    }
    if (w > 0 && h > 0) {
      this.videoW = w;
      this.videoH = h;
    }
    try {
      p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'set videoScaleType failed: %{public}s', (e as Error).message);
    }
    hilog.info(DOMAIN, TAG, 'video %{public}dx%{public}d ratio %{public}s scale=SCALED_ASPECT',
      w, h, (w > 0 && h > 0) ? (w / h).toFixed(3) : '?');
  }

  private startTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
    }
    this.timer = setInterval(() => {
      if (this.player) {
        try {
          this.curTime = this.player.currentTime;
          const d = this.player.duration;
          if (d > 0) {
            this.durTime = d;
          }
          // 兜底：部分 VOD HLS 播完不报 completed，而是停在 stopped（isPlaying 已为 false）。
          // 只在这种「已经不在播 + 进度到顶」的组合下补一次，播放中即使 duration 报小了也不会误跳。
          // onCompleted 自带 1.5s 去重，重复触发无副作用。
          if (!this.isLive && !this.isPlaying
            && this.durTime > 0 && this.curTime >= this.durTime - 800) {
            this.onCompleted();
          }
        } catch (e) {
          // 忽略瞬时异常
        }
      }
    }, 500) as number;
  }

  private tryPlay(): void {
    if (this.started) {
      return;
    }
    if (!(this.preparedReady && this.surfaceReady && this.player)) {
      return;
    }
    this.started = true;
    const resume: number = this.savedProgress;
    const canResume: boolean = !this.isLive && resume > 0 && resume < this.durTime - 3000;
    const resumeByte: number = canResume ? this.byteOf(resume) : 0;
    if (canResume && resumeByte <= LocalPrefetch.readyByte()) {
      try {
        this.player.seek(resume, media.SeekMode.SEEK_PREV_SYNC);
        this.curTime = resume;
        // 续播起跳同样要重新拉流；且 curTime 已被设成正值，
        // 绕过了上面 curTime <= 0 的起播预缓冲过滤，必须靠这里豁免
        this.markUserSeek();
      } catch (e) {
        // seek 失败则从头播
      }
    } else if (canResume && LocalPrefetch.isActive()) {
      // 续播位置还没轮到下载：先从头放，缓存追上再跳过去，别让播放器读空区
      LocalPrefetch.waitByte(resumeByte, 120000).then(() => {
        if (LocalPrefetch.readyByte() >= resumeByte) {
          this.seekCached(resume);
        }
      });
    }
    this.player.play().then(() => {
      this.isPlaying = true;
      this.connecting = false;
      this.clearWatchdog();
      this.rememberLine();
      this.scheduleHide();
    }).catch((e: BusinessError) => {
      // play() 被拒说明这条流压根起不来：以前只打日志，界面就一直停在「已暂停」
      hilog.error(DOMAIN, TAG, 'play failed: %{public}s', e.message);
      this.onPlayFail(this.rawUrl, '无法开始播放：' + e.message, String(e.code));
    });
  }

  // ---------------- 控制栏显隐 ----------------

  private toggleUi(): void {
    this.uiVisible = !this.uiVisible;
    if (this.uiVisible) {
      this.scheduleHide();
    } else {
      this.clearHide();
      // 控制层藏起来后给出一次引导，否则用户不知道点哪里能唤回
      this.showTip('点屏幕任意位置可显示控制条');
    }
  }

  private scheduleHide(): void {
    this.clearHide();
    if (!this.uiVisible || !this.isPlaying) {
      return;
    }
    this.uiTimer = setTimeout(() => {
      this.uiTimer = -1;
      if (this.isPlaying) {
        this.uiVisible = false;
      }
    }, UI_HIDE_MS) as number;
  }

  private clearHide(): void {
    if (this.uiTimer !== -1) {
      clearTimeout(this.uiTimer);
      this.uiTimer = -1;
    }
  }

  private showTip(t: string): void {
    this.tipText = t;
    if (this.tipTimer !== -1) {
      clearTimeout(this.tipTimer);
    }
    this.tipTimer = setTimeout(() => {
      this.tipTimer = -1;
      this.tipText = '';
    }, 2500) as number;
  }

  // ---------------- 播放控制 ----------------

  private togglePlay(): void {
    if (!this.player) {
      return;
    }
    if (this.connecting) {
      // 还没播起来时 play() 会被播放器拒绝（state 不是 prepared），给句人话
      this.showTip('正在连接，请稍候…');
      return;
    }
    if (this.isPlaying) {
      this.player.pause();
      this.isPlaying = false;
      this.clearHide();
      this.uiVisible = true; // 暂停时保持控制栏可见，方便看清状态
      this.showTip('已暂停');
    } else {
      this.player.play().then(() => {
        this.isPlaying = true;
        this.showTip('继续播放');
        this.scheduleHide();
      }).catch(() => {});
    }
  }

  /**
   * 标记「接下来这段缓冲是用户主动跳转引起的」。
   * 放在每一处真正调用 player.seek 的地方；长按连续跳会不断刷新截止时刻，
   * 整段连跳期间都不会误报换线路。不清 bufferStalls —— 之前 30s 窗口里
   * 已经真实发生的卡顿仍然有效，跳转只是让这一次的预期缓冲不参与计数。
   */
  private markUserSeek(): void {
    this.seekBufferUntilTs = Date.now() + SEEK_BUFFER_GRACE_MS;
    // 上次卡顿的 1.5s 去重窗口不该吃掉跳转结束后的第一次真卡顿
    this.lastStallTs = 0;
  }

  private seekBy(delta: number): void {
    if (!this.player || this.isLive) {
      return;
    }
    let t = this.curTime + delta;
    if (t < 0) {
      t = 0;
    }
    if (this.durTime > 0 && t > this.durTime) {
      t = this.durTime;
    }
    this.seekCached(t);
  }

  /**
   * 点进度条任意位置 → 直接跳到对应时间点。
   *
   * 原来这里只有一个 Progress（纯展示组件），点它不会 seek，点击还会冒泡到控制层的
   * 「点空白显隐」，表现成"一按控制条就没了"。现在外面套一层可命中的 Stack：
   *   ClickEvent.x = 相对该 Stack 左上角的局部坐标(vp)，barWidth 由 onAreaChange 拿到，
   *   两者相除即目标进度。
   *
   * 两个边界：
   *   1) 控制条隐藏时，点画面（含底部这块）的语义是「唤回控制条」，不能误跳；
   *   2) 这次点击必须标记成"按钮点击"，否则冒泡到 onScreenTap 会把刚跳完的控制条收起来。
   */
  private onBarTap(x: number): void {
    if (!this.uiVisible || this.isLive) {
      return;
    }
    const now = Date.now();
    if (now - this.lastBarTapTs < 350) {
      return;
    }
    // 个别机型 touch/mouse 给的是窗口坐标，明显越界时不跳，留给后面的 click 处理
    if (x < 0 || (this.barWidth > 0 && x > this.barWidth + 4)) {
      return;
    }
    this.lastBarTapTs = now;
    // 借按钮点击的抑制窗口挡住冒泡，避免"跳完控制条立刻消失"
    this.lastBtnTapTs = now;
    if (!this.player || this.durTime <= 0 || this.barWidth <= 0) {
      this.showTip('当前片源无法获取时长，暂不能跳转');
      return;
    }
    let ratio: number = x / this.barWidth;
    if (ratio < 0) {
      ratio = 0;
    } else if (ratio > 1) {
      ratio = 1;
    }
    // 留 1 秒余量，别让点到最右端时立刻触发播放结束
    const t: number = Math.floor(ratio * Math.max(this.durTime - 1000, 0));
    this.seekCached(t);
    this.showTip('跳转至 ' + this.fmt(t));
    if (this.uiVisible) {
      this.scheduleHide();
    }
  }

  /**
   * 按下左右：起手照旧跳一格 60s（短按就只有这一格，反馈即时、也不依赖 Up 能否送到）。
   * 超过 450ms 还没松手 → 转成「预览找点」：此后全程不再 seek，每 300ms 把目标时间
   * 往前推 60s，屏幕中间实时显示目标时间，松手才跳到那个时间。整段长按只有 2 次 seek，
   * 不再像以前那样每 700ms 拉一次流、画面反复卡在重新缓冲上。
   * 真机上按住方向键可能只来一个 Down（无重复事件），所以推进完全靠自己计时。
   */
  private beginSeek(dir: number): void {
    if (this.isLive) {
      return;
    }
    if (this.holdKey === dir) {
      return;   // 防系统重复 Down
    }
    this.cancelSeek();
    this.holdKey = dir;
    this.holdLong = false;
    this.holdTicks = 0;
    this.holdBase = this.curTime;                       // 快照：目标不随播放推进漂移
    // 起手先跳一格：短按的反馈保持和原来一样即时；万一 Up 丢了，这一格也仍然生效，
    // 不会变成「按了没反应」。长按预览的目标就从这个落点继续往前推。
    this.holdTarget = this.clampSeek(this.holdBase + dir * SEEK_BASE);
    // 起手这一格也走 seekTo，落点和预览目标用同一套钳制，避免到片尾时两者差一秒
    this.seekTo(this.holdTarget);
    this.showTip((dir > 0 ? '快进 ' : '快退 ') + Math.floor(SEEK_BASE / 1000) + ' 秒');
    // 超过判定阈值还没松手，才转成「只预览、不真跳」
    this.holdDelayTimer = setTimeout(() => {
      this.holdDelayTimer = -1;
      if (this.holdKey === 0) {
        return;
      }
      this.holdLong = true;
      this.tipText = '';                                // 不要和顶部小提示叠着显示
      this.showSeekPreview();
      this.holdTimer = setInterval(() => {
        const d: number = this.holdKey;
        if (d === 0) {
          return;
        }
        // Up 偶发丢失的兜底：只丢弃预览、不再跳，避免被跳到莫名其妙的位置
        //（起手那一格已经生效，等于一次普通短按）；正常长按 12 秒也早就到片尾了
        if (++this.holdTicks > SEEK_MAX_TICKS) {
          this.cancelSeek();
          return;
        }
        this.holdTarget = this.clampSeek(this.holdTarget + d * SEEK_STEP);
        this.showSeekPreview();
      }, SEEK_TICK_MS) as number;
    }, SEEK_HOLD_MS) as number;
  }

  /** 只清计时器和按住态，不执行跳转（页面退出 / 切集用） */
  private stopHoldTimers(): void {
    if (this.holdDelayTimer !== -1) {
      clearTimeout(this.holdDelayTimer);
      this.holdDelayTimer = -1;
    }
    if (this.holdTimer !== -1) {
      clearInterval(this.holdTimer);
      this.holdTimer = -1;
    }
  }

  private cancelSeek(): void {
    this.stopHoldTimers();
    this.holdKey = 0;
    this.holdLong = false;
    this.hideSeekPreview();
  }

  /** 松手：短按已在起手跳过；长按预览再跳到屏幕中间显示的那个时间（整段共 2 次 seek） */
  private endSeek(): void {
    const dir: number = this.holdKey;
    const wasLong: boolean = this.holdLong;
    const target: number = this.holdTarget;
    this.stopHoldTimers();
    this.holdKey = 0;
    this.holdLong = false;
    if (dir === 0) {
      return;   // touch Up 和 mouse Release 会重复到达，第二次直接忽略
    }
    // 长按结束后紧跟的 onClick 要抑制掉，否则按钮路径会多跳一次
    this.lastSeekEndTs = Date.now();
    if (wasLong) {
      // 刚进预览就松手时目标 == 起手落点，不必再 seek 一次
      if (Math.abs(target - this.curTime) > 1000) {
        this.seekTo(target);
      }
      this.showTip('跳转至 ' + this.fmt(target));
      this.seekPreviewMain = '已跳转  ' + this.fmt(target);
      this.seekPreviewSub = '';
      this.schedulePreviewHide(800);
    }
    // 短按那一格已经在 beginSeek 里跳过了，这里不再重复 seek
    if (this.uiVisible) {
      this.scheduleHide();
    }
  }

  /** 绝对时间跳转：长按松手用；落点计算与点进度条保持一致 */
  private seekTo(t: number): void {
    this.seekCached(t);
  }

  /**
   * 本地缓存还没下到这一段时，先等下载追上再跳。
   *
   * 播放器读的是本地文件，未下载区域是全零——直接 seek 过去会被当成坏码流，
   * 报的正是「stream is unsupported」。所以跳转一律先问一句：这段落地了没有。
   */
  private seekCached(t: number): void {
    if (!this.player || this.isLive) {
      return;
    }
    const total: number = LocalPrefetch.totalByte();
    const ready: number = LocalPrefetch.readyByte();
    if (!LocalPrefetch.isActive() || total <= 0 || this.durTime <= 0) {
      this.doSeek(t);
      return;
    }
    const byte: number = Math.floor(t / this.durTime * total);
    if (byte <= ready) {
      this.doSeek(t);
      return;
    }
    if (this.pendingSeek) {
      return;
    }
    this.pendingSeek = true;
    this.showTip('正在缓存这一段…');
    LocalPrefetch.waitByte(byte, 120000).then(() => {
      this.pendingSeek = false;
      const nowReady: number = LocalPrefetch.readyByte();
      if (nowReady >= byte) {
        this.doSeek(t);
        return;
      }
      // 等不上了：退到已经落地的地方，别让播放器去读空区
      const at: number = this.durTime * nowReady / total;
      this.showTip('这一段还没缓存完，先播到能放的位置');
      this.doSeek(this.clampSeek(at - 5));
    });
  }

  /** 真正落 seek 的唯一出口：顺带把 curTime 与缓冲豁免一起更新 */
  private doSeek(t: number): void {
    const target: number = this.clampSeek(t);
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    try {
      p.seek(target, media.SeekMode.SEEK_PREV_SYNC);
      this.curTime = target;
      this.markUserSeek();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'seek failed: %{public}s', (e as Error).message);
      this.showTip('跳转失败，可换条线路再试');
    }
  }

  /** 时间点换算成文件字节位置（按平均码率估，只用于判断「这段下到了没有」） */
  private byteOf(sec: number): number {
    const total: number = LocalPrefetch.totalByte();
    if (total <= 0 || this.durTime <= 0) {
      return 0;
    }
    return Math.floor(sec / this.durTime * total);
  }

  private clampSeek(t: number): number {    let v: number = t < 0 ? 0 : t;
    // 留 1 秒余量，别让跳到最右端立刻触发播放结束（和点进度条一致）
    if (this.durTime > 1000 && v > this.durTime - 1000) {
      v = this.durTime - 1000;
    }
    return v;
  }

  /** 屏幕中间的实时预览：主行目标时间，副行偏移量 + 是否到边界 */
  private showSeekPreview(): void {
    const d: number = this.holdKey;
    if (d === 0) {
      return;
    }
    const atEdge: boolean = (d > 0 && this.durTime > 1000 && this.holdTarget >= this.durTime - 1000)
      || (d < 0 && this.holdTarget <= 0);
    this.seekPreviewMain = (d > 0 ? '» ' : '« ') + this.fmt(this.holdTarget);
    this.seekPreviewSub = (d > 0 ? '快进 +' : '快退 -')
      + this.fmt(Math.abs(this.holdTarget - this.holdBase))
      + (atEdge ? ' · 已到边界' : ' · 松手跳转');
    this.seekPreviewOn = true;
    // 长按时光标不动，控制条不能按 5 秒自动收起；每走一格重新计时
    if (this.uiVisible) {
      this.scheduleHide();
    }
  }

  private schedulePreviewHide(ms: number): void {
    if (this.previewHideTimer !== -1) {
      clearTimeout(this.previewHideTimer);
    }
    this.previewHideTimer = setTimeout(() => {
      this.previewHideTimer = -1;
      this.seekPreviewOn = false;
    }, ms) as number;
  }

  private hideSeekPreview(): void {
    if (this.previewHideTimer !== -1) {
      clearTimeout(this.previewHideTimer);
      this.previewHideTimer = -1;
    }
    this.seekPreviewOn = false;
  }

  // ---------------- 指针（遥控器光标）交互 ----------------

  /**
   * 点画面空白处：显隐控制层。
   * 三种来源（控制层空白、透明点击层、根容器）都可能触发同一次点击，用时间戳去重；
   * 点在按钮上的那次由 lastBtnTapTs 排除。
   */
  private onScreenTap(): void {
    const now = Date.now();
    if (now - this.lastBtnTapTs < 600) {
      return;
    }
    if (now - this.lastTapTs < 400) {
      return;
    }
    this.lastTapTs = now;
    this.toggleUi();
    // 点画面后把焦点收回按键接收器，避免焦点跑掉导致遥控器失效
    try {
      focusControl.requestFocus('keySink');
    } catch (e) {
      // 忽略
    }
  }

  /** 按钮按下（onTouch Down 或 onMouse Press）：开始一次快进退判定 */
  private pressBegin(dir: number): void {
    if (this.isLive) {
      return;
    }
    // touch 与 mouse 事件在部分机型上会同时到达，只认第一次
    if (this.holdKey === dir) {
      return;
    }
    this.beginSeek(dir);
  }

  /** 按钮松开：短按跳一格，长按预览则跳到目标时间 */
  private pressEnd(): void {
    this.endSeek();
  }

  private changeSpeed(dir: number): void {
    if (this.isLive) {
      return;
    }
    const now = Date.now();
    // 过滤按键重复事件，避免一下跨好几档
    if (now - this.lastSpeedTs < 300) {
      return;
    }
    this.lastSpeedTs = now;
    let i = this.speedIdx + dir;
    if (i < 0) {
      i = SPEEDS.length - 1;
    }
    if (i >= SPEEDS.length) {
      i = 0;
    }
    this.speedIdx = i;
    this.applySpeed();
    this.showTip('倍速 ' + SPEEDS[this.speedIdx] + 'x');
  }

  private applySpeed(): void {
    if (!this.player) {
      return;
    }
    const s = SPEEDS[this.speedIdx];
    let mode: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (s === 1.25) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    } else if (s === 1.75) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    } else if (s === 2.0) {
      mode = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    try {
      this.player.setSpeed(mode);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setSpeed failed: %{public}s', (e as Error).message);
    }
  }

  // ---------------- OK 键：短按显隐 / 长按暂停 ----------------

  private okDown(): void {
    if (this.okTimer !== -1) {
      return; // 长按过程中的重复事件
    }
    this.okLongFired = false;
    this.okTimer = setTimeout(() => {
      this.okTimer = -1;
      this.okLongFired = true;
      this.togglePlay();
    }, OK_LONG_MS) as number;
  }

  private okUp(): void {
    if (this.okTimer !== -1) {
      clearTimeout(this.okTimer);
      this.okTimer = -1;
      if (!this.okLongFired) {
        this.toggleUi();
      }
    }
    this.okLongFired = false;
  }

  // ---------------- 画面长按：播放 / 暂停 ----------------
  /**
   * 灵犀指向式遥控器在播放页收不到标准 KeyEvent：真机日志里连 OK 键的
   * `key xx DOWN/UP` 都一条没有，所以「长按 OK 暂停」在这台设备上永远触发不了。
   * 触摸事件反而是可靠的（快进按钮、进度条都靠它），改成：
   *   短按画面 = 显隐控制条（原行为）
   *   长按画面 500ms = 播放 / 暂停
   * handleKey 里的 OK 长按逻辑保留，换普通方向键遥控器仍然生效。
   */
  private screenTouchDown(): void {
    if (this.screenHoldTimer !== -1) {
      clearTimeout(this.screenHoldTimer);
    }
    this.screenLongFired = false;
    this.screenHoldTimer = setTimeout(() => {
      this.screenHoldTimer = -1;
      this.screenLongFired = true;
      this.togglePlay();
    }, SCREEN_LONG_MS) as number;
  }

  private screenTouchUp(): void {
    if (this.screenHoldTimer !== -1) {
      clearTimeout(this.screenHoldTimer);
      this.screenHoldTimer = -1;
      this.onScreenTap();   // 没到长按阈值：当作短按，显隐控制条
    }
    // 长按已经切换过播放状态：保持 fired，让随后到达的 onClick 自己复位并跳过
  }

  private screenTouchCancel(): void {
    if (this.screenHoldTimer !== -1) {
      clearTimeout(this.screenHoldTimer);
      this.screenHoldTimer = -1;
    }
    this.screenLongFired = false;
  }

  private saveProgress(): void {
    if (!this.isLive && this.ctx !== null && this.progId) {
      PlayProgress.save(this.ctx, this.progId, this.curTime).catch(() => {});
    }
  }

  private saveAndExit(): void {
    this.saveProgress();
    router.back();
  }

  aboutToDisappear(): void {
    this.saveProgress();
    PosterStore.resume();
    RatingStore.resume();
    this.clearWatchdog();
    this.gen++;
    // 离场就停掉后台下载，别让它在后台白跑流量
    LocalPrefetch.cancel();
    // 退出时只丢弃未松手的预览，不要再跳一次
    this.cancelSeek();
    this.clearHide();
    if (this.tipTimer !== -1) {
      clearTimeout(this.tipTimer);
      this.tipTimer = -1;
    }
    if (this.okTimer !== -1) {
      clearTimeout(this.okTimer);
      this.okTimer = -1;
    }
    if (this.screenHoldTimer !== -1) {
      clearTimeout(this.screenHoldTimer);
      this.screenHoldTimer = -1;
    }
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.player) {
      this.player.release().catch(() => {});
      this.player = null;
    }
  }

  private fmt(ms: number): string {
    if (ms <= 0) {
      return '00:00';
    }
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    if (h > 0) {
      return h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
    }
    return (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }

  private btnLabel(action: string): string {
    if (action === 'toggle') {
      return this.isPlaying ? '❚❚ 暂停' : '▶ 播放';
    }
    if (action === 'back') {
      return '« 60s';
    }
    if (action === 'fwd') {
      return '60s »';
    }
    if (action === 'speed') {
      return '倍速 ' + SPEEDS[this.speedIdx] + 'x';
    }
    if (action === 'line') {
      return '换线路 ' + this.lineNo + '/' + this.lineCount;
    }
    if (action === 'prev') {
      return '⏮ 上集';
    }
    if (action === 'next') {
      return '下集 ⏭';
    }
    if (action === 'size') {
      return this.actualSize ? '⛶ 全屏' : '▣ 实际 100%';
    }
    return '退出';
  }

  private doAction(action: string): void {
    // 光标点击后重新计时，避免手一动控制条就没了
    if (this.uiVisible) {
      this.scheduleHide();
    }
    if (action === 'back') {
      // 长按刚结束时会紧跟一个 onClick，这里抑制掉，否则会多跳一次
      if (Date.now() - this.lastSeekEndTs < 500) {
        return;
      }
      this.seekBy(-SEEK_BASE);
      this.showTip('快退 ' + Math.floor(SEEK_BASE / 1000) + ' 秒');
    } else if (action === 'fwd') {
      if (Date.now() - this.lastSeekEndTs < 500) {
        return;
      }
      this.seekBy(SEEK_BASE);
      this.showTip('快进 ' + Math.floor(SEEK_BASE / 1000) + ' 秒');
    } else if (action === 'toggle') {
      this.togglePlay();
    } else if (action === 'speed') {
      this.changeSpeed(1);
    } else if (action === 'line') {
      this.switchLine();
    } else if (action === 'prev') {
      this.switchEp(-1);
    } else if (action === 'next') {
      this.switchEp(1);
    } else if (action === 'size') {
      if (this.videoW <= 0 || this.videoH <= 0) {
        this.showTip('片源未提供分辨率，无法按实际大小播放');
        return;
      }
      this.actualSize = !this.actualSize;
      this.showTip(this.actualSize
        ? '实际大小 ' + this.videoW + '×' + this.videoH + '（1:1 像素）'
        : '适应屏幕');
      // 等一帧布局完成、surface 尺寸变了之后，再重设缩放类型让播放器按新 surface 重算
      setTimeout(() => {
        this.applyScaleMode();
      }, 80);
    } else if (action === 'exit') {
      this.saveAndExit();
    }
  }

  /**
   * 按钮组之间的留白。
   * Row 的 space 是统一值，没法只把某两处拉宽，所以放一个不可命中的占位撑开：
   * 实际间距 = 18 + 8 + 18 = 44vp，组内仍是 18vp。
   * 只敢留 8vp：电视是 4K/密度 3，即 1280vp 宽，8 个按钮本来就把这一行占得差不多满了。
   */
  @Builder
  gapBtn() {
    Row()
      .width(8)
      .height(1)
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ctrlBtn(action: string) {
    // 文字必须在 builder 内部读状态：@Builder 传参是按值传递，父状态变化不会重建，
    // 直接把 label 当参数传进来会一直显示旧的「▶ 播放」
    Button(this.btnLabel(action))
      .fontSize(17)
      .fontColor('#ffffff')
      // 光标指到哪个按钮就亮哪个
      .backgroundColor(this.hoverKey === action ? '#FF6B00' : '#66000000')
      .height(54)
      .padding({ left: 26, right: 26 })
      .borderRadius(27)
      // 可见按钮不抢焦点：焦点统一由隐藏的「按键接收器」持有，
      // 否则方向键会被系统当成焦点导航，左右键就没法用来快进退
      .focusable(false)
      .onHover((isHover: boolean) => {
        if (isHover) {
          this.hoverKey = action;
        } else if (this.hoverKey === action) {
          this.hoverKey = '';
        }
      })
      .onClick((ev: ClickEvent) => {
        // ClickEvent 没有 stopPropagation，用时间戳让根容器的「点空白收起」忽略这次点击
        this.lastBtnTapTs = Date.now();
        this.doAction(action);
      })
      .onTouch((ev: TouchEvent) => {
        // 所有按钮都拦住冒泡：否则按得久一点会被控制层的「长按画面暂停」抢走
        ev.stopPropagation();
        if (action !== 'back' && action !== 'fwd') {
          return;
        }
        if (ev.type === TouchType.Down) {
          this.pressBegin(action === 'fwd' ? 1 : -1);
        } else if (ev.type === TouchType.Up) {
          this.pressEnd();
        } else if (ev.type === TouchType.Cancel) {
          this.cancelSeek();   // 手势被系统打断：丢弃预览，不跳转
        }
      })
      .onMouse((ev: MouseEvent) => {
        if (action !== 'back' && action !== 'fwd') {
          return;
        }
        if (ev.action === MouseAction.Press) {
          this.pressBegin(action === 'fwd' ? 1 : -1);
        } else if (ev.action === MouseAction.Release) {
          this.pressEnd();
        }
      })
  }

  build() {
    Stack() {
      XComponent({ id: 'video', type: XComponentType.SURFACE, controller: this.xcController })
        .onLoad((surfaceId) => {
          // 优先用控制器取；回调参数在部分机型上会是空串
          let sid: string = String(surfaceId ?? '');
          if (sid.length === 0) {
            sid = this.xcController.getXComponentSurfaceId();
          }
          this.surfaceId = sid;
          this.surfaceReady = sid.length > 0;
          this.attachSurfaceAndPrepare();
          if (this.player && this.preparedReady) {
            try {
              this.player.surfaceId = sid;
            } catch (e) {
              // 已在 prepare 前挂好了就忽略
            }
          }
          this.tryPlay();
        })
        .onDestroy(() => {})
        .focusable(false) // 别让画面表面抢走焦点，按键统一交给根容器处理
        // 实际大小：把 surface 缩到片源原始像素，SCALED_ASPECT 在比例相同时即 1:1 不缩放。
        // 必须用 px 字符串，vp 会被屏幕 density 乘一遍，就不是 100% 了。Stack 默认居中，四周露黑底。
        .width(this.actualSize && this.videoW > 0 ? this.videoW + 'px' : '100%')
        .height(this.actualSize && this.videoH > 0 ? this.videoH + 'px' : '100%')

      // 全局控制层：片名 + 状态 + 进度条 + 按钮
      Column() {
        Row() {
          Text(this.title)
            .fontSize(20).fontColor('#ffffff')
            .textShadow({ radius: 4, color: '#000000' })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.isLive) {
            Text('直播').fontSize(14).fontColor('#ffffff')
              .backgroundColor('#FF3B30')
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .borderRadius(4)
          } else if (this.canSwitchEp()) {
            // 多集时把集数亮出来：控制条上「上集 / 下集」只在有剧集信息时才画，
            // 有了这个角标，一眼能看出当前片子到底有没有分集
            Text('第 ' + (this.epIdx + 1) + '/' + this.epCount + ' 集')
              .fontSize(13)
              .fontColor('#FFD9BC')
              .backgroundColor('#66000000')
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .borderRadius(4)
          }
        }
        .width('100%')
        .padding(24)

        if (this.resolving) {
          Column() {
            LoadingProgress().width(50).height(50)
            Text('解析中…').fontColor('#ffffff').fontSize(16).margin({ top: 8 })
          }.margin({ bottom: 140 })
        } else if (this.errMsg) {
          Text(this.errMsg)
            .fontColor('#ff7777')
            .fontSize(15)
            .lineHeight(22)
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('80%')
            .padding(14)
            .backgroundColor('#00000088')
            .borderRadius(8)
            .margin({ bottom: 140 })
        } else if (this.connecting) {
          // 解析完成但还没播起来：这里以前会落到「已暂停」，看着像自己按错了
          Column() {
            LoadingProgress().width(50).height(50)
            Text(this.fetchPct >= 0
              ? '正在缓存 ' + this.fetchPct + '%'
              : (this.isLive && this.lineCount > 1
                ? '连接中… 线路 ' + this.lineNo + '/' + this.lineCount
                : '连接中…'))
              .fontColor('#ffffff').fontSize(16).margin({ top: 10 })
            if (this.fetchPct < 0 && this.isLive && this.lineCount > 1) {
              Text('这条放不出来会自动试下一条')
                .fontColor('#bbbbbb').fontSize(13).margin({ top: 6 })
            }
          }.margin({ bottom: 140 })
        } else if (!this.isPlaying) {
          Column() {
            Text('❚❚').fontSize(44).fontColor('#ffffff')
            Text('已暂停 · 点下方播放按钮继续').fontColor('#ffffff').fontSize(16)
              .margin({ top: 10 })
          }.margin({ bottom: 140 })
        } else {
          Blank()
        }

        if (!this.isLive) {
          Column() {
            Row() {
              Text(this.fmt(this.curTime)).fontColor('#ffffff').fontSize(14).width(70)
              // Progress 只是展示组件，不会响应点击；外面套一层可命中的 Stack 承担进度条交互
              Stack() {
                Progress({
                  value: this.curTime,
                  total: this.durTime > 0 ? this.durTime : 1,
                  type: ProgressType.Linear
                })
                  .width('100%')
                  .height(8)
                  .color('#FF6B00')
                  .backgroundColor('#555555')
                  // 让点击落到外层 Stack，坐标才是相对整条进度条的
                  .hitTestBehavior(HitTestMode.None)
              }
              // 轨道本身只有几 vp 高，光标很难点中；把命中区扩到 40vp
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12, right: 12 })
              .backgroundColor('#01000000')
              .onAreaChange((_old: Area, area: Area) => {
                const w: number = Number(area.width);
                if (w > 0) {
                  this.barWidth = w;
                }
              })
              .onClick((ev: ClickEvent) => {
                this.onBarTap(ev.x);
              })
              // 灵犀遥控器 OK 是鼠标点击，部分机型只发 touch / mouse 而不合成 click；
              // 三条路径都收，靠 onBarTap 里的 350ms 去重，不会重复 seek
              .onTouch((ev: TouchEvent) => {
                // 别让进度条上的长按冒泡上去被当成「长按画面暂停」
                ev.stopPropagation();
                if (ev.type === TouchType.Up) {
                  const pts = ev.changedTouches.length > 0 ? ev.changedTouches : ev.touches;
                  if (pts.length > 0) {
                    this.onBarTap(pts[0].x);
                  }
                }
              })
              .onMouse((ev: MouseEvent) => {
                if (ev.action === MouseAction.Release) {
                  this.onBarTap(ev.x);
                }
              })
              Text(this.fmt(this.durTime)).fontColor('#ffffff').fontSize(14).width(70)
              Text(SPEEDS[this.speedIdx] + 'x').fontColor('#FFD700').fontSize(14).margin({ left: 14 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 按用途分组排：集数切换 → 快进退 → 播放/暂停 → 其它。
            // 组间留出更大的间距，遥控器光标扫过时不容易点错相邻的按钮。
            Row({ space: 18 }) {
              if (this.canSwitchEp()) {
                this.ctrlBtn('prev')
                this.ctrlBtn('next')
                this.gapBtn()
              }
              this.ctrlBtn('back')
              this.ctrlBtn('fwd')
              this.gapBtn()
              this.ctrlBtn('toggle')
              this.gapBtn()
              this.ctrlBtn('speed')
              this.ctrlBtn('size')
              this.ctrlBtn('exit')
            }
            .margin({ top: 16 })

            Text('长按画面 暂停/继续 · 点画面 显隐控制条 · 点按钮或进度条跳转')
              .fontSize(14).fontColor('#e8e8e8').margin({ top: 12 })
          }
          .width('100%').padding(24).backgroundColor('#000000D9')
        } else {
          Row({ space: 18 }) {
            this.ctrlBtn('toggle')
            if (this.lineCount > 1) {
              this.ctrlBtn('line')
            }
            this.ctrlBtn('size')
            this.ctrlBtn('exit')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(16)
          .backgroundColor('#000000D9')
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .opacity(this.uiVisible ? 1 : 0)
      // 不加 opacity 动画：4K 大屏上 180ms 的渐隐实际会拖到 1 秒多，
      // 期间按钮半透明很脏，直接硬切更干脆
      // 关键：隐藏时也必须保持可命中（不要把 hitTestBehavior 设成 None），
      // 否则点画面唤不回控制条——它是显隐切换的唯一入口。
      // #01000000 只是让透明区域参与命中测试，肉眼不可见。
      .backgroundColor('#01000000')
      .hitTestBehavior(HitTestMode.Default)
      .onClick(() => {
        // 长按画面已经切换过播放状态，这里别再显隐一次
        if (this.screenLongFired) {
          this.screenLongFired = false;
          return;
        }
        this.onScreenTap();
      })
      // 画面短按显隐 / 长按播放暂停。用 touch 而不是 OK 键：
      // 灵犀遥控器的 KeyEvent 到不了播放页，触摸事件才是这台设备上可靠的输入源。
      .onTouch((ev: TouchEvent) => {
        if (ev.type === TouchType.Down) {
          this.screenTouchDown();
        } else if (ev.type === TouchType.Up) {
          this.screenTouchUp();
        } else if (ev.type === TouchType.Cancel) {
          this.screenTouchCancel();
        }
      })


      // 快进/倍速的即时反馈，控制栏隐藏时也能看到
      if (this.tipText.length > 0) {
        Column() {
          Text(this.tipText)
            .fontSize(20)
            .fontColor('#ffffff')
            .padding({ left: 22, right: 22, top: 12, bottom: 12 })
            .backgroundColor('#CC000000')
            .borderRadius(10)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        // 放在偏上位置：底部是字幕区，提示压上去会挡字幕
        .padding({ top: 240 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 长按快进退：屏幕中间实时显示目标时间，期间不 seek，松手才跳一次
      if (this.seekPreviewOn) {
        Column({ space: 8 }) {
          Text(this.seekPreviewMain)
            .fontSize(52)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')
          if (this.seekPreviewSub.length > 0) {
            Text(this.seekPreviewSub)
              .fontSize(19)
              .fontColor('#FFC48A')
          }
        }
        .padding({ left: 46, right: 46, top: 22, bottom: 22 })
        .backgroundColor('#D9000000')
        .borderRadius(18)
        .hitTestBehavior(HitTestMode.None)
      }

      // 隐藏的「按键接收器」：遥控器按键只会派发给真正的焦点节点，
      // 只给根 Stack 设 focusable/defaultFocus 是收不到的（实测键次恒为 0）。
      // 这里放一个 1x1 的 Button 拿住焦点，onKeyEvent 返回 false 让事件冒泡到根容器。
      Button('')
        .id('keySink')
        .width(1)
        .height(1)
        .opacity(0.01)
        .position({ x: 0, y: 0 })
        .focusable(true)
        .defaultFocus(true)
        .focusOnTouch(false)
        .onKeyEvent((e: KeyEvent) => {
          // 必须在这里直接处理并消费：Button 对 OK 有默认 click 行为，
          // 返回 false 会被它吃掉，事件冒泡不到根容器，OK 就等于没反应
          return this.handleKey(e);
        })

      // 隐藏的无头 WebView：只在「原始地址是个播放页」时用——那种页面要靠自己的
      // JS 去请求流地址，纯 HTTP 抓 HTML 是抓不到的。解析完会导航到 about:blank 停掉。
      SniffWeb()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    // 指向式遥控器不需要焦点，但保留 focusable + onKeyEvent：
    // 换成带方向键的普通遥控器时按键逻辑可以立刻生效
    .focusable(true)
    .defaultFocus(true)
    .id('playerRoot')
    .onAppear(() => {
      this.grabFocus(300);
      this.grabFocus(1200);
    })
    // 显隐的唯一入口是上面那层全屏透明点击层：
    // 控制层和根容器都不挂 onClick，否则一次点击会被切换两次（一开一关等于没反应）
    .onKeyEvent((e: KeyEvent) => {
      return this.handleKey(e);
    })
    // 光标一动就重新计时，让控制条不会在用户操作中途消失
    .onMouse((e: MouseEvent) => {
      if (this.uiVisible && e.action === MouseAction.Move) {
        this.scheduleHide();
      }
    })
  }

  private grabFocus(delay: number): void {
    setTimeout(() => {
      try {
        // 焦点固定交给隐藏的按键接收器，方向键才能稳定冒泡到 handleKey
        let ok: boolean = focusControl.requestFocus('keySink');
        if (!ok) {
          ok = focusControl.requestFocus('playerRoot');
        }
        hilog.info(DOMAIN, TAG, 'requestFocus -> %{public}s', String(ok));
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'requestFocus throw: %{public}s', (err as Error).message);
      }
    }, delay);
  }

  private handleKey(e: KeyEvent): boolean {
    const code: number = e.keyCode;
    const down: boolean = e.type === KeyType.Down;
    hilog.info(DOMAIN, TAG, 'key %{public}d %{public}s', code, down ? 'DOWN' : 'UP');

      if (code === KeyCode.KEYCODE_DPAD_LEFT || code === KeyCode.KEYCODE_DPAD_RIGHT) {
        if (down) {
          this.beginSeek(code === KeyCode.KEYCODE_DPAD_RIGHT ? 1 : -1);
        } else {
          this.endSeek();
        }
        return true;
      }
      if (code === KeyCode.KEYCODE_DPAD_CENTER || code === KeyCode.KEYCODE_ENTER
        || code === KeyCode.KEYCODE_NUMPAD_ENTER) {
        if (down) {
          this.okDown();
        } else {
          this.okUp();
        }
        return true;
      }
      if (code === KeyCode.KEYCODE_DPAD_UP) {
        if (down) {
          this.changeSpeed(1);
        }
        return true;
      }
      if (code === KeyCode.KEYCODE_DPAD_DOWN) {
        if (down) {
          this.changeSpeed(-1);
        }
        return true;
      }
      if (code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE || code === KeyCode.KEYCODE_MEDIA_PLAY
        || code === KeyCode.KEYCODE_MEDIA_PAUSE || code === KeyCode.KEYCODE_PLAYPAUSE) {
        if (down) {
          this.togglePlay();
        }
        return true;
      }
      if (code === KeyCode.KEYCODE_BACK) {
        if (down) {
          this.saveAndExit();
        }
        return true;
      }
    return false;
  }
}
