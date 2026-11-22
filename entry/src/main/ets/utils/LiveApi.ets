import { HttpUtil } from './HttpUtil';
import { BuiltinConfig } from './BuiltinConfig';
import { LiveCfg } from '../model/TvBoxModels';

/** 一个频道的一条线路（同一个频道常被源站列好几条地址） */
export interface LiveLine {
  name: string;
  url: string;
}

/**
 * 直播频道。
 *
 * 为什么要 id + lines 而不是一条 name/url：
 * 直播源里同一个频道会被列很多次。实测 Guovin 那份 result.m3u 有 1616 条，
 * 但只有 589 个不同频道 —— CCTV-5 列了 10 条、翡翠台 5 条、凤凰资讯 5 条。
 * 以前每条都渲染成一个格子，于是列表里「翡翠台」出现 5 次，而且第一条地址
 * 常常已经串台（放出来是购物台），只能一个个试。
 *
 * 现在按 tvg-id（m3u 有；txt 没有就用频道名）归并成一个频道，地址收进 lines，
 * 播放页可以「换线路」，并把用户最后能放的那条记下来。
 */
export interface LiveChannel {
  /** 频道身份：tvg-id，缺省用频道名 */
  id: string;
  name: string;
  /** 首选线路地址（= lines[0].url），收藏、旧调用都靠它 */
  url: string;
  /** tvg-logo，txt 源没有就空 */
  logo: string;
  lines: LiveLine[];
}

export class LiveGroup {
  name: string = '';
  channels: LiveChannel[] = [];
}

/**
 * 直播源解析：兼容 tvbox 的 txt 频道表（#genre# 分组的 "频道名,地址"）和标准 m3u 播放列表。
 */
export class LiveApi {
  static async load(live: LiveCfg): Promise<LiveGroup[]> {
    // 内置源不发请求：直接解析代码里那份 m3u，断网也能出频道表
    const addr: string = (live === null || live === undefined) ? '' : (live.url ?? '').trim();
    if (BuiltinConfig.isBuiltinLive(addr)) {
      return LiveApi.parseM3u(BuiltinConfig.liveM3u());
    }
    const text = await HttpUtil.getText(live.url);
    if (text.includes('#EXTM3U') || text.includes('#EXTINF')) {
      return LiveApi.parseM3u(text);
    }
    return LiveApi.parseTxt(text);
  }

