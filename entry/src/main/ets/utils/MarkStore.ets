import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';

/**
 * 收藏 / 播放历史。
 * 都用应用私有目录下的 JSON 文件存，历史按时间倒序、同一影片去重、最多 100 条。
 */
export interface VodMark {
  siteKey: string;
  vodId: string;
  name: string;
  pic: string;
  remarks: string;
  time: number;
  /**
   * 影片所属分类名（详情页 d.type_name）。历史页靠它判断是不是敏感词分类下的片子。
   * 可选：升级前的老记录没有这个字段，历史页会退回按片名兜底。
   */
  typeName?: string;
}

const F_FAV: string = 'tvbox_fav.json';
const F_HIS: string = 'tvbox_history.json';
const HIS_MAX: number = 100;

export class MarkStore {
  private static read(ctx: common.Context, name: string): VodMark[] {
    const text = FileStore.readText(ctx, name);
    if (!text) {
      return [];
    }
    try {
      const list = JSON.parse(text) as VodMark[];
      return list ?? [];
    } catch (e) {
      return [];
    }
  }

  private static write(ctx: common.Context, name: string, list: VodMark[]): void {
    FileStore.writeText(ctx, name, JSON.stringify(list));
  }

  // ---------- 收藏 ----------
  static listFav(ctx: common.Context): VodMark[] {
    return MarkStore.read(ctx, F_FAV);
  }

  static isFav(ctx: common.Context, siteKey: string, vodId: string): boolean {
    for (const m of MarkStore.read(ctx, F_FAV)) {
      if (m.siteKey === siteKey && m.vodId === vodId) {
        return true;
      }
    }
    return false;
  }

  // 返回切换后的状态：true = 已收藏
  static toggleFav(ctx: common.Context, mark: VodMark): boolean {
    const list = MarkStore.read(ctx, F_FAV);
    const out: VodMark[] = [];
    let removed = false;
    for (const m of list) {
      if (m.siteKey === mark.siteKey && m.vodId === mark.vodId) {
        removed = true;
        continue;
      }
      out.push(m);
    }
    if (!removed) {
      out.unshift(mark);
    }
    MarkStore.write(ctx, F_FAV, out);
    return !removed;
  }

  static removeFav(ctx: common.Context, siteKey: string, vodId: string): void {
    const out: VodMark[] = [];
    for (const m of MarkStore.read(ctx, F_FAV)) {
      if (m.siteKey === siteKey && m.vodId === vodId) {
        continue;
      }
      out.push(m);
    }
    MarkStore.write(ctx, F_FAV, out);
  }

  static clearFav(ctx: common.Context): void {
    MarkStore.write(ctx, F_FAV, []);
  }

  // ---------- 历史 ----------
  static listHistory(ctx: common.Context): VodMark[] {
    return MarkStore.read(ctx, F_HIS);
  }

  static addHistory(ctx: common.Context, mark: VodMark): void {
    const list = MarkStore.read(ctx, F_HIS);
    const out: VodMark[] = [mark];
    for (const m of list) {
      if (m.siteKey === mark.siteKey && m.vodId === mark.vodId) {
        continue;
      }
      out.push(m);
    }
    while (out.length > HIS_MAX) {
      out.pop();
    }
    MarkStore.write(ctx, F_HIS, out);
  }

  static removeHistory(ctx: common.Context, siteKey: string, vodId: string): void {
    const out: VodMark[] = [];
    for (const m of MarkStore.read(ctx, F_HIS)) {
      if (m.siteKey === siteKey && m.vodId === vodId) {
        continue;
      }
      out.push(m);
    }
    MarkStore.write(ctx, F_HIS, out);
  }

  static clearHistory(ctx: common.Context): void {
    MarkStore.write(ctx, F_HIS, []);
  }

  /**
   * 给老历史记录补分类名：详情页打开旧片子时顺手补上，历史页就能精确隐藏敏感分类。
   * 只改字段，不动 time、不重排，所以「点开看一眼」不会把旧记录顶到列表最前。
   */
  static patchHistoryType(ctx: common.Context, siteKey: string, vodId: string, typeName: string): void {
    const list = MarkStore.read(ctx, F_HIS);
    let changed: boolean = false;
    for (const m of list) {
      if (m.siteKey === siteKey && m.vodId === vodId && m.typeName !== typeName) {
        m.typeName = typeName;
        changed = true;
      }
    }
    if (changed) {
      MarkStore.write(ctx, F_HIS, list);
    }
  }
}
