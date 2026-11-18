import { HttpUtil } from './HttpUtil';
import { SiteCfg, PlayLine } from '../model/TvBoxModels';
import { VodItem, VodDetail, VodClass, VodEpisode } from '../model/VodItem';
import { KazumiRuleApi, parseKazumiRule, KazumiListResult, KazumiRule } from './KazumiRuleApi';

/**
 * 站点协议适配：苹果CMS V10 JSON 接口（TVBox 里绝大多数 http 型站点都是这套）。
 * 约定：api?ac=list 取分类；ac=videolist 取列表；ac=detail 取详情。
 */
interface CmsResp {
  code?: number;
  msg?: string;
  page?: number;
  pagecount?: number;
  total?: number;
  list?: VodItem[];
  class?: VodClass[];
}

export interface VodListResult {
  items: VodItem[];
  page: number;
  pageCount: number;
  /**
   * 该分类**总共有多少部**（接口的 total 字段）。
   * 必须用这个，不能用 items.length——列表是懒加载的，items 只是已加载的那几页，
   * 界面上写「共 N 部」会随着下拉不断变大，纯属误导。
   * 少数站点不返回 total（为 0），此时界面上不显示数量。
   */
  total: number;
}

export class SiteApi {
  static buildUrl(api: string, query: string): string {
    const base = (api ?? '').trim();
    // api 以 ? 或 & 结尾时直接接参数，避免拼出 "?&ac=list" 这种空参数（部分服务端会回 400）
    if (base.endsWith('?') || base.endsWith('&')) {
      return base + query;
    }
    const sep = base.includes('?') ? '&' : '?';
    return base + sep + query;
  }

  /**
   * type=9：Kazumi 风格 API 规则站（ext 里放规则 JSON）。
   * 这类规则只有「按关键词搜索」和「按 source 取详情」，没有苹果CMS 的分类/list 接口。
   * 造一个虚拟分类「全部番剧」：getList 用空关键词调搜索接口，等于浏览全库。
   */
  private static isKazumi(site: SiteCfg): boolean {
    return site.type === 9;
  }

  /** 虚拟分类的 type_id：仅用于让点播页有分类可选，真正请求时忽略 */
  private static readonly KAZUMI_ALL_ID: string = '__kazumi_all__';

  private static ruleOf(site: SiteCfg) {
    return parseKazumiRule(site.ext ?? '');
  }

  /** 给分类浏览这类页面用的公开入口：拿当前站点的规则（非规则站返回 null） */
  static ruleFor(site: SiteCfg): KazumiRule | null {
    if (!SiteApi.isKazumi(site)) {
      return null;
    }
    return SiteApi.ruleOf(site);
  }

  /**
   * 网页（XPath）模式的规则站：搜索、详情都要在隐藏 WebView 里真跑一遍页面，
   * 一次要好几秒。聚合搜索里跳过它们，否则一个站就能把整轮搜索拖到十几秒。
   */
  static isWebRule(site: SiteCfg): boolean {
    if (!SiteApi.isKazumi(site)) {
      return false;
    }
    const r = SiteApi.ruleOf(site);
    // 「慢」是慢在搜索要跑 WebView。混合规则（API 搜索 + XPath 选集）
    // 搜索走的是普通 HTTP 接口，聚合时不该跳过。
    return r !== null && r.searchApi === null && KazumiRuleApi.isXPathRule(r);
  }

  static async getClasses(site: SiteCfg): Promise<VodClass[]> {
    if (SiteApi.isKazumi(site)) {
      const all: VodClass = { type_id: SiteApi.KAZUMI_ALL_ID, type_name: '最新更新' };
      return [all];
    }
    const url = SiteApi.buildUrl(site.api, 'ac=list');
    const data = await HttpUtil.getJson<CmsResp>(url);
    return data.class ?? [];
  }

