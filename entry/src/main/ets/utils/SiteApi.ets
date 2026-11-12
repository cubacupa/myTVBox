import { HttpUtil } from './HttpUtil';
import { SiteCfg, PlayLine } from '../model/TvBoxModels';
import { VodItem, VodDetail, VodClass, VodEpisode } from '../model/VodItem';

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

  static async getClasses(site: SiteCfg): Promise<VodClass[]> {
    const url = SiteApi.buildUrl(site.api, 'ac=list');
    const data = await HttpUtil.getJson<CmsResp>(url);
    return data.class ?? [];
  }

  // extra 为筛选参数串（area=大陆&year=2026），为空则不带
  static async getList(site: SiteCfg, typeId: string, page: number, extra: string): Promise<VodListResult> {
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
      pageCount: data.pagecount ?? 1
    };
    return r;
  }

  static async search(site: SiteCfg, wd: string, page: number): Promise<VodListResult> {
    const q = 'ac=videolist&wd=' + encodeURIComponent(wd) + '&pg=' + page;
    const data = await HttpUtil.getJson<CmsResp>(SiteApi.buildUrl(site.api, q));
    const r: VodListResult = {
      items: data.list ?? [],
      page: page,
      pageCount: data.pagecount ?? 1
    };
    return r;
  }

  static async getDetail(site: SiteCfg, ids: string): Promise<VodDetail | null> {
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