  // "#genre#" 分组格式；一条频道可以用 # 挂多条线路
  static parseTxt(text: string): LiveGroup[] {
    const groups: LiveGroup[] = [];
    let cur = new LiveGroup();
    cur.name = '默认';
    // key = 分组 + '|' + 频道名：同名同组的多条地址合成一个频道，不同组各留各的
    const index: Map<string, LiveChannel> = new Map();
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('//')) {
        continue;
      }
      if (line.includes('#genre#')) {
        const g = line.split(',')[0].trim();
        if (cur.channels.length > 0) {
          groups.push(cur);
        }
        cur = new LiveGroup();
        cur.name = g ? g : '其他';
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      const idx = line.indexOf(',');
      if (idx <= 0) {
        continue;
      }
      const name = line.substring(0, idx).trim();
      if (LiveApi.isMetaName(name)) {
        continue;
      }
      const urls: string[] = LiveApi.splitUrls(line.substring(idx + 1));
      if (urls.length === 0) {
        continue;
      }
      const key: string = cur.name + '|' + LiveApi.normId(name);
      let ch = index.get(key);
      if (ch === undefined) {
        ch = { id: name, name: name, url: '', logo: '', lines: [] };
        index.set(key, ch);
        cur.channels.push(ch);
      }
      for (const u of urls) {
        LiveApi.pushLine(ch, '', u);
      }
    }
    if (cur.channels.length > 0) {
      groups.push(cur);
    }
    for (const g of groups) {
      LiveApi.sortChannels(g.channels);
    }
    return groups;
  }

  static parseM3u(text: string): LiveGroup[] {
    const groups: LiveGroup[] = [];
    const gmap: Map<string, LiveGroup> = new Map();
    const cmap: Map<string, LiveChannel> = new Map();
    let name = '';
    let group = '默认';
    let tid = '';
    let logo = '';
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (!line) {
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        const comma = line.lastIndexOf(',');
        name = comma >= 0 ? line.substring(comma + 1).trim() : '';
        const g = LiveApi.attr(line, 'group-title');
        group = g ? g : '默认';
        // tvg-id 是频道的稳定身份（换线路不变），没有就退回 tvg-name / 频道名
        const id = LiveApi.attr(line, 'tvg-id');
        const nm = LiveApi.attr(line, 'tvg-name');
        tid = id ? id : (nm ? nm : name);
        logo = LiveApi.attr(line, 'tvg-logo');
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      if (!line.startsWith('http')) {
        continue;
      }
      const chName: string = name ? name : '频道';
      if (LiveApi.isMetaName(chName)) {
        name = '';
        continue;
      }
      const cid: string = (tid ? tid : chName).trim();
      let g = gmap.get(group);
      if (g === undefined) {
        g = new LiveGroup();
        g.name = group;
        gmap.set(group, g);
        groups.push(g);
      }
      const key: string = group + '|' + LiveApi.normId(cid);
      let ch = cmap.get(key);
      if (ch === undefined) {
        ch = { id: cid, name: chName, url: '', logo: logo, lines: [] };
        cmap.set(key, ch);
        g.channels.push(ch);
      }
      LiveApi.pushLine(ch, '', line);
      name = '';
    }
    for (const g of groups) {
      LiveApi.sortChannels(g.channels);
    }
    return groups;
  }

  /**
   * 频道身份归一：同一台在源里常写成 CCTV-13 / CCTV13 / cctv_13 / 中央13台/
   * 央视13 等多种形式，不归一就会被当成两个频道（用户看到「两个中央13台」）。
   * 只做保守归一：统一大小写、去掉横杠/下划线/空格、把常见前缀（cctv/中央/央视）
   * 和中文数字后缀「台」「频道」剥掉；其他字符原样保留，避免 CCTV-5 与
   * CCTV-5+ 体育 被误并成一个。
   */
  private static normId(s: string): string {
    let x: string = (s ?? '').trim().toLowerCase();
    x = x.replace(/[-_\s]/g, '');
    x = x.replace(/^(cctv|中央|央视)/, '');
    x = x.replace(/(台|频道)$/, '');
    // 剥完变空说明名字不符合 cctv 模式，退回原文，免得一批怪名字全并成一个
    return x.length > 0 ? x : (s ?? '').trim().toLowerCase();
  }

  /** 从频道名里取第一个数字，用于自然排序：CCTV-11 → 11，中央13台 → 13 */
  private static chanNum(s: string): number {
    const m = /\d+/.exec(s ?? '');
    return m === null ? Number.MAX_VALUE : parseInt(m[0], 10);
  }

  /**
   * 每组内按频道号数字排：1,2,3…10,11，而不是 1,10,11,2 的字典序。
   * 都没数字的频道（地方台、卫视）保持源里的原顺序，不按拼音重排，
   * 免得用户熟悉的频道顺序被打乱。
   */
  private static sortChannels(list: LiveChannel[]): void {
    list.sort((a: LiveChannel, b: LiveChannel): number => {
      const na: number = LiveApi.chanNum(a.name);
      const nb: number = LiveApi.chanNum(b.name);
      if (na === Number.MAX_VALUE && nb === Number.MAX_VALUE) {
        return 0;
      }
      if (na !== nb) {
        return na - nb;
      }
      return a.name.localeCompare(b.name);
    });
  }

  /** 加一条线路：去重，顺手补上 ch.url */
  private static pushLine(ch: LiveChannel, lineName: string, url: string): void {
    const u: string = (url ?? '').trim();
    if (!u.startsWith('http')) {
      return;
    }
    for (const l of ch.lines) {
      if (l.url === u) {
        return;
      }
    }
    const ln: LiveLine = { name: lineName, url: u };
    ch.lines.push(ln);
    if (ch.url.length === 0) {
      ch.url = u;
    }
  }

  /**
   * 拆一条频道行里的多个地址。
   * tvbox txt 的写法是 "频道名,地址1#地址2#地址3"；有些源还在地址后面挂
   * "|频道名"（EPG 用），所以再按 | 截一次。
   */
  private static splitUrls(raw: string): string[] {
    const out: string[] = [];
    for (const part of raw.split('#')) {
      let u: string = part.trim();
      const bar: number = u.indexOf('|');
      if (bar > 0) {
        u = u.substring(0, bar).trim();
      }
      if (u.length > 4 && u.startsWith('http')) {
        out.push(u);
      }
    }
    return out;
  }

  /**
   * 源站在列表里塞的「伪频道」：Guovin 那份的第一组是「🕘️更新时间」，
   * 里面唯一的条目叫 "2026-08-27 14:06:22"，点进去必然放不出来。
   * 纯日期、含「更新时间」的一律当元信息丢掉。
   */
  private static isMetaName(n: string): boolean {
    const s: string = (n ?? '').trim();
    if (s.length === 0) {
      return true;
    }
    if (s.includes('更新时间')) {
      return true;
    }
    if (s.length >= 8 && /^\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2}/.test(s)) {
      return true;
    }
    return false;
  }

  private static attr(line: string, key: string): string {
    const k = key + '="';
    const i = line.indexOf(k);
    if (i < 0) {
      return '';
    }
    const s = i + k.length;
    const e = line.indexOf('"', s);
    if (e < 0) {
      return '';
    }
    return line.substring(s, e);
  }
}
