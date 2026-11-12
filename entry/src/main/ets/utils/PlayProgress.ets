import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 播放进度本地存储（续播用）。键为 progId，值为毫秒进度。
 */
const PREF_NAME: string = 'moviebox_play';
const KEY: string = 'progress';
/** 每集观看记录：progId -> 最近一次起播的时间戳（详情页标「看过 / 上次看到」用） */
const WATCHED_KEY: string = 'watched';
/** 上限：只留最近这么多条，别让 preferences 无限涨 */
const WATCHED_MAX: number = 500;

export class PlayProgress {
  static async get(context: common.Context, id: string): Promise<number> {
    const pref = await preferences.getPreferences(context, PREF_NAME);
    const map = pref.getSync(KEY, '{}') as string;
    try {
      const o = JSON.parse(map) as Record<string, number>;
      const v = o[id];
      return typeof v === 'number' ? v : 0;
    } catch (e) {
      return 0;
    }
  }

  static async save(context: common.Context, id: string, ms: number): Promise<void> {
    const pref = await preferences.getPreferences(context, PREF_NAME);
    const map = pref.getSync(KEY, '{}') as string;
    let o: Record<string, number> = {};
    try {
      o = JSON.parse(map) as Record<string, number>;
    } catch (e) {
      o = {};
    }
    o[id] = ms;
    await pref.put(KEY, JSON.stringify(o));
    await pref.flush();
  }

  /**
   * 每次起播（含播放器里切上/下集）记一笔，只记时间戳。
   * 播放历史按影片去重、进度表又没有时间，两个都回答不了「最近看的是哪一集」，
   * 所以单独留一份按集的记录。
   */
  static async mark(context: common.Context, id: string): Promise<void> {
    if (id.length === 0) {
      return;
    }
    const pref = await preferences.getPreferences(context, PREF_NAME);
    const raw: string = pref.getSync(WATCHED_KEY, '{}') as string;
    let o: Record<string, number> = {};
    try {
      o = JSON.parse(raw) as Record<string, number>;
    } catch (e) {
      o = {};
    }
    o[id] = Date.now();
    const keys: string[] = Object.keys(o);
    if (keys.length > WATCHED_MAX) {
      keys.sort((a: string, b: string) => (o[b] ?? 0) - (o[a] ?? 0));
      const keep: Record<string, number> = {};
      for (let i = 0; i < WATCHED_MAX; i++) {
        keep[keys[i]] = o[keys[i]];
      }
      o = keep;
    }
    await pref.put(WATCHED_KEY, JSON.stringify(o));
    await pref.flush();
  }

  /** 读出全部按集观看记录（progId -> 时间戳） */
  static async watched(context: common.Context): Promise<Record<string, number>> {
    const pref = await preferences.getPreferences(context, PREF_NAME);
    const raw: string = pref.getSync(WATCHED_KEY, '{}') as string;
    try {
      return JSON.parse(raw) as Record<string, number>;
    } catch (e) {
      return {};
    }
  }

  /**
   * 所有「有播放进度」的 progId。
   * 升级前的版本只有进度表、没有按集记录，详情页靠它兜底把老片看过的集标暗。
   */
  static async progressIds(context: common.Context): Promise<string[]> {
    const pref = await preferences.getPreferences(context, PREF_NAME);
    const raw: string = pref.getSync(KEY, '{}') as string;
    const out: string[] = [];
    try {
      const o: Record<string, number> = JSON.parse(raw) as Record<string, number>;
      for (const k of Object.keys(o)) {
        if ((o[k] ?? 0) > 0) {
          out.push(k);
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }
}
