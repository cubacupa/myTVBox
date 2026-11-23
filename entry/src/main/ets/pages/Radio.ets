import { common } from '@kit.AbilityKit';
import { EpgNowNext, EpgProg } from '../utils/EpgStore';
import { RadioEpg } from '../utils/RadioEpg';
import { RadioStation, RadioApi } from '../utils/RadioApi';
import { RadioStore } from '../utils/RadioStore';
import { RadioPlayer } from '../utils/RadioPlayer';
import { SideNav } from '../components/SideNav';

/** 库里的三个视图：电台 / 我的收藏 / 最近播放 */
const TAB_ALL: number = 0;
const TAB_FAV: number = 1;
const TAB_RECENT: number = 2;

/**
 * 液晶屏动效，用户在底行手动切换三种：
 * 0 波浪（左侧竖直亮带向右铺成曲面）
 * 1 漩涡（多条旋臂绕中心旋转）
 * 2 放射（中心亮核向外密铺射线，各线长度伸缩，星系穿梭感）
 * Canvas 手绘，每帧只重画 284×92 这一块，不动 @State。
 * 只有 isLive() 为真才动，停了只留一条静线。
 */
const WAVE_W: number = 284;
const WAVE_H: number = 92;
const WAVE_CY: number = 46;
/** 网格 72 列 × 26 行 ≈ 1872 颗点/帧 */
const GRID_COLS: number = 72;
const GRID_ROWS: number = 26;
const FX_WAVE: number = 0;
const FX_VORTEX: number = 1;
const FX_RADIAL: number = 2;
/** 漩涡：铺满全屏的粒子网格列/行数 + 旋臂数 */
const VORTEX_COLS: number = 92;
const VORTEX_ROWS: number = 32;
const VORTEX_ARMS: number = 5;
/** 放射：射线条数 / 最长射线半径（够铺到四角）/ 纵向压扁比 / 画点步长 */
const RAY_COUNT: number = 168;
const RAY_MAX: number = 168;
const RAY_FLAT: number = 0.34;
const RAY_STEP: number = 3;

/** 放射线：固定角度，长度随时间在自己的基准上伸缩 */
interface Ray {
  ang: number;
  base: number;
  speed: number;
  phase: number;
  bright: boolean;
}

/** 唱片封套底色：深→浅双色，按 sid 取模分配，同一个台颜色固定 */
const DISC_COLORS: string[][] = [
  ['#3A2A5E', '#8E6FC4'], ['#1E4A4A', '#4FA9A0'], ['#5A2A32', '#C2606E'],
  ['#4A3A18', '#C79A3A'], ['#1F3A5A', '#5E95C4'], ['#3A1E4A', '#9A5EC4'],
  ['#1E4A2A', '#5EBE72'], ['#4A2A1E', '#C47A4A']
];

/** 左侧台标区的三个视图 */
const PTAB_REC: number = 0;
const PTAB_FAV: number = 1;
const PTAB_RECENT: number = 2;

/** 节目单浮层的一行 */
interface EpgRow {
  time: string;
  title: string;
  now: boolean;
}

/**
 * 电台库列表的懒加载数据源。
 *
 * 电台表两千多条，一次 ForEach 全铺出来，电视会卡在建列表那几百毫秒上。
 * 换台/换分类时整表 reload 一次即可——可见行只有十来行，重建代价可以忽略。
 */
class RadioSource implements IDataSource {
  private data: RadioStation[] = [];
  private ls: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(i: number): RadioStation {
    return this.data[i];
  }

  set(d: RadioStation[]): void {
    this.data = d;
    for (const l of this.ls) {
      l.onDataReloaded();
    }
  }

  registerDataChangeListener(l: DataChangeListener): void {
    if (this.ls.indexOf(l) < 0) {
      this.ls.push(l);
    }
  }

  unregisterDataChangeListener(l: DataChangeListener): void {
    const i: number = this.ls.indexOf(l);
    if (i >= 0) {
      this.ls.splice(i, 1);
    }
  }
}

/**
 * 网络电台。
 *
 * 左半边是一台「会说话的收音机」：液晶屏上只有真数据——台名、台标、当前节目、
 * 节目进度、下一档；六个按键全是真功能（音量、上一台/下一台、收藏、节目单）。
 * 右半边是电台库：分类下拉 + 电台/收藏/最近三个视图。
 *
 * 节目单来自电台自己的 EPG（RadioEpg）：直播页那套 xmltv 只有电视台，电台一条都没有；
 * 找得到就显示，找不到就留空，绝不为凑界面编节目名。
 */
@Entry
@Component
struct RadioPage {
  @State stations: RadioStation[] = [];
  @State cur: RadioStation | null = null;
  @State playing: boolean = false;
  /** 'buffering' 在拉流时显示，让用户知道点到了 */
  @State stateText: string = '';
  @State err: string = '';
  @State loading: boolean = true;
  /** 电台表刷新时的提示（首次进入要等这一下） */
  @State tip: string = '';

  @State vol: number = 65;
  @State volOsd: boolean = false;

  @State tab: number = TAB_ALL;
  @State group: string = '全部电台';
  /** 电台库搜索词：空表示不过滤 */
  @State kw: string = '';
  @State showGroups: boolean = false;
  /** 左侧台标区：推荐 / 收藏 / 最近 */
  @State ptab: number = PTAB_REC;

  @State showEpg: boolean = false;
  @State epgRows: EpgRow[] = [];

  /** 液晶屏上的节目信息 */
  @State epgNow: string = '';
  @State epgNowTime: string = '';
  @State epgNext: string = '';
  @State epgNextTime: string = '';
  @State epgPct: number = 0;

  @State clock: string = '';
  @State dateText: string = '';

  @State favOn: boolean = false;
  /** 收藏/最近的数量做成 @State：RadioStore 是普通静态数组，直接读它不会触发 chip 重绘 */
  @State favCount: number = 0;
  @State recentCount: number = 0;
  @State presetList: RadioStation[] = [];

  /** 每次换台/换分类 +1，列表 key 里带上它，保证选中态跟着重画 */
  @State listTick: number = 0;
  /** 节目换档时 +1：列表/精选格里的「正在播」靠它重画 */
  @State epgTick: number = 0;
  /** 液晶屏动效：0 波浪 / 1 漩涡 / 2 放射，用户在底行手动切换 */
  @State fxMode: number = FX_WAVE;

