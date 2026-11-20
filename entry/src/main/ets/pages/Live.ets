import { router } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { common } from '@kit.AbilityKit';
import { ConfigStore } from '../utils/ConfigStore';
import { AppState } from '../utils/AppState';
import { LiveGroup, LiveChannel } from '../utils/LiveApi';
import { LiveSrcProbe } from '../utils/LiveSrcProbe';
import { LiveMarkStore, LiveFav } from '../utils/LiveMarkStore';
import { EpgStore, EpgNowNext, EpgProg } from '../utils/EpgStore';
import { LiveCfg } from '../model/TvBoxModels';
import { SideNav } from '../components/SideNav';
import { LivePreview } from '../components/LivePreview';

const VIEW_FAV: number = 0;
const VIEW_ALL: number = 1;

/**
 * 直播页：解析配置里的 lives（txt 频道表 / m3u 播放列表），左侧分组、右侧频道。
 *
 * 两个跟"能不能用"直接相关的小功能：
 *   - 收藏：左侧分组列表最上面一行「★ 收藏 (N)」，样式与分组行完全一致；只读本机收藏文件，
 *     跟直播源载入成功与否无关；点开是独立收藏视图，右上角有「清除全部」（二次确认），
 *     点任意分组即可回到直播频道；格子里点右上角星标可取消（点星不会播放）
 *   - 已点过：点过的频道整格变暗，避免对着一堆死频道反复点
 *
 * 还有一件：配置里的 lives 常有好几个是空壳（302 / 502 / 只有注释），
 * 进页面先探活，能出频道的才上屏；只剩一个能用时连切换栏都不显示。
 */
@Entry
@Component
struct Live {
  /** 配置里的全部直播源（含空壳，仅用于「有没有源」判断与隐藏计数） */
  @State lives: LiveCfg[] = [];
  /** 探活通过的直播源：切换栏只认这份 */
  @State okLives: LiveCfg[] = [];
  /** 已确认是空壳、被藏起来的源个数 */
  @State hiddenCount: number = 0;
  /** 首屏逐个试源时的进度提示 */
  @State probeTip: string = '';
  @State liveIdx: number = 0;
  @State groups: LiveGroup[] = [];
  /** 实际渲染用的分组：只含直播源自己的分组，收藏由左上角按钮独立展示 */
  @State uiGroups: LiveGroup[] = [];
  @State groupIdx: number = 0;
  /** 当前视图：收藏 / 全部频道 */
  @State viewMode: number = VIEW_FAV;
  /** 焦点频道在 curChannels() 里的下标；大卡预览只认它 */
  @State @Watch('onFocusIdxChanged') focusIdx: number = 0;
  /** 预览真正播起来的线路，进入播放页时继承它，避免换个线路重新加载 */
  @State previewPlayingUrl: string = '';
  /** 是否展开右上角「分类」下拉列表（仅全部频道视图） */
  @State showGroups: boolean = false;
  /** 「清除全部」的二次确认 */
  @State confirmClearFav: boolean = false;
  @State loading: boolean = false;
  @State err: string = '';
  /** 收藏 / 取消收藏后的即时反馈 */
  @State tip: string = '';
  /** 收藏地址快照，用于渲染与判断（Store 里也有一份，避免每次读文件） */
  @State favUrls: string[] = [];
  /** 遥控器焦点标记（自绘焦点态） */
  @State focusId: string = '';
  /** 刚点过星标的时间戳：GridItem 的 onClick 会跟着触发，用它挡掉"收藏顺手把片子打开" */
  private lastStarTs: number = 0;
  private ctx: common.Context | null = null;
  /**
   * 节目单心跳：EPG 是异步载入的，「正在播 / 接下来」还要随时间往前推，
   * 所以用一个每分钟 +1 的计数让相关卡片重绘（不靠定时重排整页数据）。
   */
  @State epgTick: number = 0;
  private epgTimer: number = -1;

  aboutToAppear(): void {
    this.boot();
  }

  aboutToDisappear(): void {
    if (this.epgTimer >= 0) {
      clearInterval(this.epgTimer);
      this.epgTimer = -1;
    }
  }

  /** 后台把节目单准备好；成功或失败都要打 tick，界面才好从「N 条线路」切到「正在播」 */
  private startEpg(ctx: common.Context): void {
    try {
      EpgStore.init(ctx);
    } catch (e) {
      // 节目单读缓存失败不该影响直播页本身
    }
    if (EpgStore.hasData()) {
      this.epgTick++;
    }
    if (this.epgTimer < 0) {
      this.epgTimer = setInterval(() => { this.epgTick++; }, 60000);
    }
    EpgStore.ensure(ctx).then((changed: boolean) => {
      if (changed) {
        this.epgTick++;
      }
    }).catch(() => {});
  }