  // extra 为筛选参数串（area=大陆&year=2026），为空则不带
  static async getList(site: SiteCfg, typeId: string, page: number, extra: string): Promise<VodListResult> {
    if (SiteApi.isKazumi(site)) {
      const r = SiteApi.ruleOf(site);
      if (r === null || (!KazumiRuleApi.isApiRule(r) && !KazumiRuleApi.isXPathRule(r))) {
        return { items: [], page: page, pageCount: 1, total: 0 };
      }
      // 网页模式规则没有分类接口。这类站基本都是 macCMS，模板自带
      // index.php/ajax/data（只认 page/limit，回全库按更新时间倒序），
      // 优先用它做全库浏览；接口关掉时才退回「空关键词搜一次」的老办法。
      if (!KazumiRuleApi.isApiRule(r)) {
        const cms: KazumiListResult | null = await KazumiRuleApi.browseCms(r, page);
        if (cms !== null) {
          return {
            items: cms.items,
            page: page,
            pageCount: cms.pageCount ?? 1,
            total: cms.total
          };
        }
        if (page > 1) {
          return { items: [], page: page, pageCount: 1, total: 0 };
        }
      }
      const got = await KazumiRuleApi.search(r, '', page);
      if (!KazumiRuleApi.isApiRule(r)) {
        return { items: got.items, page: 1, pageCount: 1, total: got.items.length };
      }
      const q: Record<string, Object> = r.searchApi === null ? {} : (r.searchApi.query ?? {});
      const limit: number = Number(q['limit'] ?? 24) || 24;
      const pageCount: number = got.total > 0 ? Math.ceil(got.total / limit) : 1;
      return { items: got.items, page: page, pageCount: pageCount, total: got.total };
    }
    let q = typeId
      ? ('ac=videolist&t=' + typeId + '&pg=' + page)
      : ('ac=videolist&pg=' + page);
    if (extra) {
      q = q + '&' + extra;
    }
    const data = await HttpUtil.getJson<CmsResp>(SiteApi.buildUrl(site.api, q));
    const r: VodListResult = {
      items: data.list ?? [],
      page: page,
      pageCount: data.pagecount ?? 1,
      total: data.total ?? 0
    };
    return r;
  }

  static async search(site: SiteCfg, wd: string, page: number): Promise<VodListResult> {
    if (SiteApi.isKazumi(site)) {
      const r = SiteApi.ruleOf(site);
      if (r === null || (!KazumiRuleApi.isApiRule(r) && !KazumiRuleApi.isXPathRule(r))) {
        return { items: [], page: page, pageCount: 1, total: 0 };
      }
      const got = await KazumiRuleApi.search(r, wd, page);
      return { items: got.items, page: page, pageCount: 1, total: got.total };
    }
    const q = 'ac=videolist&wd=' + encodeURIComponent(wd) + '&pg=' + page;
    const data = await HttpUtil.getJson<CmsResp>(SiteApi.buildUrl(site.api, q));
    const r: VodListResult = {
      items: data.list ?? [],
      page: page,
      pageCount: data.pagecount ?? 1,
      total: data.total ?? 0
    };
    return r;
  }

  static async getDetail(site: SiteCfg, ids: string): Promise<VodDetail | null> {
    if (SiteApi.isKazumi(site)) {
      const r = SiteApi.ruleOf(site);
      if (r === null || (!KazumiRuleApi.isApiRule(r) && !KazumiRuleApi.isXPathRule(r))) {
        return null;
      }
      return await KazumiRuleApi.getDetail(r, ids);
    }
    const url = SiteApi.buildUrl(site.api, 'ac=detail&ids=' + ids);
    const data = await HttpUtil.getJson<CmsResp>(url);
    if (data.list && data.list.length > 0) {
      return data.list[0];
    }
    return null;
  }

  // vod_play_from / vod_play_url 都是 $$$ 分线路，线路内 # 分集、$ 分"集名/地址"
  static parseLines(d: VodDetail): PlayLine[] {
    const froms: string[] = (d.vod_play_from ?? '').split('$$$');
    const urls: string[] = (d.vod_play_url ?? '').split('$$$');
    const lines: PlayLine[] = [];
    for (let i = 0; i < urls.length; i++) {
      const line = new PlayLine();
      if (i < froms.length && froms[i]) {
        line.name = froms[i];
      } else {
        line.name = '线路' + (i + 1);
      }
      line.episodes = SiteApi.parseEpisodes(urls[i]);
      if (line.episodes.length > 0) {
        lines.push(line);
      }
    }
    return lines;
  }

  static parseEpisodes(raw: string): VodEpisode[] {
    const eps: VodEpisode[] = [];
    if (!raw) {
      return eps;
    }
    for (const p of raw.split('#')) {
      if (!p) {
        continue;
      }
      const i = p.indexOf('$');
      if (i > 0) {
        const ep: VodEpisode = { name: p.substring(0, i), url: p.substring(i + 1) };
        eps.push(ep);
      } else {
        const ep: VodEpisode = { name: p, url: p };
        eps.push(ep);
      }
    }
    return eps;
  }
}
