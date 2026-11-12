import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';
import { BuiltinConfig } from './BuiltinConfig';
import { AppState } from './AppState';
import { SiteCfg } from '../model/TvBoxModels';

/**
 * 「自己的 Default」：把从别的接口里试出来能出内容的站点，一个个收进内置 Default。
 *
 * 背景：内置 Default 原本是代码里写死的一条采集站。用户导入第三方配置 → 试出
 * 能播的站 → 想把这条留下来，但第三方接口会失效、会被换掉。所以这里单独存一份
 * 用户收集的站点清单（私有目录 tvbox_my_sites.json），BuiltinConfig.text() 会把它
 * 和内置站拼成同一份配置文本；之后在地址簿里点「Default」就能看到全部成果。
 *
 * 设计取舍：
 * - 收的是站点本身（key/name/type/api/ext…），不是配置地址，所以源接口挂了也不影响；
 * - 按 api 去重（大小写、结尾斜杠不敏感），同一条站从两个接口里试到也只留一份；
 * - 只收 AppState.isUsable 的站点（type 0/1 + http api），spider 站收进来也跑不了；
 * - 本工程不预置站点，Default 里所有站点都来自用户收集，随时可以删；
 * - 这个文件不参与 ConfigStore.clearAll：清空配置是重置接口，不该把慢慢收集的成果抹掉。
 */

const F_MY: string = 'tvbox_my_sites.json';

/** 落盘结构：字段与配置 JSON 里的 sites 元素完全一致，可直接拼回配置文本 */
interface MySiteRec {
  key?: string;
  name?: string;
  type?: number;
  api?: string;
  ext?: string;
  searchable?: boolean;
  quickSearch?: boolean;
  filterable?: boolean;
  jar?: string;
  playerType?: number;
}

export class MySitesStore {
  /** 启动时读盘并同步给 BuiltinConfig，之后所有取内置文本的地方都能带上收集成果 */
  static init(ctx: common.Context): void {
    MySitesStore.sync(MySitesStore.read(ctx));
  }

  static count(ctx: common.Context): number {
    return MySitesStore.read(ctx).length;
  }

  /** 已收站点的规范化 api，UI 用它判断「✓ 已收」 */
  static apis(ctx: common.Context): string[] {
    const out: string[] = [];
    const builtin: string = MySitesStore.normApi(BuiltinConfig.BUILTIN_API);
    if (builtin.length > 0) {
      out.push(builtin);
    }
    for (const r of MySitesStore.read(ctx)) {
      out.push(MySitesStore.normApi(r.api ?? ''));
    }
    return out;
  }

  static contains(ctx: common.Context, api: string): boolean {
    const key: string = MySitesStore.normApi(api);
    if (key.length === 0) {
      return false;
    }
    if (key === MySitesStore.normApi(BuiltinConfig.BUILTIN_API)) {
      return true;
    }
    for (const r of MySitesStore.read(ctx)) {
      if (MySitesStore.normApi(r.api ?? '') === key) {
        return true;
      }
    }
    return false;
  }

  /** 用户自己收进来的站点 api（规范化后）；设置页用它判断哪些行能删 */
  static userApis(ctx: common.Context): string[] {
    const out: string[] = [];
    for (const r of MySitesStore.read(ctx)) {
      out.push(MySitesStore.normApi(r.api ?? ''));
    }
    return out;
  }

  /**
   * 从 Default 移出一条用户收集站。
   * 返回可直接显示的提示。
   */
  static remove(ctx: common.Context, api: string): string {
    const key: string = MySitesStore.normApi(api);
    if (key.length === 0) {
      return '这个站点没有 api 地址，删不了';
    }
    if (key === MySitesStore.normApi(BuiltinConfig.BUILTIN_API)) {
      return '这是 Default 预设的站点，不能删除';
    }
    const arr: MySiteRec[] = MySitesStore.read(ctx);
    const next: MySiteRec[] = [];
    let name: string = '';
    let hit: boolean = false;
    for (const r of arr) {
      if (MySitesStore.normApi(r.api ?? '') === key) {
        hit = true;
        name = (r.name ?? '').trim();
      } else {
        next.push(r);
      }
    }
    if (!hit) {
      return '这条站点不在你收集的 Default 清单里，不能删';
    }
    if (!MySitesStore.write(ctx, next)) {
      return '保存失败：本地文件写不进去';
    }
    return '已从 Default 删除「' + (name.length > 0 ? name : '站点') + '」（现在共 '
      + next.length + ' 个站点）';
  }