  private async boot(): Promise<void> {
    try {
      const ctx = getContext(this) as common.Context;
      this.ctx = ctx;
      this.refreshMarks();
      // 进来先落在收藏：点开直播多半是看常看的几个频道，不用等网络直播源探活。
      // 放在读配置之前，首帧就是收藏，不会先闪一下加载态。
      if (this.favUrls.length > 0) {
        this.viewMode = VIEW_FAV;
      } else {
        this.viewMode = VIEW_ALL;
      }
      this.startEpg(ctx);
      await ConfigStore.init(ctx);
      // 直播源可以跟点播源不同地址（设置页可单独载入），这里统一读 AppState.lives
      this.lives = AppState.lives;
      if (this.lives.length === 0) {
        // 没有直播源时收藏照样能看：收藏只认本机文件
        this.rebuildGroups();
        return;
      }
      await this.openFirstGood();
    } catch (e) {
      this.loading = false;
      this.probeTip = '';
      this.err = '直播源加载失败：' + (e as Error).message;
    }
  }

  /**
   * 并行探活所有 lives，谁先出频道谁先上屏。
   *
   * 以前是串行逐个 await：配置里常混着 302 / 502 的空壳，每个都要等满
   * connectTimeout + readTimeout，最后一个才是能用的源时，页面会长时间空白，
   * 看起来就像崩了。现在慢源在后台跑，不挡着好源上屏；单个源抛异常
   * 也只算它自己失败，不会把整页拖进错误态。
   */
  private async openFirstGood(): Promise<void> {
    this.loading = true;
    this.err = '';
    this.groups = [];
    this.uiGroups = [];
    this.okLives = [];
    this.hiddenCount = 0;
    this.probeTip = '正在加载直播源…';
    const total: number = this.lives.length;
    if (total === 0) {
      this.loading = false;
      return;
    }
    let done: boolean = false;
    let finished: number = 0;
    for (let i = 0; i < total; i++) {
      const live: LiveCfg = this.lives[i];
      LiveSrcProbe.load(live).then((gs: LiveGroup[] | null) => {
        finished = finished + 1;
        if (gs !== null && !done) {
          done = true;
          this.okLives = [live];
          this.liveIdx = 0;
          this.groups = gs;
          this.loading = false;
          this.probeTip = '';
          this.rebuildGroups();
        } else if (gs !== null) {
          // 后到的好源只补进切换栏，别把用户已经在看的频道表换掉
          const next: LiveCfg[] = this.okLives.slice();
          next.push(live);
          this.okLives = next;
        } else {
          this.hiddenCount = this.hiddenCount + 1;
        }
        if (finished === total && !done) {
          this.loading = false;
          this.probeTip = '';
          this.err = '这 ' + total + ' 个直播源都没解析出频道'
            + (LiveSrcProbe.lastReason().length > 0 ? '：' + LiveSrcProbe.lastReason() : '');
        }
      }).catch(() => {
        finished = finished + 1;
        this.hiddenCount = this.hiddenCount + 1;
        if (finished === total && !done) {
          this.loading = false;
          this.probeTip = '';
          this.err = '这 ' + total + ' 个直播源都没解析出频道';
        }
      });
    }
  }

  private async loadLive(idx: number): Promise<void> {
    if (idx < 0 || idx >= this.okLives.length) {
      return;
    }
    this.liveIdx = idx;
    // 点了某个直播源就回到该源的分组，别还停在收藏视图里
    this.viewMode = VIEW_ALL;
    this.confirmClearFav = false;
    this.loading = true;
    this.err = '';
    this.groups = [];
    this.uiGroups = [];
    this.groupIdx = 0;
    const gs: LiveGroup[] | null = await LiveSrcProbe.load(this.okLives[idx]);
    if (gs === null) {
      // 探活过的源一般走不到这里；真走到说明地址临时抽了，直接把原因摊开
      const why: string = LiveSrcProbe.badReason(this.okLives[idx].url);
      this.err = '这个直播源没有解析到频道' + (why.length > 0 ? '：' + why : '');
    } else {
      this.groups = gs;
      this.rebuildGroups();
    }
    this.loading = false;
  }

  private refreshMarks(): void {
    if (this.ctx === null) {
      return;
    }
    const f: string[] = [];
    for (const it of LiveMarkStore.favs(this.ctx)) {
      f.push(it.url);
    }
    this.favUrls = f;
  }

  /** 只放直播源自身的分组（收藏不再混进来），尽量保持当前选中的分组不变 */
  private rebuildGroups(): void {
    const keepName: string = (this.uiGroups.length > 0 && this.groupIdx < this.uiGroups.length)
      ? this.uiGroups[this.groupIdx].name : '';
    const out: LiveGroup[] = [];
    for (const g of this.groups) {
      out.push(g);
    }
    this.uiGroups = out;
    this.focusFirstChannel();
    let next: number = 0;
    if (keepName.length > 0) {
      for (let i = 0; i < out.length; i++) {
        if (out[i].name === keepName) {
          next = i;
          break;
        }
      }
    }
    this.groupIdx = next;
  }

