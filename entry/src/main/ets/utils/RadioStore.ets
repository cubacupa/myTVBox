import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';

/**
 * 电台的本地记忆：收藏、最近播放、音量、上次听的台。
 *
 * 全部塞进一个小 JSON（几十个 id），比用 Preferences 省事，也跟项目里其它
 * 记忆文件（直播收藏、观看记录）保持同一套读写方式。
 */
const F_MEM: string = 'tvbox_radio_mem.json';
/** 最近播放最多记这么多条 */
const RECENT_MAX: number = 30;

interface MemRec {
  fav?: string[];
  recent?: string[];
  vol?: number;
  last?: string;
}

export class RadioStore {
  private static fav: string[] = [];
  private static recent: string[] = [];
  private static vol: number = 65;
  private static last: string = '';
  private static loaded: boolean = false;
  private static ctx: common.Context | null = null;

  static init(ctx: common.Context): void {
    if (RadioStore.loaded) {
      return;
    }
    RadioStore.loaded = true;
    RadioStore.ctx = ctx;
    const txt: string = FileStore.readText(ctx, F_MEM);
    if (txt.length === 0) {
      return;
    }
    try {
      const m = JSON.parse(txt) as MemRec;
      if (m !== null) {
        RadioStore.fav = RadioStore.clean(m.fav);
        RadioStore.recent = RadioStore.clean(m.recent);
        RadioStore.last = (m.last ?? '').trim();
        const v: number = (typeof m.vol === 'number') ? m.vol : 65;
        RadioStore.vol = Math.max(0, Math.min(100, Math.round(v)));
      }
    } catch (e) {
      // 文件坏了用默认值
    }
  }

  private static clean(src: string[] | undefined): string[] {
    const out: string[] = [];
    if (Array.isArray(src)) {
      for (const a of src) {
        const t: string = (a ?? '').trim();
        if (t.length > 0 && out.indexOf(t) < 0) {
          out.push(t);
        }
      }
    }
    return out;
  }

  private static save(): void {
    const ctx: common.Context | null = RadioStore.ctx;
    if (ctx === null) {
      return;
    }
    const rec: MemRec = {
      fav: RadioStore.fav,
      recent: RadioStore.recent,
      vol: RadioStore.vol,
      last: RadioStore.last
    };
    FileStore.writeText(ctx, F_MEM, JSON.stringify(rec));
  }

  // ---------- 收藏 ----------

  static favs(): string[] {
    return RadioStore.fav;
  }

  static isFav(sid: string): boolean {
    return RadioStore.fav.indexOf(sid) >= 0;
  }

  /** 返回操作后是否已收藏，界面直接拿去当星标状态 */
  static toggleFav(sid: string): boolean {
    const i: number = RadioStore.fav.indexOf(sid);
    if (i >= 0) {
      RadioStore.fav.splice(i, 1);
    } else {
      RadioStore.fav.unshift(sid);
    }
    RadioStore.save();
    return i < 0;
  }

  // ---------- 最近播放 ----------

  static recents(): string[] {
    return RadioStore.recent;
  }

  static markPlayed(sid: string): void {
    const i: number = RadioStore.recent.indexOf(sid);
    if (i >= 0) {
      RadioStore.recent.splice(i, 1);
    }
    RadioStore.recent.unshift(sid);
    while (RadioStore.recent.length > RECENT_MAX) {
      RadioStore.recent.pop();
    }
    RadioStore.last = sid;
    RadioStore.save();
  }

  static lastSid(): string {
    return RadioStore.last;
  }

  // ---------- 音量 ----------

  static volume(): number {
    return RadioStore.vol;
  }

  static setVolume(v: number): void {
    RadioStore.vol = Math.max(0, Math.min(100, Math.round(v)));
    RadioStore.save();
  }
}