  /** 点一下加入，再点一下移出；返回可直接显示给用户的提示 */
  static toggle(ctx: common.Context, s: SiteCfg): string {
    if (!AppState.isUsable(s)) {
      return '这个站点需要 spider 引擎，收进 Default 也播不了';
    }
    const api: string = (s.api ?? '').trim();
    const key: string = MySitesStore.normApi(api);
    if (key.length === 0) {
      return '这个站点没有 api 地址，无法收藏';
    }
    if (key === MySitesStore.normApi(BuiltinConfig.BUILTIN_API)) {
      return '这是 Default 自带的站点，不用收';
    }
    const arr: MySiteRec[] = MySitesStore.read(ctx);
    let hit: number = -1;
    for (let i = 0; i < arr.length; i++) {
      if (MySitesStore.normApi(arr[i].api ?? '') === key) {
        hit = i;
        break;
      }
    }
    let msg: string;
    let next: MySiteRec[];
    if (hit >= 0) {
      const nm: string = (arr[hit].name ?? '').trim();
      next = [];
      for (let i = 0; i < arr.length; i++) {
        if (i !== hit) {
          next.push(arr[i]);
        }
      }
      msg = '已从 Default 移出「' + (nm.length > 0 ? nm : '站点') + '」';
    } else {
      const rec: MySiteRec = {
        key: s.key,
        name: s.name,
        type: s.type,
        api: api,
        searchable: s.searchable,
        quickSearch: s.quickSearch,
        filterable: s.filterable
      };
      if ((s.ext ?? '').length > 0) {
        rec.ext = s.ext;
      }
      if ((s.jar ?? '').length > 0) {
        rec.jar = s.jar;
      }
      if (s.playerType !== 0) {
        rec.playerType = s.playerType;
      }
      next = [];
      for (const r of arr) {
        next.push(r);
      }
      next.push(rec);
      const nm: string = (s.name ?? '').trim();
      msg = '已收进 Default：' + (nm.length > 0 ? nm : api);
    }
    if (!MySitesStore.write(ctx, next)) {
      return '保存失败：本地文件写不进去';
    }
    return msg + '（Default 现在共 ' + (next.length + 1) + ' 个站点）';
  }

  private static read(ctx: common.Context): MySiteRec[] {
    const txt: string = FileStore.readText(ctx, F_MY);
    if (!txt) {
      return [];
    }
    try {
      const arr = JSON.parse(txt) as MySiteRec[];
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: MySiteRec[] = [];
      for (const r of arr) {
        if (r !== null && typeof r === 'object' && ((r.api ?? '').trim().length > 0)) {
          out.push(r);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private static write(ctx: common.Context, arr: MySiteRec[]): boolean {
    const ok: boolean = FileStore.writeText(ctx, F_MY, JSON.stringify(arr));
    // 写盘失败也要更新内存，至少本次运行内切回 Default 能看到
    MySitesStore.sync(arr);
    return ok;
  }

  /** 把清单同步成 BuiltinConfig 可以直接拼接的站点 JSON 片段 */
  private static sync(arr: MySiteRec[]): void {
    const parts: string[] = [];
    for (const r of arr) {
      parts.push(JSON.stringify(r));
    }
    BuiltinConfig.setExtras(parts);
  }

  /** api 归一化：忽略大小写与结尾斜杠，避免同一条站被收两次（设置页也要用） */
  static normApi(api: string): string {
    let s: string = (api ?? '').trim().toLowerCase();
    while (s.length > 0 && s.charAt(s.length - 1) === '/') {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
