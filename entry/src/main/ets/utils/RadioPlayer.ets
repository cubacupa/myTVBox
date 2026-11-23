import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RadioRelay } from './RadioRelay';

/**
 * 电台播放器：纯音频的 AVPlayer 薄封装。
 *
 * 只做三件播放页关心的、而 AVPlayer 不会替你做的事：
 *   1) 一条线路起不来就自动换下一条（电台流时效性差，列表里三条线路很常见，
 *      第一条挂掉的概率不低，让用户手动换线路是最后手段而不是第一选择）；
 *   2) 换台时把旧实例彻底释放，并用代次号丢弃旧实例迟到的回调——
 *      不这么做会出现「刚切到 A 台，两秒后被 B 台残留的 error 顶掉」；
 *   3) 音量走 AVPlayer 自己，不碰系统音量：用户在电台里调的音量不该影响 App 之外。
 */
export class RadioPlayer {
  private player: media.AVPlayer | null = null;
  private urls: string[] = [];
  private idx: number = 0;
  /** 代次：每次换台 +1，旧实例的回调看到代次不符就全部丢弃 */
  private gen: number = 0;
  private vol: number = 65;
  /** 用户意图（想听 / 想停），决定 prepared 之后到底 play 不 play */
  private want: boolean = false;
  /** 本线路第一次出声的时刻，用来判断「是真播过一段，还是刚出声就断」 */
  private playedAt: number = 0;
  /** 播着播着断掉后已经自动重连过几次（每次 open 归零，别无限重连） */
  private reconnected: number = 0;

  /** 'buffering' | 'playing' | 'paused' | 'error' */
  onState: (s: string) => void = () => {};
  /** 真正播不出来时的原因（所有线路都失败才报） */
  onFail: (msg: string) => void = () => {};

  async open(urls: string[], vol: number, autoplay: boolean): Promise<void> {
    this.vol = Math.max(0, Math.min(100, vol));
    this.want = autoplay;
    this.reconnected = 0;
    this.playedAt = 0;
    // 直连会「播 1 秒就停」的台，改走本机转发（见 RadioRelay 顶部注释）
    this.urls = await RadioRelay.mapAll(urls.slice());
    await this.start(0);
  }

  private async start(i: number): Promise<void> {
    const g: number = ++this.gen;
    await this.drop();
    if (i >= this.urls.length) {
      this.failHard('这个台的线路都连不上，换个台试试');
      return;
    }
    this.onState('buffering');
    let p: media.AVPlayer;
    try {
      p = await media.createAVPlayer();
    } catch (e) {
      this.failHard('播放器创建失败');
      return;
    }
    if (g !== this.gen) {
      p.release().catch(() => {});
      return;
    }
    this.player = p;
    this.idx = i;
    p.on('stateChange', (state: string) => {
      if (g !== this.gen) {
        return;
      }
      if (state === 'initialized') {
        p.prepare().catch(() => {});
      } else if (state === 'prepared') {
        try {
          p.setVolume(this.vol / 100);
        } catch (e) {
          // 音量设置失败不影响出声
        }
        if (this.want) {
          p.play().catch(() => {});
        }
      } else if (state === 'playing') {
        if (this.playedAt === 0) {
          this.playedAt = Date.now();
        }
        this.onState('playing');
      } else if (state === 'paused') {
        this.onState('paused');
      } else if (state === 'completed') {
        // 直播流走到 completed 只有两种可能：
        //   1) 服务器只吐了一小段就关连接（有的 CDN 对范围请求只回 8KB），出声不到几秒就断；
        //   2) 真播了一阵，链路自己断了。
        // 前者别去重连——重连也是同样的几秒、同样的断；后者重连一次通常能接上。
        const ms: number = this.playedAt > 0 ? (Date.now() - this.playedAt) : 0;
        this.playedAt = 0;
        if (ms < 4000) {
          this.nextOnFail(g);
        } else if (this.reconnected < 1 && this.want) {
          this.reconnected++;
          this.onState('buffering');
          setTimeout(() => {
            if (g === this.gen) {
              this.start(this.idx).catch(() => {});
            }
          }, 800);
        } else {
          this.failHard('线路已断开，点播放重连');
        }
      }
    });
    p.on('error', (err: BusinessError) => {
      if (g !== this.gen) {
        return;
      }
      this.nextOnFail(g);
    });
    try {
      p.url = this.urls[i];
    } catch (e) {
      this.nextOnFail(g);
    }
  }

  private nextOnFail(g: number): void {
    if (g !== this.gen) {
      return;
    }
    if (this.idx + 1 < this.urls.length) {
      this.start(this.idx + 1).catch(() => {});
    } else {
      this.failHard('这个台的线路都连不上，换个台试试');
    }
  }

  /**
   * 彻底放不出来：把实例收掉、回到第一条线路。
   * 不收拾干净的话，用户看到红字后点「播放」会打到已经 error 的旧实例上，
   * 屏幕从「已暂停」变成「播放中」但一点声音都没有。
   */
  private failHard(msg: string): void {
    this.idx = 0;
    this.playedAt = 0;
    this.reconnected = 0;
    this.want = true;
    this.drop().catch(() => {});
    this.onState('error');
    this.onFail(msg);
  }

  /** 释放当前实例（不动 want：换台时用户还是想听的） */
  private async drop(): Promise<void> {
    const p: media.AVPlayer | null = this.player;
    this.player = null;
    if (p === null) {
      return;
    }
    try {
      await p.release();
    } catch (e) {
      // 老实例可能已经自己走了，忽略
    }
  }

  setVolume(v: number): void {
    this.vol = Math.max(0, Math.min(100, Math.round(v)));
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    try {
      p.setVolume(this.vol / 100);
    } catch (e) {
      // 忽略
    }
  }

  pause(): void {
    this.want = false;
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    try {
      p.pause().catch(() => {});
    } catch (e) {
      // 忽略
    }
    this.onState('paused');
  }

  resume(): void {
    this.want = true;
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      // 已经释放（切走过），重新开当前台
      this.start(this.idx).catch(() => {});
      return;
    }
    try {
      p.play().catch(() => {});
    } catch (e) {
      // 忽略
    }
  }

  /** 页面退出时必须调：不停会一直在后台出声 */
  close(): void {
    this.want = false;
    this.gen++;
    this.drop().catch(() => {});
  }
}
