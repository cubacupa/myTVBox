import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';

const F_FAV: string = 'tvbox_live_fav.json';
const F_LAST: string = 'tvbox_live_last.json';
/** 「最后能放的线路」最多记这么多个频道 */
const LAST_MAX: number = 300;

export interface LiveFav {
  name: string;
  url: string;
  group: string;
}

interface FavRec {
  name?: string;
  url?: string;
  group?: string;
}

interface LastRec {
  key?: string;
  url?: string;
}

/**
 * 直播频道的两个小记忆：
 *   ① 收藏：频道名 + 地址 + 分组（地址是稳定标识，同名频道很多）
 *   ② 最后能放的线路：多线路频道记住上次真播出来的那条，避开串台/404
 *
 * 内存里各存一份（数组）：直播列表一屏上百个格子，每次都读文件会卡顿。
 */
export class LiveMarkStore {
  private static favArr: LiveFav[] | null = null;
  private static lastCache: Map<string, string> = new Map();
  private static lastLoaded: boolean = false;

  // ---------- 收藏 ----------

  static favs(ctx: common.Context): LiveFav[] {
    if (LiveMarkStore.favArr !== null) {
      return LiveMarkStore.favArr;
    }
    const out: LiveFav[] = [];
    const txt: string = FileStore.readText(ctx, F_FAV);
    if (txt) {
      try {
        const arr = JSON.parse(txt) as FavRec[];
        if (Array.isArray(arr)) {
          for (const a of arr) {
            const url: string = (a.url ?? '').trim();
            if (url.length === 0) {
              continue;
            }
            out.push({
              name: (a.name ?? '').trim() || '频道',
              url: url,
              group: (a.group ?? '').trim()
            });
          }
        }
      } catch (e) {
        // 文件损坏当作空，下次保存覆盖
      }
    }
    LiveMarkStore.favArr = out;
    return out;
  }

  static isFav(ctx: common.Context, url: string): boolean {
    for (const f of LiveMarkStore.favs(ctx)) {
      if (f.url === url) {
        return true;
      }
    }
    return false;
  }

  /** 收藏/取消收藏，返回操作后是否为「已收藏」。
   *  lineUrls 是该频道的全部线路：只要有一条已被收藏，就视为「已收藏」，
   *  取消时一起清掉，避免合并成多线路后同一个频道残留好几条收藏。 */
  static toggleFav(ctx: common.Context, ch: LiveFav, lineUrls: string[]): boolean {
    const list: LiveFav[] = LiveMarkStore.favs(ctx);
    for (let i = list.length - 1; i >= 0; i--) {
      if (LiveMarkStore.hit(list[i].url, ch.url, lineUrls)) {
        list.splice(i, 1);
        LiveMarkStore.favArr = list;
        FileStore.writeText(ctx, F_FAV, JSON.stringify(list));
        return false;
      }
    }
    list.unshift(ch);
    LiveMarkStore.favArr = list;
    FileStore.writeText(ctx, F_FAV, JSON.stringify(list));
    return true;
  }

  /** 收藏里是否有属于该频道（任意一条线路）的记录 */
  static favOf(ctx: common.Context, lineUrls: string[]): boolean {
    for (const f of LiveMarkStore.favs(ctx)) {
      if (LiveMarkStore.hit(f.url, '', lineUrls)) {
        return true;
      }
    }
    return false;
  }

  private static hit(url: string, fallback: string, lineUrls: string[]): boolean {
    if (fallback.length > 0 && url === fallback) {
      return true;
    }
    for (const u of lineUrls) {
      if (u === url) {
        return true;
      }
    }
    return false;
  }

  /** 清空全部收藏（收藏视图右上角的「清空收藏」用） */
  static clearFavs(ctx: common.Context): void {
    LiveMarkStore.favArr = [];
    FileStore.remove(ctx, F_FAV);
  }

  // ---------- 最后能放的线路 ----------

  /**
   * 同一个频道在源站常有好几条地址，第一条经常已经串台（放出来是购物台）
   * 或者直接 404。这里记住「上次真的播出来」的那条，下次点同一频道直接从它开始，
   * 不用每次从第一条重新踩坑。
   */
  static lastGood(ctx: common.Context, key: string): string {
    if (!key) {
      return '';
    }
    const m: Map<string, string> = LiveMarkStore.lastMap(ctx);
    const u = m.get(key);
    return u === undefined ? '' : u;
  }

  static setLastGood(ctx: common.Context, key: string, url: string): void {
    if (!key || !url) {
      return;
    }
    const m: Map<string, string> = LiveMarkStore.lastMap(ctx);
    if (m.get(key) === url) {
      return;
    }
    m.set(key, url);
    const keys: string[] = [];
    m.forEach((_v: string, k: string) => {
      keys.push(k);
    });
    // 超上限就丢最早记的那批（Map 保持插入顺序）
    if (keys.length > LAST_MAX) {
      for (let i = 0; i < keys.length - LAST_MAX; i++) {
        m.delete(keys[i]);
      }
    }
    const arr: LastRec[] = [];
    m.forEach((v: string, k: string) => {
      arr.push({ key: k, url: v });
    });
    FileStore.writeText(ctx, F_LAST, JSON.stringify(arr));
  }

  private static lastMap(ctx: common.Context): Map<string, string> {
    if (LiveMarkStore.lastLoaded) {
      return LiveMarkStore.lastCache;
    }
    const m: Map<string, string> = new Map();
    const txt: string = FileStore.readText(ctx, F_LAST);
    if (txt) {
      try {
        const arr = JSON.parse(txt) as LastRec[];
        if (Array.isArray(arr)) {
          for (const a of arr) {
            const k: string = (a.key ?? '').trim();
            const u: string = (a.url ?? '').trim();
            if (k.length > 0 && u.length > 0) {
              m.set(k, u);
            }
          }
        }
      } catch (e) {
        // 损坏当作空
      }
    }
    LiveMarkStore.lastCache = m;
    LiveMarkStore.lastLoaded = true;
    return m;
  }
}
