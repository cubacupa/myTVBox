import { J } from './JsonUtil';
import { LenientJson } from './LenientJson';
import { SiteCfg, ParseCfg, LiveCfg, RepoCfg, TvBoxConfig } from '../model/TvBoxModels';

/**
 * TVBox 配置解析器。
 * 兼容两种形态：
 * 1) 普通配置：{ sites, parses, lives, spider, wallpaper }
 * 2) 多仓配置：{ urls: [ { name, url } ] }（urls 里也可能是纯字符串）
 *
 * 注意：真实配置基本都不是严格 JSON（含 // 注释、尾逗号、裸控制字符），
 * 因此走 LenientJson 清洗后再解析；解析失败直接抛错，由调用方展示原因，
 * 不再静默返回空配置（那样会出现"导入成功但 0 个站点"的假象）。
 */
export class ConfigParser {
  static parse(text: string): TvBoxConfig {
    const cfg = new TvBoxConfig();
    cfg.raw = text;
    let root: Record<string, Object> | null = null;
    try {
      root = J.obj(LenientJson.parse<Object>(text));
    } catch (e) {
      throw new Error('配置不是合法 JSON：' + (e as Error).message);
    }
    if (root === null) {
      throw new Error('配置顶层不是 JSON 对象');
    }

    // 多仓
    const urls = J.arr(root, 'urls');
    if (urls.length > 0) {
      cfg.isRepo = true;
      for (const u of urls) {
        const repo = new RepoCfg();
        const uo = J.obj(u);
        if (uo !== null) {
          repo.url = J.str(uo, 'url', '');
          repo.name = J.str(uo, 'name', '');
        } else if (typeof u === 'string') {
          repo.url = u as string;
        }
        if (repo.url) {
          if (!repo.name) {
            repo.name = ConfigParser.shortName(repo.url);
          }
          cfg.repos.push(repo);
        }
      }
      return cfg;
    }

    cfg.sites = ConfigParser.readSites(root);
    cfg.parses = ConfigParser.readParses(root);
    cfg.lives = ConfigParser.readLives(root);
    cfg.spider = J.str(root, 'spider', '');
    cfg.wallpaper = J.str(root, 'wallpaper', '');
    cfg.flags = ConfigParser.readStringArray(root, 'flags');
    return cfg;
  }

  private static shortName(url: string): string {
    const clean = url.split('?')[0];
    const parts = clean.split('/');
    if (parts.length > 0) {
      return parts[parts.length - 1];
    }
    return url;
  }

  private static readStringArray(o: Record<string, Object>, key: string): string[] {
    const out: string[] = [];
    for (const v of J.arr(o, key)) {
      if (typeof v === 'string') {
        out.push(v as string);
      }
    }
    return out;
  }

  private static readSites(root: Record<string, Object>): SiteCfg[] {
    const out: SiteCfg[] = [];
    for (const it of J.arr(root, 'sites')) {
      const o = J.obj(it);
      if (o === null) {
        continue;
      }
      const s = new SiteCfg();
      s.key = J.str(o, 'key', '');
      s.name = J.str(o, 'name', '');
      s.type = J.num(o, 'type', 1);
      s.api = J.str(o, 'api', '');
      s.ext = J.raw(o, 'ext');
      s.searchable = J.bool(o, 'searchable', true);
      s.quickSearch = J.bool(o, 'quickSearch', true);
      s.filterable = J.bool(o, 'filterable', false);
      s.jar = J.str(o, 'jar', '');
      s.playerType = J.num(o, 'playerType', 0);
      if (!s.api && !s.jar) {
        continue;
      }
      if (!s.name) {
        s.name = s.key;
      }
      if (!s.key) {
        s.key = s.name;
      }
      out.push(s);
    }
    return out;
  }

  private static readParses(root: Record<string, Object>): ParseCfg[] {
    const out: ParseCfg[] = [];
    for (const it of J.arr(root, 'parses')) {
      const o = J.obj(it);
      if (o === null) {
        continue;
      }
      const p = new ParseCfg();
      p.name = J.str(o, 'name', '');
      p.type = J.num(o, 'type', 1);
      p.url = J.str(o, 'url', '');
      // ext 里的 flag 可能是 ["qq","youku"]，也可能是一串 "qq|youku"
      const ext = J.obj(o['ext']);
      if (ext !== null) {
        for (const f of J.arr(ext, 'flag')) {
          if (typeof f === 'string') {
            p.flags.push((f as string).toLowerCase());
          }
        }
        if (p.flags.length === 0) {
          const fs = J.str(ext, 'flag', '');
          if (fs) {
            for (const f of fs.split('|')) {
              if (f) {
                p.flags.push(f.trim().toLowerCase());
              }
            }
          }
        }
      }
      if (p.url) {
        out.push(p);
      }
    }
    return out;
  }

  private static readLives(root: Record<string, Object>): LiveCfg[] {
    const out: LiveCfg[] = [];
    for (const it of J.arr(root, 'lives')) {
      const o = J.obj(it);
      if (o === null) {
        continue;
      }
      const l = new LiveCfg();
      l.name = J.str(o, 'name', '直播');
      l.type = J.num(o, 'type', 0);
      l.url = J.str(o, 'url', '');
      l.epg = J.str(o, 'epg', '');
      l.logo = J.str(o, 'logo', '');
      l.playerType = J.num(o, 'playerType', 0);
      if (l.url) {
        out.push(l);
      }
    }
    return out;
  }
}