  /**
   * 把默认焦点放到第一个频道卡。
   *
   * 频道表还没渲染完时，ArkUI 会抛「This component has unfocusable ancestor」(150002)；
   * 这句在定时器回调里，未捕获异常会被系统判成 JsError 直接杀掉进程——
   * 设成影视仓的大频道表后进直播页闪退，就是这个原因。所以异常必须吞掉，
   * 隔一会儿再试一次；两次都不成就把焦点交给系统默认，不再重试。
   */
  private focusFirstChannel(): void {
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('live-ch-0');
      } catch (e) {
        setTimeout(() => {
          try {
            this.getUIContext().getFocusController().requestFocus('live-ch-0');
          } catch (err) {
            // 焦点不是必需功能，放弃即可
          }
        }, 700);
      }
    }, 400);
  }

  /** 收藏频道：只读本机收藏文件，不看 lives、不看探活结果 */
  private favChannels(): LiveChannel[] {
    const out: LiveChannel[] = [];
    if (this.ctx === null) {
      return out;
    }
    for (const f of LiveMarkStore.favs(this.ctx)) {
      const ch: LiveChannel = {
        id: f.name, name: f.name, url: f.url, logo: '',
        lines: [{ name: '', url: f.url }]
      };
      out.push(ch);
    }
    return out;
  }

  private curChannels(): LiveChannel[] {
    if (this.viewMode === VIEW_FAV) {
      return this.favChannels();
    }
    if (this.uiGroups.length === 0 || this.groupIdx >= this.uiGroups.length) {
      return [];
    }
    return this.uiGroups[this.groupIdx].channels;
  }

  /** 焦点频道的预览地址：优先上次放出来的线路，避免大卡一直撞死线 */
  private focusChannel(): LiveChannel | null {
    const list: LiveChannel[] = this.curChannels();
    if (list.length === 0) {
      return null;
    }
    if (this.focusIdx < 0 || this.focusIdx >= list.length) {
      this.focusIdx = 0;
    }
    return list[this.focusIdx];
  }

  /** 焦点一变就清掉上一频道的预览线路，防止进播放页时继承错频道 */
  private onFocusIdxChanged(): void {
    this.previewPlayingUrl = '';
  }

  /** 大卡重建 key 列表：无焦点时为空（ForEach 不渲染），否则只含当前焦点频道一项 */
  private focusCardKeys(): string[] {
    const ch: LiveChannel | null = this.focusChannel();
    if (ch === null) {
      return [];
    }
    return [this.previewKeyOf(ch)];
  }

  /** 预览组件的重建 key：频道 + 当前线路，两者任一变化都强制重建播放器 */
  private previewKeyOf(ch: LiveChannel): string {
    const key: string = ch.id.length > 0 ? ch.id : ch.name;
    return key + '|' + this.previewUrlOf(ch);
  }

  private previewUrlOf(ch: LiveChannel): string {
    const urls: string[] = this.lineUrls(ch);
    if (urls.length === 0) {
      return '';
    }
    const key: string = ch.id.length > 0 ? ch.id : ch.name;
    if (this.ctx !== null) {
      const good: string = LiveMarkStore.lastGood(this.ctx, key);
      if (urls.indexOf(good) >= 0) {
        return good;
      }
    }
    return urls[0];
  }

  /** 一个频道的全部线路地址（合并后可能有好几条） */
  private lineUrls(ch: LiveChannel): string[] {
    const out: string[] = [];
    for (const l of ch.lines) {
      out.push(l.url);
    }
    if (out.length === 0 && ch.url.length > 0) {
      out.push(ch.url);
    }
    return out;
  }

  private isFav(ch: LiveChannel): boolean {
    if (this.favUrls.indexOf(ch.url) >= 0) {
      return true;
    }
    for (const u of this.lineUrls(ch)) {
      if (this.favUrls.indexOf(u) >= 0) {
        return true;
      }
    }
    return false;
  }

  private curGroupName(): string {
    const gs: LiveGroup[] = this.uiGroups;
    if (this.groupIdx < gs.length) {
      return gs[this.groupIdx].name;
    }
    return '';
  }

  private toggleFav(ch: LiveChannel): void {
    if (this.ctx === null) {
      return;
    }
    this.lastStarTs = Date.now();
    const f: LiveFav = {
      name: ch.name, url: ch.url,
      group: this.viewMode === VIEW_FAV ? '★ 收藏' : this.curGroupName()
    };
    const on: boolean = LiveMarkStore.toggleFav(this.ctx, f, this.lineUrls(ch));
    this.refreshMarks();
    this.rebuildGroups();
    this.tip = (on ? '已收藏「' : '已取消收藏「') + ch.name + '」';
  }

  private play(ch: LiveChannel): void {
    // 星标刚被点过就跳过：同一次点击冒泡上来的 onClick 不该触发播放
    if (Date.now() - this.lastStarTs < 600) {
      return;
    }
    const urls: string[] = this.lineUrls(ch);
    if (urls.length === 0) {
      return;
    }
    const key: string = ch.id.length > 0 ? ch.id : ch.name;
    // 线路优先级：预览此刻真正在播的那条 > 上次能放出来的 > 第一条。
    // 大卡预览已经把这条线路拉通了，进播放页继续用它，不然会重新加载、黑屏一次。
    let start: number = 0;
    let matched: boolean = false;
    const playingUrl: string = this.previewPlayingUrl;
    if (playingUrl.length > 0) {
      for (let i = 0; i < urls.length; i++) {
        if (urls[i] === playingUrl) {
          start = i;
          matched = true;
          break;
        }
      }
    }
    if (!matched && this.ctx !== null) {
      const good: string = LiveMarkStore.lastGood(this.ctx, key);
      if (good.length > 0) {
        for (let i = 0; i < urls.length; i++) {
          if (urls[i] === good) {
            start = i;
            break;
          }
        }
      }
    }
    router.pushUrl({
      url: 'pages/Player',
      params: {
        url: urls[start],
        title: ch.name,
        flag: 'live',
        progId: '',
        isLive: true,
        // 同一频道的其余线路一起带过去，播放页可以「换线路」，失败还会自动试下一条
        lines: urls,
        lineIdx: start,
        liveKey: key
      }
    });
  }

  /** 频道台标文字：中文取首字，英文数字连取两位（CCTV-1 → CC） */
  private logoText(ch: LiveChannel): string {
    const n: string = ch.name.trim();
    if (n.length === 0) {
      return '·';
    }
    const first: string = n.substring(0, 1);
    if (/[A-Za-z0-9]/.test(first)) {
      return n.length >= 2 ? n.substring(0, 2).toUpperCase() : first.toUpperCase();
    }
    return first;
  }

  /** 台标底色：按频道名散列取一个稳定色，同名永远同色 */
  private logoColor(ch: LiveChannel): string {
    const palette: string[] = [
      '#D8443C', '#2F6FD0', '#D9861F', '#12A38F',
      '#7A4CD9', '#3B9A4E', '#C4417A', '#4A6FA5'
    ];
    let h: number = 0;
    for (let i = 0; i < ch.name.length; i++) {
      h = (h * 31 + ch.name.charCodeAt(i)) % 9973;
    }
    return palette[h % palette.length];
  }

  /** 清空收藏：第一次点只进入确认态，避免遥控误触一次清掉 49 个频道 */
  private clearAllFavs(): void {
    if (!this.confirmClearFav) {
      this.confirmClearFav = true;
      return;
    }
    if (this.ctx === null) {
      return;
    }
    const n: number = this.favUrls.length;
    LiveMarkStore.clearFavs(this.ctx);
    this.refreshMarks();
    this.rebuildGroups();
    this.confirmClearFav = false;
    this.tip = '已清除 ' + n.toString() + ' 个收藏';
  }

  /** 数字键 1-9 选前 9 个频道，0 选第 10 个；菜单键展开/收起分类下拉 */
  private handleKey(e: KeyEvent): boolean {
    if (e.type !== KeyType.Down) {
      return false;
    }
    const code: number = e.keyCode;
    if (code === KeyCode.KEYCODE_MENU) {
      if (this.viewMode === VIEW_ALL && this.uiGroups.length > 1) {
        this.showGroups = !this.showGroups;
        return true;
      }
      return false;
    }
    let digit: number = -1;
    if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
      digit = code - KeyCode.KEYCODE_0;
    } else if (code >= KeyCode.KEYCODE_NUMPAD_0 && code <= KeyCode.KEYCODE_NUMPAD_0 + 9) {
      digit = code - KeyCode.KEYCODE_NUMPAD_0;
    }
    if (digit < 0) {
      return false;
    }
    const idx: number = digit === 0 ? 9 : digit - 1;
    if (idx >= this.curChannels().length) {
      return true;
    }
    this.focusIdx = idx;
    this.focusId = 'c-' + idx.toString();
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('live-ch-' + idx.toString());
      } catch (err) {}
    }, 30);
    return true;
  }

  private epgProgress(ch: LiveChannel, tick: number): number {
    if (tick < 0) {
      return 0;
    }
    const nn: EpgNowNext | null = this.nowNextOf(ch);
    if (nn === null || nn.cur === null || nn.cur.e <= nn.cur.s) {
      return 0;
    }
    const pct: number = Math.round((Date.now() - nn.cur.s) * 100 / (nn.cur.e - nn.cur.s));
    return pct < 0 ? 0 : (pct > 100 ? 100 : pct);
  }

  private epgRange(ch: LiveChannel, tick: number): string {
    if (tick < 0) {
      return '';
    }
    const nn: EpgNowNext | null = this.nowNextOf(ch);
    if (nn === null || nn.cur === null) {
      return '';
    }
    return this.hhmm(nn.cur.s) + ' - ' + this.hhmm(nn.cur.e);
  }

  @Builder
  viewTab(label: string, mode: number, key: string, onTap: () => void) {
    Column() {
      Text(label)
        .fontSize(15)
        .fontWeight(this.viewMode === mode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.viewMode === mode ? '#FFB37A' : (this.focusId === key ? '#FFFFFF' : '#9A9AA6'))
        .height(30)
        .maxLines(1)
      Row()
        .width(this.viewMode === mode ? 28 : 0)
        .height(2)
        .borderRadius(1)
        .backgroundColor('#FF8A3D')
    }
    .height(46)
    .padding({ left: 16, right: 16 })
    .borderRadius(8)
    .focusable(true)
    .onFocus(() => { this.focusId = key; })
    .onBlur(() => { this.focusId = ''; })
    .onClick(onTap)
  }

  /** 右上角「分类」下拉浮层：列出全部频道的所有分组，点一项切换 */
  @Builder
  groupDropdown() {
    Scroll() {
      Column() {
        ForEach(this.uiGroups, (g: LiveGroup, idx: number) => {
        Row() {
          Row()
            .width(3)
            .height(20)
            .borderRadius(2)
            .backgroundColor(idx === this.groupIdx ? '#FF8A3D' : Color.Transparent)
            .margin({ right: 10 })
          Text(g.name)
            .fontSize(14)
            .fontWeight(idx === this.groupIdx ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(idx === this.groupIdx ? '#FFB37A' : '#C9C9D4')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(g.channels.length.toString() + ' 个')
            .fontSize(11)
            .fontColor('#6E6E7A')
            .margin({ left: 8 })
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 14 })
        .borderRadius(8)
        .backgroundColor(idx === this.groupIdx ? '#1FFF8A3D'
          : (this.focusId === ('gd-' + idx) ? '#1AFFFFFF' : Color.Transparent))
        .focusable(true)
        .onFocus(() => { this.focusId = 'gd-' + idx; })
        .onBlur(() => { this.focusId = ''; })
        .onClick(() => {
          this.groupIdx = idx;
          this.focusIdx = 0;
          this.showGroups = false;
          this.tip = '';
        })
      }, (g: LiveGroup, idx: number) => g.name + String(idx))
      }
      .width('100%')
    }
    .width(260)
    .constraintSize({ maxHeight: 480 })
    .scrollBar(BarState.Off)
    .padding(6)
    .borderRadius(12)
    .backgroundColor('#141720')
    .border({ width: 1, color: '#333744' })
    .shadow({ radius: 24, color: '#99000000', offsetY: 8 })
    .position({ right: 52, top: 76 })
    .zIndex(100)
  }

  @Builder
  focusCard(ch: LiveChannel) {
    Column() {
      // 电视机：屏幕占满大卡宽度，无外加背景
      Column() {
        Stack() {
          // 关键：用 key 强制预览组件随频道重建，不能只靠 @Prop @Watch。
          // 切台若只换 url 而不重建，播放器实例和 phase 会停在上一频道，
          // 表现为「点小卡毫无反应 / 雪花屏只在第一次出现」。
          ForEach([this.previewKeyOf(ch)], (key: string) => {
            LivePreview({
              url: this.previewUrlOf(ch),
              onStateChange: (phase: string, url: string) => {
                // 旧预览实例 release 前的 playing 回调可能晚到，只认当前焦点频道的线路，
                // 否则进播放页会继承到上一个频道的地址。
                if (phase === 'playing' && this.lineUrls(ch).indexOf(url) >= 0) {
                  this.previewPlayingUrl = url;
                }
              }
            })
          }, (key: string) => key)
          Text('点画面进入全屏')
            .fontSize(11)
            .fontColor('#D8D8E0')
            .backgroundColor('#99000000')
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .position({ right: 10, bottom: 10 })
        }
        .width('100%')
        .height(300)
        .borderRadius(6)
        .clip(true)
        .onClick(() => { this.play(ch); })

        // 机身底部铭牌：左侧频道名 + 收藏，右侧播放说明
        Row({ space: 16 }) {
          Row({ space: 8 }) {
            Text(ch.name)
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 300 })
            Text(this.isFav(ch) ? '★' : '')
              .fontSize(15)
              .fontColor('#FFB300')
          }
          .alignItems(VerticalAlign.Center)
          .flexShrink(0)

          Blank()

          // 右侧播放说明：正在播 / 接下来 / 进度
          Column({ space: 4 }) {
            if (this.epgNowText(ch, this.epgTick).length > 0) {
              Text(this.epgNowText(ch, this.epgTick))
                .fontSize(15)
                .fontColor('#FFD9BC')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            if (this.epgNextText(ch, this.epgTick).length > 0) {
              Text(this.epgNextText(ch, this.epgTick))
                .fontSize(12)
                .fontColor('#9A9AA6')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            if (this.epgRange(ch, this.epgTick).length > 0) {
              Row({ space: 10 }) {
                Text(this.epgRange(ch, this.epgTick))
                  .fontSize(11)
                  .fontColor('#A9A9B4')
                Text(this.epgProgress(ch, this.epgTick).toString() + '%')
                  .fontSize(11)
                  .fontColor('#A9A9B4')
                Text(this.lineUrls(ch).length > 1
                  ? this.lineUrls(ch).length.toString() + ' 条线路'
                  : '单线路')
                  .fontSize(11)
                  .fontColor('#7E7E8A')
              }
              Row() {
                Row()
                  .width(this.epgProgress(ch, this.epgTick).toString() + '%')
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor('#FF8A3D')
              }
              .width('100%')
              .height(4)
              .borderRadius(2)
              .backgroundColor('#2A2C35')
            } else {
              Text(this.lineUrls(ch).length > 1
                ? this.lineUrls(ch).length.toString() + ' 条线路可选'
                : '单线路')
                .fontSize(11)
                .fontColor('#7E7E8A')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 4 })
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .borderRadius(14)
      .backgroundColor('#1C1F2A')
      .border({ width: 1, color: '#3A3F4E' })

      // 电视机底座
      Row()
        .width(60)
        .height(10)
        .backgroundColor('#2A2E3C')
      Row()
        .width(148)
        .height(5)
        .borderRadius(3)
        .backgroundColor('#3A3F4E')

      // 今天接下来：占满大卡下方空区，填满节目单，无数据只留一行淡提示
      Column({ space: 9 }) {
        Row({ space: 8 }) {
          Row()
            .width(3)
            .height(14)
            .borderRadius(2)
            .backgroundColor('#FF8A3D')
          Text('今天接下来')
            .fontSize(13)
            .fontColor('#B9B9C6')
        }
        .width('100%')

        ForEach(this.upcomingOf(ch, this.epgTick), (p: EpgProg, idx: number) => {
          Row({ space: 12 }) {
            Text(this.hhmm(p.s))
              .fontSize(13)
              .fontColor(idx === 0 ? '#FFB37A' : '#8A8A96')
              .width(42)
            Text(p.t)
              .fontSize(14)
              .fontColor(idx === 0 ? '#EDEDF2' : '#A9A9B6')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
        }, (p: EpgProg) => p.s.toString() + p.t)

        if (this.upcomingOf(ch, this.epgTick).length === 0) {
          Text('暂无节目单')
            .fontSize(12)
            .fontColor('#6E6E7A')
        }
      }
      .width('100%')
      .margin({ top: 18, left: 12, right: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  @Builder
  staticChannelCard(ch: LiveChannel, idx: number) {
    Row({ space: 11 }) {
      Stack() {
        Row()
          .width(42)
          .height(42)
          .borderRadius(12)
          .backgroundColor(this.logoColor(ch))
        Text(this.logoText(ch))
          .fontSize(this.logoText(ch).length > 1 ? 15 : 19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(42)
      .height(42)

      Column({ space: 3 }) {
        Text(ch.name)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EDEDF2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.epgNowText(ch, this.epgTick).length > 0) {
          Text(this.epgNowText(ch, this.epgTick))
            .fontSize(11)
            .fontColor('#FFD9BC')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.epgNextText(ch, this.epgTick).length > 0
            ? this.epgNextText(ch, this.epgTick)
            : ch.lines.length > 1 ? ch.lines.length.toString() + ' 条线路' : '单线路')
            .fontSize(10)
            .fontColor('#6E6E7A')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        } else {
          Text(ch.lines.length > 1 ? ch.lines.length.toString() + ' 条线路' : '单线路')
            .fontSize(11.5)
            .fontColor('#7E7E8A')
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.isFav(ch) ? '★' : '☆')
        .fontSize(15)
        .fontColor(this.isFav(ch) ? '#FFB300' : '#5F5F6B')
        .padding({ left: 4, right: 8, top: 6, bottom: 6 })
        .onClick(() => { this.toggleFav(ch); })
    }
    .width('100%')
    .height(82)
    .padding({ left: 14, right: 8 })
    .borderRadius(14)
    .backgroundColor(this.focusIdx === idx ? '#24202B' : '#151720')
    .border({ width: this.focusIdx === idx ? 1 : 0, color: '#FF8A3D' })
    .id('live-ch-' + idx)
    .focusable(true)
    .defaultFocus(idx === 0)
    .onFocus(() => {
      this.focusId = 'c-' + idx;
      this.focusIdx = idx;
    })
    .onBlur(() => {
      this.focusId = '';
    })
    .onKeyEvent((e: KeyEvent) => { return this.handleKey(e); })
    .onClick(() => {
      if (Date.now() - this.lastStarTs < 600) {
        return;
      }
      // 点小卡只切换预览，不进入播放页
      this.focusIdx = idx;
      this.focusId = 'c-' + idx;
      setTimeout(() => {
        try {
          this.getUIContext().getFocusController().requestFocus('live-ch-' + idx.toString());
        } catch (err) {}
      }, 30);
    })
  }

  @Builder
  topChip(label: string, on: boolean, urlKey: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(13.5)
        .fontWeight(on ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(on ? '#150A04' : '#B9B9C6')
        .maxLines(1)
    }
    .height(42)
    .padding({ left: 18, right: 18 })
    .borderRadius(21)
    .backgroundColor(on ? '#FF8A3D' : '#10FFFFFF')
    .border({ width: 1, color: this.focusId === urlKey ? '#FFD9BC' : (on ? '#FF8A3D' : '#1AFFFFFF') })
    .focusable(true)
    .onFocus(() => { this.focusId = urlKey; })
    .onBlur(() => { this.focusId = ''; })
    .onClick(onTap)
  }

  /** 小号 chip：直播源用，比顶栏主 chip 矮一圈，多个能横向铺开不占地方 */
  @Builder
  srcChip(label: string, on: boolean, urlKey: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(11.5)
        .fontWeight(on ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(on ? '#150A04' : '#A9A9B6')
        .maxLines(1)
    }
    .height(30)
    .padding({ left: 11, right: 11 })
    .borderRadius(15)
    .backgroundColor(on ? '#FF8A3D' : '#10FFFFFF')
    .border({ width: 1, color: this.focusId === urlKey ? '#FFD9BC' : (on ? '#FF8A3D' : '#1AFFFFFF') })
    .focusable(true)
    .onFocus(() => { this.focusId = urlKey; })
    .onBlur(() => { this.focusId = ''; })
    .onClick(onTap)
  }

  /** HH:mm（本地时区），节目单里到处要用 */
  private hhmm(ms: number): string {
    const d: Date = new Date(ms);
    const h: string = d.getHours().toString();
    const m: string = d.getMinutes().toString();
    return (h.length < 2 ? '0' + h : h) + ':' + (m.length < 2 ? '0' + m : m);
  }

  private nowNextOf(ch: LiveChannel): EpgNowNext | null {
    return EpgStore.nowNext(ch.id, ch.name);
  }

  /** 接下来 3 档；tick 只为把 epgTick 读进渲染依赖，节目单随时间往前推 */
  private upcomingOf(ch: LiveChannel, tick: number): EpgProg[] {
    if (tick < 0) {
      return [];
    }
    return EpgStore.upcoming(ch.id, ch.name, 3);
  }

  /**
   * 正在播的一行文字。tick 只是为了把 epgTick 这个状态读进渲染依赖里：
   * @Builder 里不直接读的话，EPG 载入完成不会触发重绘。
   */
  private epgNowText(ch: LiveChannel, tick: number): string {
    if (tick < 0) {
      return '';
    }
    const nn: EpgNowNext | null = this.nowNextOf(ch);
    if (nn === null || nn.cur === null) {
      return '';
    }
    return '正在播 · ' + nn.cur.t;
  }

  private epgNextText(ch: LiveChannel, tick: number): string {
    if (tick < 0) {
      return '';
    }
    const nn: EpgNowNext | null = this.nowNextOf(ch);
    if (nn === null || nn.next === null) {
      return '';
    }
    const p: EpgProg = nn.next;
    return '接下来 ' + this.hhmm(p.s) + ' ' + p.t;
  }

  build() {
    Row() {
      SideNav({ active: 2 })
      Stack({ alignContent: Alignment.TopStart }) {
        // 背景：冷蓝氛围光 + 深色底
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 150,
            colors: [['#0C1226', 0.0], ['#08090B', 0.62], ['#08090B', 1.0]]
          })
        Column()
          .width(1100)
          .height(700)
          .borderRadius(550)
          .linearGradient({
            angle: 120,
            colors: [['#332A46FF', 0.0], ['#0A1A2AFF', 0.6], ['#00000000', 1.0]]
          })
          .blur(60)
          .margin({ left: 1100, top: -260 })

        Column() {
          // ---- 顶栏：标题 + 视图标签 + 右侧操作 ----
          Row() {
            Text('直播')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')

            // 视图标签挪到顶栏，紧跟标题，隔开一点
            Row({ space: 4 }) {
              this.viewTab('收藏', VIEW_FAV, 'view-fav', () => {
                this.viewMode = VIEW_FAV;
                this.focusIdx = 0;
                this.tip = '';
                this.showGroups = false;
              })
              this.viewTab('全部频道', VIEW_ALL, 'view-all', () => {
                this.viewMode = VIEW_ALL;
                this.focusIdx = 0;
                this.tip = '';
                this.confirmClearFav = false;
                this.showGroups = false;
              })
            }
            .margin({ left: 34 })

            Blank()

            Row({ space: 12 }) {
              // 可用直播源 chip：贴在频道按钮左侧，空源探活阶段已排除；多个向左铺开
              if (this.viewMode === VIEW_ALL && this.okLives.length > 0) {
                Row({ space: 6 }) {
                  ForEach(this.okLives, (l: LiveCfg, idx: number) => {
                    this.srcChip(l.name, idx === this.liveIdx, 'src-' + idx, () => {
                      this.loadLive(idx);
                      this.showGroups = false;
                    })
                  }, (l: LiveCfg, idx: number) => l.name + String(idx))
                }
              }
              // 分类下拉：仅「全部频道」且有多个分组时出现，按钮显示当前分组名
              if (this.viewMode === VIEW_ALL && this.uiGroups.length > 1) {
                this.topChip(this.curGroupName() + ' ▾', this.showGroups, 'groupdrop', () => {
                  this.showGroups = !this.showGroups;
                })
              }
              // 「清空收藏」只属于收藏视图；二次确认提示贴在按钮左边
              if (this.viewMode === VIEW_FAV && this.favUrls.length > 0) {
                if (this.confirmClearFav) {
                  Text('再按一下确认清空')
                    .fontSize(12)
                    .fontColor('#FFB37A')
                }
                this.topChip('清空收藏',
                  this.confirmClearFav, 'clearfav', () => { this.clearAllFavs(); })
              }
            }
          }
          .width('100%')
          .height(50)
          .alignItems(VerticalAlign.Center)
          .margin({ top: 20 })

          // ---- 分类改成右上角下拉按钮，这一行只留间距 ----
          Row()
            .width('100%')
            .height(20)

          // ---- 主体 ----
          if (this.lives.length === 0 && this.favUrls.length === 0) {
            Column({ space: 14 }) {
              Text('没有直播源')
                .fontSize(24)
                .fontColor('#EDEDF2')
              Text('打开设置，填入 m3u / txt 直播源')
                .fontSize(14)
                .fontColor('#8E8E9A')
              Text('打开设置')
                .fontSize(16)
                .fontColor('#150A04')
                .height(50)
                .padding({ left: 30, right: 30 })
                .borderRadius(25)
                .backgroundColor('#FF8A3D')
                .textAlign(TextAlign.Center)
                .margin({ top: 10 })
                .focusable(true)
                .onClick(() => { router.replaceUrl({ url: 'pages/Settings' }).catch(() => {}); })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.viewMode === VIEW_ALL && this.loading) {
            Column({ space: 12 }) {
              LoadingProgress().width(46).height(46).color('#FF8A3D')
              Text(this.probeTip.length > 0 ? this.probeTip : '正在加载直播源…')
                .fontSize(13.5)
                .fontColor('#8E8E9A')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.viewMode === VIEW_ALL && this.err.length > 0) {
            Column({ space: 18 }) {
              Text(this.err)
                .fontSize(15)
                .fontColor('#FF8B7A')
                .textAlign(TextAlign.Center)
                .width(900)
              Text('重试')
                .fontSize(16)
                .fontColor('#EDEDF2')
                .height(50)
                .padding({ left: 32, right: 32 })
                .borderRadius(25)
                .backgroundColor('#16FFFFFF')
                .textAlign(TextAlign.Center)
                .focusable(true)
                .onClick(() => {
                  LiveSrcProbe.reset();
                  if (this.okLives.length > 0) {
                    this.loadLive(this.liveIdx);
                  } else {
                    this.openFirstGood();
                  }
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.curChannels().length === 0) {
            // 收藏 / 全部频道各自为空：整屏居中，避免左边大卡区半屏空白
            Column({ space: 14 }) {
              Text(this.viewMode === VIEW_FAV ? '还没有收藏频道' : '这个直播源没有频道')
                .fontSize(22)
                .fontColor('#EDEDF2')
              Text(this.viewMode === VIEW_FAV
                ? '切到「全部频道」，在频道右上角点 ☆ 收藏'
                : '换个直播源，或去设置检查源地址')
                .fontSize(13)
                .fontColor('#8E8E9A')
              if (this.viewMode === VIEW_FAV) {
                Text('去全部频道')
                  .fontSize(16)
                  .fontColor('#150A04')
                  .height(48)
                  .padding({ left: 30, right: 30 })
                  .borderRadius(24)
                  .backgroundColor('#FF8A3D')
                  .textAlign(TextAlign.Center)
                  .margin({ top: 10 })
                  .focusable(true)
                  .onClick(() => {
                    this.viewMode = VIEW_ALL;
                    this.focusIdx = 0;
                    this.tip = '';
                  })
              }
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Column() {
              if (this.tip.length > 0) {
                Text(this.tip)
                  .fontSize(12.5)
                  .fontColor('#FFB37A')
                  .width('100%')
                  .margin({ bottom: 8, left: 4 })
              }

              Row({ space: 20 }) {
                // 左半屏：焦点大卡（电视机外框 + 右侧播放说明）
                // 用 ForEach + key 强制重建：@Builder 按值传对象参数，焦点变了内部不刷新，
                // 必须靠 key 变化让整棵大卡子树重建，频道名/EPG/预览才会一起更新。
                Column() {
                  ForEach(this.focusCardKeys(), (key: string) => {
                    this.focusCard(this.focusChannel() as LiveChannel)
                  }, (key: string) => key)
                }
                .width('50%')
                .height('100%')
                .justifyContent(FlexAlign.Start)

                // 右半屏：频道小卡两两排列
                Column() {
                  Grid() {
                    ForEach(this.curChannels(), (ch: LiveChannel, idx: number) => {
                      GridItem() {
                        this.staticChannelCard(ch, idx)
                      }
                    }, (ch: LiveChannel, idx: number) => ch.name + String(idx) + ch.url)
                  }
                  .columnsTemplate('1fr 1fr')
                  .columnsGap(12)
                  .rowsGap(12)
                  .width('100%')
                  .layoutWeight(1)
                  .scrollBar(BarState.Off)
                }
                .layoutWeight(1)
                .height('100%')
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .layoutWeight(1)
            }
            .width('100%')
            .layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 48, right: 52, bottom: 26 })
        .alignItems(HorizontalAlign.Start)
        .onKeyEvent((e: KeyEvent) => { return this.handleKey(e); })
      }
      .layoutWeight(1)
      .height('100%')

      // 分类下拉浮层：放在主体之后，浮在内容之上
      if (this.showGroups && this.viewMode === VIEW_ALL && this.uiGroups.length > 1) {
        this.groupDropdown()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