  private player: RadioPlayer = new RadioPlayer();
  private src: RadioSource = new RadioSource();
  private ctx: common.Context | null = null;
  private barTimer: number = -1;
  private clockTimer: number = -1;
  private osdTimer: number = -1;
  private epgTimer: number = -1;

  // 声波点阵：Canvas 由结构持有，定时器只重画 context，不动 @State
  private waveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private waveReady: boolean = false;
  private waveT: number = 0;
  private waveSpeed: number = 0.03;
  private waveSpeedTarget: number = 0.03;
  private waveSpeedTick: number = 0;
  /** 放射线场：实例字段持有，角度固定、每帧只改长度，不碰 @State */
  private rays: Ray[] = [];

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.Context;
    RadioStore.init(this.ctx);
    this.vol = RadioStore.volume();
    this.syncCounts();
    RadioApi.init(this.ctx);
    this.player.onState = (s: string) => this.onPlayerState(s);
    this.player.onFail = (m: string) => {
      this.err = m;
      this.playing = false;
      this.stateText = '';
    };
    this.clockTo();
    this.clockTimer = setInterval(() => {
      this.clockTo();
      this.refreshEpgLabels();
      // 节目单是后台异步落盘的，过一会儿自己就位；label 每 10 秒对一次表就够
    }, 10000);
    // 32ms 一帧≈31fps，只重画 Canvas，不碰界面状态
    this.barTimer = setInterval(() => {
      this.drawWave();
    }, 32);
    this.startEpg();
    this.boot();
  }

  aboutToDisappear(): void {
    if (this.barTimer >= 0) {
      clearInterval(this.barTimer);
      this.barTimer = -1;
    }
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    if (this.osdTimer >= 0) {
      clearTimeout(this.osdTimer);
      this.osdTimer = -1;
    }
    this.player.close();
  }

  // ---------------- 启动 ----------------

  private async boot(): Promise<void> {
    this.loading = true;
    if (!RadioApi.has()) {
      this.tip = '正在准备电台列表…';
      const err: string = await RadioApi.load(this.ctx as common.Context, false);
      if (err.length > 0 && !RadioApi.has()) {
        this.err = '电台列表加载失败：' + err;
        this.tip = '';
        this.loading = false;
        return;
      }
    }
    this.tip = '';
    this.loading = false;
    this.presetList = RadioApi.presets();
    const lastSid: string = RadioStore.lastSid();
    let start: RadioStation | null = (lastSid.length > 0) ? RadioApi.find(lastSid) : null;
    if (start === null && this.presetList.length > 0) {
      start = this.presetList[0];
    }
    if (start !== null) {
      this.selectStation(start, true);
    } else {
      this.refreshList();
    }
    // 缓存过期就悄悄换一份新的，不打扰当前播放
    if (!RadioApi.isFresh()) {
      RadioApi.load(this.ctx as common.Context, true).then((e: string) => {
        if (e.length === 0) {
          this.presetList = RadioApi.presets();
          this.refreshList();
        }
      });
    }
  }

  /** 节目单：直播页那套 xmltv 里没有电台，单独取（见 RadioEpg） */
  private startEpg(): void {
    if (this.ctx === null) {
      return;
    }
    try {
      RadioEpg.init(this.ctx);
    } catch (e) {
      // 节目单坏了不影响听台
    }
    this.refreshEpgLabels();
    RadioEpg.ensure(this.ctx).then((changed: boolean) => {
      if (changed) {
        this.refreshEpgLabels();
        // 列表每行都要重画一次，否则只有液晶屏有节目名
        this.refreshList();
      }
    }).catch(() => {});
  }

  // ---------------- 播放 ----------------

  /** RadioStore 改完必须同步一次计数，@Builder 才会重画 chip 上的数字 */
  private syncCounts(): void {
    this.favCount = RadioStore.favs().length;
    this.recentCount = RadioStore.recents().length;
  }

  /** 用户在底行点选动效 */
  private setFx(mode: number): void {
    this.fxMode = mode;
  }

  private selectStation(s: RadioStation, autoplay: boolean): void {
    this.cur = s;
    this.err = '';
    this.favOn = RadioStore.isFav(s.sid);
    this.refreshEpgLabels();
    this.refreshList();
    if (autoplay) {
      // 别抢在出声之前就写「正在播放」：状态位先挂「正在连接」，
      // 引擎真的进 playing 才由 onPlayerState 换回来（节奏方块也跟着它起跳）
      this.stateText = '正在连接';
      this.player.open(s.streams, this.vol, true).catch(() => {});
      this.playing = true;
      RadioStore.markPlayed(s.sid);
      this.syncCounts();
    }
  }

  private onPlayerState(s: string): void {
    if (s === 'playing') {
      this.playing = true;
      this.stateText = '';
      this.err = '';
    } else if (s === 'paused') {
      this.playing = false;
      this.stateText = '';
    } else if (s === 'buffering') {
      this.err = '';
      this.stateText = '正在连接';
    } else if (s === 'error') {
      this.playing = false;
      this.stateText = '';
    }
  }

  private togglePlay(): void {
    const c: RadioStation | null = this.cur;
    if (c === null) {
      return;
    }
    if (this.playing) {
      this.player.pause();
      this.playing = false;
      return;
    }
    this.playing = true;
    this.stateText = '';
    this.err = '';
    this.player.resume();
    RadioStore.markPlayed(c.sid);
    this.syncCounts();
  }

  /** 上一台 / 下一台：走当前可见列表，跟用户眼前看到的顺序一致 */
  private step(delta: number): void {
    const view: RadioStation[] = this.visibleList();
    if (view.length === 0) {
      return;
    }
    const curSid: string = (this.cur !== null) ? (this.cur as RadioStation).sid : '';
    let idx: number = -1;
    for (let i = 0; i < view.length; i++) {
      if (view[i].sid === curSid) {
        idx = i;
        break;
      }
    }
    const next: number = (idx < 0) ? 0 : (idx + delta + view.length) % view.length;
    this.selectStation(view[next], true);
  }

  private setVol(v: number): void {
    this.vol = Math.max(0, Math.min(100, v));
    RadioStore.setVolume(this.vol);
    this.player.setVolume(this.vol);
    this.volOsd = true;
    if (this.osdTimer >= 0) {
      clearTimeout(this.osdTimer);
    }
    this.osdTimer = setTimeout(() => {
      this.volOsd = false;
      this.osdTimer = -1;
    }, 1600);
  }

  private toggleFav(): void {
    const c: RadioStation | null = this.cur;
    if (c === null) {
      return;
    }
    this.favOn = RadioStore.toggleFav(c.sid);
    this.syncCounts();
    this.refreshList();
  }

  // ---------------- 列表 ----------------

  private visibleList(): RadioStation[] {
    const raw: RadioStation[] = this.rawList();
    const k: string = this.kw.trim().toLowerCase();
    if (k.length === 0) {
      return raw;
    }
    const out: RadioStation[] = [];
    for (const s of raw) {
      const hay: string = (s.name + ' ' + s.cat + ' ' + s.loc + ' ' + s.country).toLowerCase();
      if (hay.indexOf(k) >= 0) {
        out.push(s);
      }
    }
    return out;
  }

  private rawList(): RadioStation[] {
    if (this.tab === TAB_FAV) {
      const out: RadioStation[] = [];
      for (const sid of RadioStore.favs()) {
        const s: RadioStation | null = RadioApi.find(sid);
        if (s !== null) {
          out.push(s);
        }
      }
      return out;
    }
    if (this.tab === TAB_RECENT) {
      const out: RadioStation[] = [];
      for (const sid of RadioStore.recents()) {
        const s: RadioStation | null = RadioApi.find(sid);
        if (s !== null) {
          out.push(s);
        }
      }
      return out;
    }
    if (this.group === '全部电台') {
      return RadioApi.list();
    }
    const out: RadioStation[] = [];
    for (const s of RadioApi.list()) {
      if (RadioApi.groupOf(s) === this.group) {
        out.push(s);
      }
    }
    return out;
  }

  private refreshList(): void {
    const v: RadioStation[] = this.visibleList();
    this.stations = v;
    this.src.set(v);
    this.listTick++;
  }

  // ---------------- 左侧台标区 ----------------

  /** 推荐就是精选：15 个，数量太少不做冷启动轮换，轮了反而记不住位置 */
  private ptabList(): RadioStation[] {
    if (this.ptab === PTAB_FAV) {
      return this.stationsOf(RadioStore.favs());
    }
    if (this.ptab === PTAB_RECENT) {
      return this.stationsOf(RadioStore.recents());
    }
    return this.presetList;
  }

  private stationsOf(sids: string[]): RadioStation[] {
    const out: RadioStation[] = [];
    for (const sid of sids) {
      const s: RadioStation | null = RadioApi.find(sid);
      if (s !== null) {
        out.push(s);
      }
    }
    return out;
  }

  private ptabCount(t: number): number {
    if (t === PTAB_FAV) {
      return this.favCount;
    }
    if (t === PTAB_RECENT) {
      return this.recentCount;
    }
    return this.presetList.length;
  }

  private emptyTip(): string {
    return this.ptab === PTAB_FAV ? '还没有收藏的台' : '还没有听过的台';
  }

  /** 按 sid 派生一个稳定的封套配色，同一个台每次都是同一个颜色 */
  private rackColor(sid: string): string[] {
    let h: number = 0;
    for (let i: number = 0; i < sid.length; i++) {
      h = (h * 31 + sid.charCodeAt(i)) % 9973;
    }
    return DISC_COLORS[h % DISC_COLORS.length];
  }

  // ---------------- 节目单 ----------------

  private refreshEpgLabels(): void {
    const c: RadioStation | null = this.cur;
    if (c === null) {
      return;
    }
    const nn: EpgNowNext | null = RadioEpg.nowNext(c.name);
    const prevNow: string = this.epgNow;
    if (nn === null) {
      this.epgNow = '';
      this.epgNowTime = '';
      this.epgNext = '';
      this.epgNextTime = '';
      this.epgPct = 0;
      if (prevNow.length > 0) {
        this.epgTick++;
      }
      return;
    }
    const cur: EpgProg | null = nn.cur;
    const nxt: EpgProg | null = nn.next;
    this.epgNow = (cur !== null) ? cur.t : '';
    this.epgNowTime = (cur !== null) ? (RadioPage.hhmm(cur.s) + '—' + RadioPage.hhmm(cur.e)) : '';
    this.epgNext = (nxt !== null) ? nxt.t : '';
    this.epgNextTime = (nxt !== null) ? RadioPage.hhmm(nxt.s) : '';
    if (cur !== null && cur.e > cur.s) {
      const pct: number = Math.round((Date.now() - cur.s) * 100 / (cur.e - cur.s));
      this.epgPct = Math.max(0, Math.min(100, pct));
    } else {
      this.epgPct = 0;
    }
    if (this.epgNow !== prevNow) {
      this.epgTick++;
    }
  }

  private openEpg(): void {
    const c: RadioStation | null = this.cur;
    if (c === null) {
      return;
    }
    const rows: EpgRow[] = [];
    const now: number = Date.now();
    for (const p of RadioEpg.day(c.name)) {
      rows.push({
        time: RadioPage.hhmm(p.s) + '—' + RadioPage.hhmm(p.e),
        title: p.t,
        now: p.s <= now && now < p.e
      });
    }
    if (rows.length === 0) {
      rows.push({ time: '', title: '这个台暂时没有节目单', now: false });
    }
    this.epgRows = rows;
    this.showEpg = true;
  }

  private epgFor(s: RadioStation): EpgNowNext | null {
    return RadioEpg.nowNext(s.name);
  }

  // ---------------- 杂项 ----------------

  private clockTo(): void {
    const d: Date = new Date();
    const hh: string = String(d.getHours()).padStart(2, '0');
    const mm: string = String(d.getMinutes()).padStart(2, '0');
    this.clock = hh + ':' + mm;
    const wd: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    this.dateText = (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + wd[d.getDay()];
  }

  /** 状态位唯一文案：连不上就说原因，正在连就说正在连，最后才是播放/暂停 */
  private statusText(): string {
    if (this.err.length > 0) {
      return this.err;
    }
    if (this.stateText.length > 0) {
      return this.stateText;
    }
    return this.playing ? '正在播放' : '已暂停';
  }

  /** 真的出声了才算在播：粒子、状态位共用这一个判断，不许各自为政 */
  private isLive(): boolean {
    return this.statusText() === '正在播放';
  }

  /** 每帧入口：按当前 fxMode 分发到三种动效，停播统一留一条淡基准线 */
  private drawWave(): void {
    if (!this.waveReady) {
      return;
    }
    const g: CanvasRenderingContext2D = this.waveCtx;
    g.clearRect(0, 0, WAVE_W, WAVE_H);
    if (!this.isLive()) {
      // 停播才留一条淡基准线；出声时让位给点阵，不要一条横线穿过动效
      g.globalAlpha = 0.4;
      g.fillStyle = '#9FAE84';
      g.fillRect(0, WAVE_CY, WAVE_W, 1);
      g.globalAlpha = 1;
      return;
    }
    // 推进速度每 0.8~2.6 秒随机换一次，平滑逼近
    this.waveSpeedTick--;
    if (this.waveSpeedTick <= 0) {
      this.waveSpeedTarget = 0.018 + Math.random() * 0.024;
      this.waveSpeedTick = 25 + Math.floor(Math.random() * 55);
    }
    this.waveSpeed += (this.waveSpeedTarget - this.waveSpeed) * 0.05;
    this.waveT += this.waveSpeed;
    if (this.fxMode === FX_VORTEX) {
      this.drawVortex(g, this.waveT);
    } else if (this.fxMode === FX_RADIAL) {
      this.drawRadial(g, this.waveT);
    } else {
      this.drawPerspective(g, this.waveT);
    }
    g.globalAlpha = 1;
  }

  /**
   * 动效一：透视点阵。左侧一列竖直亮带，往右逐列扭曲成起伏的波浪曲面。
   * 每列的行距随 u 张开，波浪相位沿行错开，远处的点更暗更小。
   */
  private drawPerspective(g: CanvasRenderingContext2D, t: number): void {
    g.fillStyle = '#354226';
    const stepX: number = (WAVE_W - 4) / (GRID_COLS - 1);
    for (let c: number = 0; c < GRID_COLS; c++) {
      const u: number = c / (GRID_COLS - 1);
      const x: number = 2 + c * stepX;
      const spread: number = 0.62 + u * 0.38;
      const amp: number = 2 + u * 20;
      const baseAlpha: number = 0.92 - u * 0.55;
      const sz: number = 1.7 - u * 0.7;
      for (let r: number = 0; r < GRID_ROWS; r++) {
        const v: number = r / (GRID_ROWS - 1) - 0.5;
        const w1: number = Math.sin(u * 5.2 - t * 1.7 + v * 4.2) * amp;
        const w2: number = Math.sin(u * 2.3 - t * 0.9 + v * 8.0) * amp * 0.45;
        const y: number = WAVE_CY + v * 80 * spread + w1 + w2;
        const band: number = Math.abs(Math.sin(v * 9.4 + u * 1.2 - t * 0.5));
        g.globalAlpha = baseAlpha * (0.14 + 0.86 * band * band);
        g.fillRect(x, y, sz, sz);
      }
    }
  }

  /**
   * 动效二：漩涡。整块液晶屏铺满粒子，用归一化椭圆坐标算极角/半径，
   * 亮度按「旋臂数×极角 − 半径×扭转 + 时间×旋转」调制出五条旋转的螺旋臂。
   * 关键点：先给每颗粒子一个底亮度，旋臂只是叠亮，这样四角也有点、真正铺满，
   * 而不是只在中心画一小圈。
   */
  private drawVortex(g: CanvasRenderingContext2D, t: number): void {
    const cx: number = WAVE_W * 0.5;
    const cy: number = WAVE_CY;
    const hx: number = WAVE_W * 0.5;
    const hy: number = WAVE_H * 0.5;
    const spin: number = t * 1.3;
    const stepX: number = WAVE_W / (VORTEX_COLS - 1);
    const stepY: number = WAVE_H / (VORTEX_ROWS - 1);
    g.fillStyle = '#354226';
    for (let r: number = 0; r < VORTEX_ROWS; r++) {
      const y: number = r * stepY;
      const ny: number = (y - cy) / hy;
      for (let c: number = 0; c < VORTEX_COLS; c++) {
        const x: number = c * stepX;
        const nx: number = (x - cx) / hx;
        // 归一化半径 0（中心）~1.4（四角），极角覆盖整圈
        const rad: number = Math.sqrt(nx * nx + ny * ny);
        const ang: number = Math.atan2(ny, nx);
        // 相位沿极角分出五臂，沿半径扭曲成螺旋，随时间整体旋转
        const phase: number = VORTEX_ARMS * ang - rad * 8.2 + spin;
        const arm: number = 0.5 + 0.5 * Math.sin(phase);
        const ridge: number = arm * arm * arm;
        // 底亮度保证铺满，旋臂叠亮；边缘稍暗但不清零
        const edge: number = 1 - Math.min(0.42, rad * 0.3);
        g.globalAlpha = (0.2 + 0.78 * ridge) * edge;
        const sz: number = 1.7 - Math.min(0.6, rad * 0.4);
        g.fillRect(x, y, sz, sz);
      }
    }
    // 中心亮核：中心几颗粒子用亮绿点一下，漩涡有个眼
    g.globalAlpha = 0.85;
    g.fillStyle = '#6E8A4F';
    for (let k: number = 0; k < 12; k++) {
      const a: number = k * Math.PI / 6 + spin * 0.5;
      g.fillRect(cx + Math.cos(a) * 2.2 - 0.8, cy + Math.sin(a) * 2.2 - 0.8, 1.6, 1.6);
    }
  }

  /** 放射线场初始化：角度均匀铺满一圈并加抖动，每条线基准长度/速度/相位各异 */
  private initRays(): void {
    this.rays = [];
    for (let i: number = 0; i < RAY_COUNT; i++) {
      const ang: number = i * 2 * Math.PI / RAY_COUNT + (Math.random() - 0.5) * 0.02;
      this.rays.push({
        ang: ang,
        // 基准长度 0.55~1：即使最短也铺过半屏，整体始终放射满屏
        base: 0.55 + Math.random() * 0.45,
        // 每条线的长度按自己的速度伸缩，快慢错开才像穿梭
        speed: 0.7 + Math.random() * 1.6,
        phase: Math.random() * 2 * Math.PI,
        // 每六条一条亮线，层次分明
        bright: i % 6 === 0
      });
    }
  }

  /**
   * 动效三：放射。一开场就是满屏从中心射出的线，纵向压扁贴合屏比；
   * 变化只在每条线的长度——各自按 sin 在基准上伸缩，中心留一颗亮核。
   */
  private drawRadial(g: CanvasRenderingContext2D, t: number): void {
    if (this.rays.length === 0) {
      this.initRays();
    }
    const cx: number = WAVE_W * 0.5;
    const cy: number = WAVE_CY;
    for (let i: number = 0; i < this.rays.length; i++) {
      const ray: Ray = this.rays[i];
      // 长度在基准的 0.45~1 之间随各自相位伸缩
      const wave: number = 0.5 + 0.5 * Math.sin(t * ray.speed + ray.phase);
      const len: number = RAY_MAX * ray.base * (0.45 + 0.55 * wave);
      const dx: number = Math.cos(ray.ang);
      const dy: number = Math.sin(ray.ang) * RAY_FLAT;
      g.fillStyle = ray.bright ? '#6E8A4F' : '#354226';
      // 从中心向外逐点画成一条线；线越长越往外衰减，中心段最实
      for (let r: number = 3; r < len; r += RAY_STEP) {
        const x: number = cx + dx * r;
        const y: number = cy + dy * r;
        if (x < 0 || x > WAVE_W || y < 0 || y > WAVE_H) {
          break;
        }
        g.globalAlpha = (ray.bright ? 0.95 : 0.72) * (1 - r / RAY_MAX * 0.4);
        const sz: number = ray.bright ? 1.6 : 1.2;
        g.fillRect(x, y, sz, sz);
      }
    }
    // 中心亮核
    g.globalAlpha = 0.9;
    g.fillStyle = '#7E9A57';
    g.fillRect(cx - 2, cy - 1.5, 4, 3);
  }

  private static hhmm(ms: number): string {
    const d: Date = new Date(ms);
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }

  private fmtOf(s: RadioStation): string {
    for (const u of s.streams) {
      if (u.indexOf('.m3u8') >= 0) {
        return 'HLS';
      }
    }
    return 'MP3';
  }

  private subOf(s: RadioStation): string {
    const parts: string[] = [];
    if (s.loc.length > 0) {
      parts.push(s.loc);
    }
    if (s.cat.length > 0) {
      parts.push(s.cat);
    }
    if (parts.length === 0) {
      parts.push(s.country.length > 0 ? s.country : '网络电台');
    }
    return parts.join(' · ');
  }

  private epgLineOf(s: RadioStation, wantNext: boolean): string {
    const nn: EpgNowNext | null = this.epgFor(s);
    if (nn === null) {
      return '';
    }
    if (wantNext) {
      return (nn.next !== null) ? nn.next.t : '';
    }
    return (nn.cur !== null) ? nn.cur.t : '';
  }

  // ---------------- 界面 ----------------

  /** 动效切换 chip：选中读 this.fxMode（Builder 参数按值传，不能靠入参传选中态） */
  @Builder
  fxChip(label: string, mode: number) {
    Text(label)
      .fontSize(9.5)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.fxMode === mode ? '#D5E0B6' : '#4A5936')
      .backgroundColor(this.fxMode === mode ? '#354226' : Color.Transparent)
      .borderRadius(3)
      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      .onClick(() => this.setFx(mode))
  }

  @Builder
  lcd() {
    Column() {
      // 顶行：信号格 + 状态 + 日期时间
      Row({ space: 8 }) {
        Row({ space: 2 }) {
          Column().width(3).height(5).backgroundColor('#354226')
          Column().width(3).height(8).backgroundColor('#354226')
          Column().width(3).height(11).backgroundColor('#354226')
          Column().width(3).height(15).backgroundColor('#354226')
        }
        .alignItems(VerticalAlign.Bottom)
        .height(15)

        // 状态位只放一条：连不上就报原因，别让「已暂停」把失败盖住
        Text(this.statusText())
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.err.length > 0 ? '#7C2F1E' : '#354226')
          .letterSpacing(this.err.length > 0 ? 0.2 : 1.4)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 330 })

        Blank()

        Text(this.dateText + '  ' + this.clock)
          .fontSize(11.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4A5936')
      }
      .width('100%')
      .height(18)

      // 中部：节奏方块 + 台名/台标
      Row({ space: 14 }) {
        Stack() {
          Canvas(this.waveCtx)
            .width(WAVE_W)
            .height(WAVE_H)
            .onReady(() => {
              this.waveReady = true;
              this.drawWave();
            })
        }
        .width(WAVE_W)
        .height(WAVE_H)

        Column() {
          Row({ space: 10 }) {
            Column() {
              Text(this.cur !== null ? (this.cur as RadioStation).name : '—')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor('#28341C')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.cur !== null ? this.subOf(this.cur as RadioStation) : '')
                .fontSize(12)
                .fontColor('#50603A')
                .margin({ top: 3 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 台标：叠在首字底上，图挂了也还有字，不会白框
            Stack() {
              Text(this.cur !== null ? (this.cur as RadioStation).name.substring(0, 1) : '')
                .fontSize(23)
                .fontWeight(FontWeight.Bold)
                .fontColor('#4A5936')
              if (this.cur !== null && (this.cur as RadioStation).logo.length > 0) {
                Image((this.cur as RadioStation).logo)
                  .width(64)
                  .height(64)
                  .borderRadius(10)
                  .objectFit(ImageFit.Contain)
                  .backgroundColor('#C8D6A4')
                  .padding(2)
              }
            }
            .width(64)
            .height(64)
            .borderRadius(10)
            .backgroundColor('#C8D6A4')
            .border({ width: 1.5, color: '#A8B98A' })
          }
          .width('100%')
          // 台标比台名块矮，顶部对齐才不会被垂直居中带偏
          .alignItems(VerticalAlign.Top)

          // 当前节目：没有节目单就整块不画，不留空框
          if (this.epgNow.length > 0) {
            Column() {
              Text('正在播出')
                .fontSize(9.5)
                .fontWeight(FontWeight.Bold)
                .fontColor('#5C6C43')
                .letterSpacing(1)
              Text(this.epgNow + (this.epgNowTime.length > 0 ? '  ' + this.epgNowTime : ''))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#2B371D')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 })
              Row() {
                Row()
                  .width(this.epgPct + '%')
                  .height(3)
                  .borderRadius(2)
                  .backgroundColor('#354226')
              }
              .width('100%')
              .height(3)
              .borderRadius(2)
              .backgroundColor('#84946C')
              .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .margin({ top: 7 })
          }
        }
        .layoutWeight(1)
        // 高度按「台名 + 副标题 + 节目块」写死：没有节目单时内容变矮，顶边才不会往下掉
        .height(106)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      // 底部对齐：右侧最后一格是进度条，方块底边跟着它走，两者才齐平
      .alignItems(VerticalAlign.Bottom)
      // 底部让出 12：方块和进度条一起上抬，底下的「网络 / 立体声」上方才有空白
      .padding({ bottom: 12 })

      // 底行：左容器和特效区同宽，切换贴它的右缘；右侧是下一档
      Row({ space: 8 }) {
        Row({ space: 8 }) {
          Text('网络')
            .fontSize(9.5)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D5E0B6')
            .backgroundColor('#354226')
            .borderRadius(3)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          Text('立体声')
            .fontSize(9.5)
            .fontWeight(FontWeight.Bold)
            .fontColor('#4A5936')
            .border({ width: 1, color: '#6B7C4D' })
            .borderRadius(3)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          Blank()
          Row({ space: 2 }) {
            this.fxChip('波浪', FX_WAVE)
            Text('｜').fontSize(9).fontColor('#84946C')
            this.fxChip('漩涡', FX_VORTEX)
            Text('｜').fontSize(9).fontColor('#84946C')
            this.fxChip('放射', FX_RADIAL)
          }
        }
        .width(WAVE_W)
        Blank()
        if (this.epgNext.length > 0) {
          Text('下一档 ' + this.epgNextTime + ' · ' + this.epgNext)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4C5A35')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .height(18)
    }
    .width('100%')
    .height(192)
    .padding({ left: 16, right: 16, top: 12, bottom: 10 })
    .borderRadius(10)
    .linearGradient({
      angle: 155,
      colors: [['#DBE6BD', 0.0], ['#CAD8A9', 0.55], ['#B9C99A', 1.0]]
    })
    .border({ width: 2, color: '#0C0D10' })
    .shadow({ radius: 12, color: '#000000AA', offsetX: 0, offsetY: 4 })
  }

  /**
   * 面板按键。图标全部用矢量画，不引系统符号：
   * 真机上 `sys.symbol.*` 大部分名字取不到，Image 直接渲染成空，只剩文字。
   */
  @Builder
  keyBtn(label: string, kind: string, act: () => void, accent: boolean) {
    // 收藏键的文案/高亮必须在这里读 this.favOn：@Builder 参数按值传递，
    // 由调用处传 this.favOn ? '已收藏' : '收藏' 会固化成旧值，跟 Builder 内部读
    // this.favOn 的星标对不上（真机上出现过「文字已收藏、图标却是空心星」）。
    Row({ space: 6 }) {
      Text(kind === 'fav' ? (this.favOn ? '已收藏' : '收藏') : label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor((kind === 'fav' ? this.favOn : accent) ? '#150A04' : '#D9DAE2')
      if (kind === 'voldown' || kind === 'volup') {
        Text(kind === 'voldown' ? '−' : '＋')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(accent ? '#150A04' : '#B9BAC6')
      } else if (kind === 'prev') {
        this.skipIcon(false, accent ? '#150A04' : '#B9BAC6')
      } else if (kind === 'next') {
        this.skipIcon(true, accent ? '#150A04' : '#B9BAC6')
      } else if (kind === 'fav') {
        Text(this.favOn ? '★' : '☆')
          .fontSize(14)
          .fontColor(this.favOn ? '#150A04' : '#B9BAC6')
      } else {
        this.listIcon(accent ? '#150A04' : '#B9BAC6')
      }
    }
    .layoutWeight(1)
    .height(40)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .borderRadius(7)
    .backgroundColor((kind === 'fav' ? this.favOn : accent) ? '#FFA15C' : '#26272E')
    .border({ width: 1, color: (kind === 'fav' ? this.favOn : accent) ? '#FFC093' : '#43444E' })
    .shadow({ radius: 6, color: '#00000099', offsetX: 0, offsetY: 3 })
    .onClick(() => act())
  }

  /**
   * 上一台 / 下一台：|◀ ▶| 两个实心图标。
   * 用 SymbolGlyph 而不是 Image——Image 装系统符号取不到字形，会渲染成空。
   */
  @Builder
  skipIcon(forward: boolean, color: string) {
    SymbolGlyph(forward ? $r('sys.symbol.forward_end_fill') : $r('sys.symbol.backward_end_fill'))
      .fontSize(15)
      .fontColor([color])
  }

  /** 三横线：节目单 */
  @Builder
  listIcon(color: string) {
    SymbolGlyph($r('sys.symbol.list_bullet'))
      .fontSize(15)
      .fontColor([color])
  }

  /** 暂停 */
  @Builder
  pauseIcon(color: string) {
    SymbolGlyph($r('sys.symbol.pause_fill'))
      .fontSize(15)
      .fontColor([color])
  }

  /** 三角：播放 */
  @Builder
  playIcon(color: string) {
    SymbolGlyph($r('sys.symbol.play_fill'))
      .fontSize(15)
      .fontColor([color])
  }

  /** 一个台标格：黑胶唱片（各色封套 + 大盘心台标 + 套内台名），选框套住整张封套 */
  @Builder
  tileCell(s: RadioStation) {
    Column() {
      Stack() {
        // 封套底：按台派生的双色渐变
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(8)
          .linearGradient({
            angle: 145,
            colors: [[this.rackColor(s.sid)[0], 0], [this.rackColor(s.sid)[1], 1]]
          })

        // 黑胶盘：同心纹路 + 盘心大台标
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius('50%')
            .backgroundColor('#1A1410')
            .opacity(0.92)
          ForEach([0, 1, 2, 3], (_n: number) => {
            Column()
              .width((66 + _n * 11).toString() + '%')
              .height((66 + _n * 11).toString() + '%')
              .borderRadius('50%')
              .border({ width: 1, color: '#33FFFFFF' })
          }, (_n: number) => 'groove' + _n)
          if (s.logo.length > 0) {
            Image(s.logo)
              .width('60%')
              .height('60%')
              .borderRadius('50%')
              .objectFit(ImageFit.Contain)
              .backgroundColor('#FFFFFF')
          } else {
            Text(s.name.substring(0, 1))
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
        }
        .width('88%')
        .height('88%')

        // 台名放进封套里：底部一条半透明深色标签，不再占格子下方一行
        Column() {
          Text(s.name)
            .fontSize(10.5)
            .fontWeight(this.cur !== null && this.cur.sid === s.sid ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.cur !== null && this.cur.sid === s.sid ? '#FFB37A' : '#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 2, bottom: 3, left: 3, right: 3 })
            .backgroundColor('#A6000000')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      // 比正方形略扁 8%：唱片看上去仍是圆的，但一行矮下来，第三行才能露出小半个
      .aspectRatio(1.08)
      .borderRadius(8)
      .clip(true)
    }
    .width('100%')
    .padding(3)
    .borderRadius(11)
    .border({
      width: 2,
      color: this.cur !== null && this.cur.sid === s.sid ? '#FF8A3D' : Color.Transparent
    })
    .onClick(() => this.selectStation(s, true))
  }

  @Builder
  ptabChip(label: string, t: number) {
    Row({ space: 5 }) {
      Text(label)
        .fontSize(12)
        .fontWeight(this.ptab === t ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.ptab === t ? '#150A04' : '#B9B9C6')
      Text(String(this.ptabCount(t)))
        .fontSize(9.5)
        .fontColor(this.ptab === t ? '#4A2A12' : '#6B6D7A')
    }
    .height(26)
    .padding({ left: 12, right: 12 })
    .borderRadius(13)
    .backgroundColor(this.ptab === t ? '#FF8A3D' : '#14FFFFFF')
    .onClick(() => { this.ptab = t; })
  }

  @Builder
  presets() {
    Column() {
      Row({ space: 6 }) {
        this.ptabChip('推荐', PTAB_REC)
        this.ptabChip('收藏', PTAB_FAV)
        this.ptabChip('最近', PTAB_RECENT)
      }
      .width('100%')
      .height(26)

      if (this.ptabList().length === 0) {
        Column() {
          Text(this.emptyTip())
            .fontSize(12)
            .fontColor('#7A7C88')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 一行 6 个台标；高度交给外层 layoutWeight，滚到半行就自然露出来，提示下面还有
        Grid() {
          ForEach(this.ptabList(), (s: RadioStation) => {
            GridItem() {
              this.tileCell(s)
            }
          }, (s: RadioStation) => s.sid + '#' + this.ptab + '#' + this.listTick + '#'
            + (this.cur !== null ? this.cur.sid : '') + '#' + this.epgTick)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(4)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  stationRow(s: RadioStation) {
    Row({ space: 12 }) {
      Stack() {
        Text(s.name.substring(0, 1))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#6E7080')
        if (s.logo.length > 0) {
          Image(s.logo)
            .width(38)
            .height(38)
            .borderRadius(8)
            .objectFit(ImageFit.Contain)
            .backgroundColor('#33343D')
            .padding(2)
        }
      }
      .width(38)
      .height(38)

      Column() {
        Text(s.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EDEDF3')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.epgLineOf(s, false).length > 0
          ? ('正在播 · ' + this.epgLineOf(s, false))
          : this.subOf(s))
          .fontSize(10.5)
          .fontColor('#82848F')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.fmtOf(s))
        .fontSize(8.5)
        .fontWeight(FontWeight.Bold)
        .fontColor('#9D9FAB')
        .border({ width: 1, color: '#3C3D47' })
        .borderRadius(3)
        .padding({ left: 5, right: 5, top: 1, bottom: 1 })

      Text(RadioStore.isFav(s.sid) ? '★' : '☆')
        .fontSize(15)
        .fontColor(RadioStore.isFav(s.sid) ? '#FF8A3D' : '#4E4F5A')
        .padding({ left: 6, right: 2 })
        .onClick(() => {
          RadioStore.toggleFav(s.sid);
          if (this.cur !== null && this.cur.sid === s.sid) {
            this.favOn = RadioStore.isFav(s.sid);
          }
          this.syncCounts();
          this.refreshList();
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .borderRadius(7)
    .backgroundColor(this.cur !== null && this.cur.sid === s.sid ? '#33251C' : Color.Transparent)
    .border({
      width: 1,
      color: this.cur !== null && this.cur.sid === s.sid ? '#7A5334' : Color.Transparent
    })
    .onClick(() => this.selectStation(s, true))
  }

  @Builder
  library() {
    Column() {
      Row({ space: 7 }) {
        Text('电台库')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text(this.kw.trim().length > 0 ? String(this.stations.length) : String(RadioApi.count()))
          .fontSize(9.5)
          .fontColor('#6B6D7A')

        // 搜索：输入即过滤下面的列表
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(12)
            .fontColor(['#8A8C99'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          TextInput({ text: this.kw, placeholder: '搜台名' })
            .layoutWeight(1)
            .height(26)
            .fontSize(11)
            .fontColor('#E4E4EC')
            .placeholderColor('#6B6D7A')
            .placeholderFont({ size: 11 })
            .backgroundColor(Color.Transparent)
            .padding(0)
            .borderRadius(0)
            // TextInput 自带一圈描边，套在圆角胶囊里就是那道刺眼的白线
            .borderWidth(0)
            .onChange((v: string) => {
              this.kw = v;
              this.refreshList();
            })
          if (this.kw.length > 0) {
            SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
              .fontSize(13)
              .fontColor(['#7A7C88'])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .onClick(() => {
                this.kw = '';
                this.refreshList();
              })
          }
        }
        .layoutWeight(1)
        .height(27)
        .padding({ left: 9, right: 9 })
        .borderRadius(14)
        .backgroundColor('#14FFFFFF')
        .border({ width: 1, color: '#26FFFFFF' })

        // 分类下拉按钮
        Row({ space: 5 }) {
          Text(this.group + ' ▾')
            .fontSize(11)
            .fontColor(this.showGroups ? '#150A04' : '#B9B9C6')
        }
        .height(27)
        .padding({ left: 11, right: 11 })
        .borderRadius(14)
        .backgroundColor(this.showGroups ? '#FF8A3D' : '#1AFFFFFF')
        .border({ width: 1, color: this.showGroups ? '#FF8A3D' : '#26FFFFFF' })
        .onClick(() => { this.showGroups = !this.showGroups; })
      }
      .width('100%')
      .height(30)

      if (this.loading && this.stations.length === 0) {
        Column() {
          LoadingProgress().width(32).height(32).color('#FF8A3D')
          Text(this.tip.length > 0 ? this.tip : '正在准备电台列表…')
            .fontSize(11)
            .fontColor('#8A8C99')
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.stations.length === 0) {
        Column() {
          Text(this.kw.trim().length > 0 ? '没有匹配的台'
            : (this.tab === TAB_FAV ? '还没有收藏的台' : '这个分类下暂时没有台'))
            .fontSize(12)
            .fontColor('#7A7C88')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          LazyForEach(this.src, (s: RadioStation) => {
            ListItem() {
              this.stationRow(s)
            }
          }, (s: RadioStation) => s.sid + '#'
            + (this.cur !== null ? this.cur.sid : '') + '#' + this.listTick + '#' + this.epgTick)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  groupMenu() {
    Column() {
      ForEach(RadioApi.groups(), (g: string) => {
        Row() {
          Text(g)
            .fontSize(11.5)
            .fontColor(this.group === g ? '#FFB37A' : '#D2D3DC')
          Blank()
          Text(String(RadioApi.countOf(g)))
            .fontSize(9.5)
            .fontColor('#6B6D7A')
        }
        .width('100%')
        .height(30)
        .padding({ left: 10, right: 10 })
        .borderRadius(6)
        .backgroundColor(this.group === g ? '#2E2419' : Color.Transparent)
        .onClick(() => {
          this.group = g;
          this.showGroups = false;
          this.tab = TAB_ALL;
          this.refreshList();
        })
      }, (g: string) => 'g' + g)
    }
    .width(180)
    .padding(6)
    .onClick(() => {})
    .borderRadius(10)
    .backgroundColor('#1B1C22')
    .border({ width: 1, color: '#33343E' })
    .shadow({ radius: 18, color: '#000000CC', offsetX: 0, offsetY: 8 })
  }

  @Builder
  epgPanel() {
    Column() {
      Row() {
        Column() {
          Text('今日节目单')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text(this.cur !== null ? (this.cur as RadioStation).name + ' · ' + this.dateText : '')
            .fontSize(10)
            .fontColor('#8A8C99')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text('✕')
          .fontSize(15)
          .fontColor('#9A9CA8')
          .padding(6)
          .onClick(() => { this.showEpg = false; })
      }
      .width('100%')

      List({ space: 2 }) {
        ForEach(this.epgRows, (r: EpgRow, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(r.time)
                .fontSize(10.5)
                .fontColor(r.now ? '#FFB37A' : '#6E7080')
                .width(64)
              Text(r.title)
                .fontSize(11.5)
                .fontWeight(r.now ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(r.now ? '#FFFFFF' : '#C4C5CE')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (r.now) {
                Text('正在播出')
                  .fontSize(8.5)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#150A04')
                  .backgroundColor('#FF8A3D')
                  .borderRadius(3)
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              }
            }
            .width('100%')
            .height(32)
            .padding({ left: 8, right: 8 })
            .borderRadius(5)
            .backgroundColor(r.now ? '#2E2419' : Color.Transparent)
          }
        }, (r: EpgRow, i: number) => 'epg' + i + r.title)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .margin({ top: 8 })
    }
    .width(470)
    // 节目少的时候不留大片空：按条数收，最多 400 再滚动
    .height(Math.min(400, 92 + this.epgRows.length * 32))
    .padding(16)
    .onClick(() => {})
    .borderRadius(16)
    .backgroundColor('#14151A')
    .border({ width: 1, color: '#33343E' })
    .shadow({ radius: 30, color: '#000000DD', offsetX: 0, offsetY: 16 })
  }

  build() {
    Row() {
      SideNav({ active: 3 })
      Stack({ alignContent: Alignment.Center }) {
        // 背景
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 160,
            colors: [['#22232B', 0.0], ['#141519', 0.55], ['#0B0B0E', 1.0]]
          })

        Column() {
          // 顶栏
          Row({ space: 9 }) {
            Text('网络电台')
              .fontSize(27)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text('RADIO')
              .fontSize(11)
              .fontColor('#6B6D7A')
              .letterSpacing(1.5)
          }
          .width('100%')
          .height(34)

          Row({ space: 14 }) {
            // 左：收音机
            Column({ space: 10 }) {
              this.lcd()

              Row({ space: 6 }) {
                this.keyBtn('音量', 'voldown', () => this.setVol(this.vol - 5), false)
                this.keyBtn('音量', 'volup', () => this.setVol(this.vol + 5), false)
                this.keyBtn('上一台', 'prev', () => this.step(-1), false)
                this.keyBtn('下一台', 'next', () => this.step(1), false)
                this.keyBtn('收藏', 'fav', () => this.toggleFav(), false)
                this.keyBtn('节目单', 'epg', () => this.openEpg(), false)
              }
              .width('100%')

              Row({ space: 9 }) {
                if (this.playing) {
                  this.pauseIcon('#FF8A3D')
                } else {
                  this.playIcon('#FF8A3D')
                }
                Text(this.playing ? '暂停' : '播放')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#F0F0F6')
                  .letterSpacing(2)
              }
              .width('100%')
              .height(36)
              .alignItems(VerticalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .borderRadius(7)
              .backgroundColor('#2E2F37')
              .border({ width: 1, color: '#4B4C56' })
              .onClick(() => this.togglePlay())

              this.presets()
            }
            .width(732)
            .height('100%')

            // 右：电台库
            Column() {
              this.library()
            }
            .layoutWeight(1)
            .height('100%')
            .padding({ left: 13, right: 13, top: 10, bottom: 8 })
            .borderRadius(12)
            .linearGradient({
              angle: 165,
              colors: [['#1E1F25', 0.0], ['#131419', 1.0]]
            })
            .border({ width: 1, color: '#303139' })
          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 20, right: 22, top: 12, bottom: 12 })

        // 分类下拉：浮在列表上方右对齐
        if (this.showGroups) {
          Column() {
            this.groupMenu()
          }
          .width('100%')
          .height('100%')
          .padding({ right: 26, top: 56 })
          .alignItems(HorizontalAlign.End)
          .onClick(() => { this.showGroups = false; })
        }

        // 音量 OSD
        if (this.volOsd) {
          Row({ space: 9 }) {
            Text('音量')
              .fontSize(11)
              .fontColor('#C7C8D1')
              .letterSpacing(1)
            Row() {
              Row()
                .width(this.vol + '%')
                .height(6)
                .borderRadius(3)
                .backgroundColor('#FF8A3D')
            }
            .width(140)
            .height(6)
            .borderRadius(3)
            .backgroundColor('#3B3C45')
            Text(String(this.vol))
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFB37A')
              .width(26)
          }
          .padding({ left: 12, right: 12 })
          .height(36)
          .borderRadius(7)
          .backgroundColor('#2A2B33EE')
          .border({ width: 1, color: '#454650' })
          .position({ x: 26, y: 266 })
          .hitTestBehavior(HitTestMode.None)
        }

        // 节目单浮层
        if (this.showEpg) {
          Column() {
            this.epgPanel()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('#000000B8')
          .onClick(() => { this.showEpg = false; })
        }
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0B0E')
  }
}
