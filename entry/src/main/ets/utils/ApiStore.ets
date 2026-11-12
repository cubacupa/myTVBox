import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';

const F_API: string = 'tvbox_apis.json';

/** 一条已保存的配置接口（地址簿条目） */
export interface SavedApi {
  name: string;
  url: string;
}

/** 落盘时的宽松结构：老文件可能缺字段 */
interface ApiRec {
  name?: string;
  url?: string;
}

/**
 * 配置接口地址簿。
 *
 * 配置地址动辄上百个字符，电视上用遥控器重新输入一遍太痛苦；
 * 而且同时放着好几份配置（4K 站、多仓、纯直播）时，光看域名分不清谁是谁。
 * 所以填过的地址连同用户起的名字一起存下来，设置页直接点名字切换。
 */
export class ApiStore {
  static list(ctx: common.Context): SavedApi[] {
    const out: SavedApi[] = [];
    const txt: string = FileStore.readText(ctx, F_API);
    if (!txt) {
      return out;
    }
    try {
      const arr = JSON.parse(txt) as ApiRec[];
      if (!Array.isArray(arr)) {
        return out;
      }
      for (const a of arr) {
        const url: string = (a.url ?? '').trim();
        if (url.length === 0) {
          continue;
        }
        const nm: string = (a.name ?? '').trim();
        out.push({ name: nm.length > 0 ? nm : ApiStore.guessName(url), url: url });
      }
    } catch (e) {
      // 文件损坏当作空列表，下次保存会覆盖
    }
    return out;
  }

  private static write(ctx: common.Context, arr: SavedApi[]): void {
    FileStore.writeText(ctx, F_API, JSON.stringify(arr));
  }

  /** 保存/更新一条：同一个地址只留一条，且置顶（最近用过的排前面） */
  static save(ctx: common.Context, name: string, url: string): void {
    const u: string = (url ?? '').trim();
    if (u.length === 0) {
      return;
    }
    const nm: string = (name ?? '').trim();
    const finalName: string = nm.length > 0 ? nm : ApiStore.guessName(u);
    const arr: SavedApi[] = ApiStore.list(ctx);
    const next: SavedApi[] = [{ name: finalName, url: u }];
    for (const a of arr) {
      if (a.url !== u) {
        next.push(a);
      }
    }
    ApiStore.write(ctx, next);
  }

  static rename(ctx: common.Context, url: string, name: string): void {
    const u: string = (url ?? '').trim();
    const nm: string = (name ?? '').trim();
    if (u.length === 0 || nm.length === 0) {
      return;
    }
    const next: SavedApi[] = [];
    let hit: boolean = false;
    for (const a of ApiStore.list(ctx)) {
      if (a.url === u) {
        next.push({ name: nm, url: a.url });
        hit = true;
      } else {
        next.push(a);
      }
    }
    if (!hit) {
      next.push({ name: nm, url: u });
    }
    ApiStore.write(ctx, next);
  }

  static remove(ctx: common.Context, url: string): void {
    const u: string = (url ?? '').trim();
    const next: SavedApi[] = [];
    for (const a of ApiStore.list(ctx)) {
      if (a.url !== u) {
        next.push(a);
      }
    }
    ApiStore.write(ctx, next);
  }

  static nameOf(ctx: common.Context, url: string): string {
    const u: string = (url ?? '').trim();
    if (u.length === 0) {
      return '';
    }
    for (const a of ApiStore.list(ctx)) {
      if (a.url === u) {
        return a.name;
      }
    }
    return '';
  }

  /** 没填名字时，从域名推一个能看的名字：http://example.com/4k.json → example */
  static guessName(url: string): string {
    let s: string = (url ?? '').trim();
    const scheme: number = s.indexOf('://');
    if (scheme >= 0) {
      s = s.substring(scheme + 3);
    }
    let stop: number = s.length;
    const marks: string[] = ['/', '?', '#'];
    for (const m of marks) {
      const k: number = s.indexOf(m);
      if (k >= 0 && k < stop) {
        stop = k;
      }
    }
    s = s.substring(0, stop);
    if (s.startsWith('www.')) {
      s = s.substring(4);
    }
    const dot: number = s.indexOf('.');
    const base: string = dot > 0 ? s.substring(0, dot) : s;
    return base.length > 0 ? base : '自定义接口';
  }
}
