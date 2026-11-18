import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { VodItem, VodDetail } from '../model/VodItem';
import { SiteCfg } from '../model/TvBoxModels';
import { J } from './JsonUtil';
import { SiteApi } from './SiteApi';
import { sniffer } from './WebSniffer';
import { RuleCategory } from './RuleCategories';
import { HttpUtil } from './HttpUtil';

/** 抓站点页面统一用桌面 UA：番剧站按 UA 分流，手机 UA 拿到的是另一套模板 */
const CMS_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/**
 * Kazumi 风格 API 规则适配器（路线 B 第一步）。
 *
 * 背景：Kazumi 的 XPath 规则靠 WebView 执行混淆 JS 才能拿到 m3u8，原生 ArkTS 做不了；
 * 但它新版的 API 模式规则（searchMode/chapterMode = api）直接用 HTTP JSON 交换，
 * 其中 delimited 格式返回的就是苹果CMS 同构的 vod_play_from / vod_play_url，
 * 可以直接喂给 SiteApi.parseLines()，不需要 WebView。
 *
 * 本模块只覆盖 API 模式；不含 XPath、不含 JS 嗅探。
 */

const UA: string =
  'Mozilla/5.0 (Linux; Android 10; SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';

interface ApiRequest {
  method?: string;
  url: string;
  query?: Record<string, Object>;
  headers?: Record<string, Object>;
  bodyType?: string;
  body?: Record<string, Object>;
}

export interface KazumiRule {
  name: string;
  baseURL: string;
  userAgent: string;
  searchMode: string;
  chapterMode: string;
  /** 规则的内容分类：官方字段叫 type（默认 anime），部分第三方规则写 category */
  category: string;
  searchApi: ApiRequest | null;
  searchListPath: string;
  searchNamePath: string;
  searchSourcePath: string;
  searchPicPath: string;
  chapterApi: ApiRequest | null;
  chapterFormat: string;
  roadNamesPath: string;
  roadEpisodesPath: string;
  roadSeparator: string;
  episodeSeparator: string;
  fieldSeparator: string;
  /** API 搜索给的 id 不一定是地址，有的规则用模板拼出详情页（@source） */
  searchSourceTemplate: string;
  // ---- 网页（XPath）模式：老格式规则与 api/xpath 规则用这一套 ----
  searchURL: string;
  searchList: string;
  searchName: string;
  searchResult: string;
  chapterRoads: string;
  chapterResult: string;
  // ---- nested 格式（milimili / sorani / xfdmnext 这类）：剧集只给播放页 id ----
  roadsPath: string;
  roadNamePath: string;
  episodesPath: string;
  episodeNamePath: string;
  episodeUrlPath: string;
  episodePageUrl: string;
  episodePageQuery: Record<string, Object>;
}

export interface KazumiListResult {
  items: VodItem[];
  total: number;
  /** 只有全库浏览（macCMS 数据接口）会带：接口报的总页数 */
  pageCount?: number;
}

/** macCMS 站点 index.php/ajax/data 的一项（只声明用得到的字段） */
interface CmsDataItem {
  vod_id?: number | string;
  vod_name?: string;
  vod_pic?: string;
  vod_remarks?: string;
  vod_year?: string;
  vod_area?: string;
  detail_link?: string;
  /** 列表接口其实带全了这几个，之前没用上，导致详情页没有简介 */
  vod_content?: string;
  vod_blurb?: string;
  vod_actor?: string;
  vod_director?: string;
  vod_lang?: string;
  vod_class?: string;
  type?: CmsDataType;
}

interface CmsDataType {
  type_name?: string;
}

interface CmsDataResp {
  code?: number;
  page?: number;
  pagecount?: number;
  total?: number;
  list?: CmsDataItem[];
}

/** 影片元信息：列表接口 / 详情页 HTML 里能拿到的部分，用来补详情页的空白 */
interface CmsMeta {
  name: string;
  pic: string;
  content: string;
  year: string;
  area: string;
  remarks: string;
  typeName: string;
}

/** nested 剧集拼出来的线路（供 VodDetail 的 $$$ / # / $ 串用） */
interface NestedLines {
  froms: string[];
  urls: string[];
}

// ---------------- 规则解析 ----------------

/**
 * 规则的内容分类。官方字段是 type（默认 anime），第三方规则偶尔写成 category /
 * categories（数组取第一个）。都没有就按 anime 算——官方 86 条规则里 84 条都是它。
 */
function categoryField(root: Record<string, Object>): string {
  for (const k of ['type', 'category', 'categories']) {
    const v: Object | undefined = root[k];
    if (v === undefined || v === null) {
      continue;
    }
    if (typeof v === 'string') {
      const s: string = (v as string).trim();
      if (s.length > 0) {
        return s;
      }
    } else if (Array.isArray(v)) {
      const arr: Object[] = v as Object[];
      if (arr.length > 0 && typeof arr[0] === 'string') {
        return (arr[0] as string).trim();
      }
    }
  }
  return 'anime';
}

/** 规则的分类值 → 界面用的分类名（家长锁分类过滤、豆瓣匹配都按这个名字走） */
export function categoryName(cat: string): string {
  const raw: string = (cat ?? '').trim();
  const s: string = raw.toLowerCase();
  if (s.length === 0) {
    return '番剧';
  }
  if (s === 'anime' || s === 'bangumi' || raw === '动漫' || raw === '动画' || raw === '番剧') {
    return '番剧';
  }
  if (s === 'movie' || s === 'film' || raw === '电影') {
    return '电影';
  }
  if (s === 'tv' || s === 'tvshow' || s === 'series' || raw === '电视剧' || raw === '剧集') {
    return '电视剧';
  }
  if (s === 'documentary' || raw === '纪录片') {
    return '纪录片';
  }
  if (s === 'variety' || raw === '综艺') {
    return '综艺';
  }
  // dms.json 把 type 写成 "1"，这种明显是写错的，别拿数字当分类名
  if (/^[0-9]+$/.test(s)) {
    return '番剧';
  }
  return raw;
}

function reqOf(v: Object | null | undefined): ApiRequest | null {
  const o: Record<string, Object> | null = J.obj(v);
  if (o === null) {
    return null;
  }
  const url: string = J.str(o, 'url', '');
  if (url.length === 0) {
    return null;
  }
  const r: ApiRequest = { url: url };
  r.method = J.str(o, 'method', 'GET');
  r.query = J.obj(o['query']) ?? {};
  r.headers = J.obj(o['headers']) ?? {};
  r.bodyType = J.str(o, 'bodyType', 'json');
  r.body = J.obj(o['body']) ?? {};
  return r;
}

export function parseKazumiRule(text: string): KazumiRule | null {
  if (!text || text.trim().length === 0) {
    return null;
  }
  let root: Record<string, Object> | null = null;
  try {
    root = J.obj(JSON.parse(text) as Object);
  } catch (e) {
    return null;
  }
  if (root === null) {
    return null;
  }
  const sc: Record<string, Object> | null = J.obj(root['searchApiConfig']);
  const cc: Record<string, Object> | null = J.obj(root['chapterApiConfig']);
  // 折叠默认值：与 Kazumi 的 ApiSearchConfig / ApiChapterConfig.fromJson 完全一致，
  // 少了这些默认值，像 milimili 这种「只写 roadsPath + 两个路径」的规则会一条线路都拼不出来。
  const r: KazumiRule = {
    name: J.str(root, 'name', ''),
    baseURL: J.str(root, 'baseURL', ''),
    userAgent: J.str(root, 'userAgent', ''),
    searchMode: J.str(root, 'searchMode', ''),
    chapterMode: J.str(root, 'chapterMode', ''),
    // 官方的分类字段是 type（默认 anime），顺手也认 category，省得第三方规则白丢
    category: categoryField(root),
    searchApi: sc === null ? null : reqOf(sc['request']),
    searchListPath: sc === null ? '' : J.str(sc, 'listPath', '$.data[*]'),
    searchNamePath: sc === null ? '' : J.str(sc, 'namePath', '$.name'),
    searchSourcePath: sc === null ? '' : J.str(sc, 'sourcePath', '$.url'),
    searchPicPath: sc === null ? '' : J.str(sc, 'picPath', ''),
    searchSourceTemplate: sc === null ? '' : J.str(sc, 'sourceTemplate', ''),
    searchURL: J.str(root, 'searchURL', ''),
    searchList: J.str(root, 'searchList', ''),
    searchName: J.str(root, 'searchName', ''),
    searchResult: J.str(root, 'searchResult', ''),
    chapterRoads: J.str(root, 'chapterRoads', ''),
    chapterResult: J.str(root, 'chapterResult', ''),
    chapterApi: cc === null ? null : reqOf(cc['request']),
    // Kazumi 只有 nested / delimited 两种格式，缺省且不是 delimited 就按 nested
    chapterFormat: cc === null ? '' : (J.str(cc, 'format', '') === 'delimited' ? 'delimited' : 'nested'),
    roadNamesPath: cc === null ? '' : J.str(cc, 'roadNamesPath', ''),
    roadEpisodesPath: cc === null ? '' : J.str(cc, 'roadEpisodesPath', ''),
    roadSeparator: cc === null ? '' : J.str(cc, 'roadSeparator', '$$$'),
    episodeSeparator: cc === null ? '' : J.str(cc, 'episodeSeparator', '#'),
    fieldSeparator: cc === null ? '' : J.str(cc, 'fieldSeparator', '$'),
    roadsPath: cc === null ? '' : J.str(cc, 'roadsPath', '$.data.roads[*]'),
    // nested 里线路名可能是 roadNamePath（单数），delimited 用的是 roadNamesPath
    roadNamePath: cc === null ? '' : J.str(cc, 'roadNamePath', '$.name'),
    episodesPath: cc === null ? '' : J.str(cc, 'episodesPath', '$.episodes[*]'),
    episodeNamePath: cc === null ? '' : J.str(cc, 'episodeNamePath', '$.name'),
    episodeUrlPath: cc === null ? '' : J.str(cc, 'episodeUrlPath', '$.url'),
    episodePageUrl: '',
    episodePageQuery: {}
  };
  // episodePage 是 {url, query} 对象；带 query 的站点要把 @episodeUrl 拼成参数
  const ep: Record<string, Object> | null = cc === null ? null : J.obj(cc['episodePage']);
  if (ep !== null) {
    r.episodePageUrl = J.str(ep, 'url', '');
    r.episodePageQuery = J.obj(ep['query']) ?? {};
  }
  return r;
}

export interface RuleSiteResult {
  site: SiteCfg | null;
  msg: string;
}

/**
 * 把一段 Kazumi 规则 JSON 转成可收进 Default 的站点（type=9）。
 * 只接受 API 模式规则——XPath 规则要 WebView 跑混淆 JS，原生 ArkTS 用不了。
 * 返回的 site 直接喂 MySitesStore.toggle() 持久化即可；msg 给界面提示。
 */
export function ruleToSite(text: string): RuleSiteResult {
  const raw: string = (text ?? '').trim();
  if (raw.length === 0) {
    return { site: null, msg: '先粘贴规则 JSON' };
  }
  const r: KazumiRule | null = parseKazumiRule(raw);
  if (r === null) {
    return { site: null, msg: '不是合法的规则 JSON' };
  }
  const api: boolean = KazumiRuleApi.isApiRule(r);
  const web: boolean = KazumiRuleApi.isXPathRule(r);
  if (!api && !web) {
    return { site: null, msg: '这条规则既没有 API 接口也没有剧集 XPath，用不了' };
  }
  if (api) {
    // 格式只有 delimited / nested 两种：delimited 直接给 m3u8 串，
    // nested 给的是一堆播放页，播的时候要靠无头 WebView 嗅探出流地址
    if (!KazumiRuleApi.isNested(r) && r.chapterFormat !== 'delimited') {
      return { site: null, msg: '这条规则的剧集格式（' + r.chapterFormat + '）还不支持' };
    }
    if (r.searchListPath.length === 0 || r.searchSourcePath.length === 0) {
      return { site: null, msg: '规则缺少搜索字段路径（listPath / sourcePath）' };
    }
  }
  if (web) {
    const canSearch: boolean = r.searchURL.length > 0 && r.searchList.length > 0 && r.searchResult.length > 0;
    if (!canSearch) {
      return { site: null, msg: '规则缺少搜索 XPath（searchURL / searchList / searchResult）' };
    }
  }
  // key 用 baseURL 的 host，稳定且唯一；拿不到就退回规则名
  let host: string = '';
  try {
    const u: string = (r.baseURL ?? '').trim();
    if (u.length > 0) {
      const i: number = u.indexOf('://');
      const rest: string = i >= 0 ? u.substring(i + 3) : u;
      const slash: number = rest.indexOf('/');
      host = (slash >= 0 ? rest.substring(0, slash) : rest).toLowerCase();
    }
  } catch (e) {
    host = '';
  }
  if (host.length === 0) {
    host = (r.name ?? '').trim().replace(/\s+/g, '').toLowerCase();
  }
  if (host.length === 0) {
    return { site: null, msg: '规则没有 baseURL，无法生成唯一标识' };
  }
  const site: SiteCfg = new SiteCfg();
  site.key = 'kz_' + host;
  site.name = (r.name ?? '').trim().length > 0 ? (r.name ?? '').trim() : host;
  site.type = 9;
  site.api = 'kazumi://' + host;
  site.ext = raw;
  site.searchable = true;
  site.quickSearch = true;
  site.filterable = false;
  return { site: site, msg: '已识别规则：' + site.name };
}

// ---------------- 从链接 / 规则名取规则 ----------------

/**
 * Kazumi 官方规则库。规则就是仓库根目录下的一个个 <规则名>.json，
 * 所以「规则名」本身就能还原成地址，电视上只要敲 giriGiriLove 这么短一个词。
 * GitHub raw 在国内时快时慢，失败后退 jsdelivr 的同一份文件。
 */
const RULE_REPOS: string[] = [
  'https://raw.githubusercontent.com/Predidit/KazumiRules/main/',
  'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/'
];

/** github 网页上的 blob 链接 → raw 直链 */
function blobToRaw(u: string): string {
  const i: number = u.indexOf('github.com/');
  const j: number = u.indexOf('/blob/');
  if (i < 0 || j < 0 || j < i) {
    return '';
  }
  return 'https://raw.githubusercontent.com/' + u.substring(i + 11, j) + u.substring(j + 6);
}

/** raw.githubusercontent 地址 → jsdelivr 同文件地址 */
function rawToMirror(u: string): string {
  const host: string = 'raw.githubusercontent.com/';
  const i: number = u.indexOf(host);
  if (i < 0) {
    return '';
  }
  const segs: string[] = u.substring(i + host.length).split('/');
  // owner / repo / branch / ...path
  if (segs.length < 4) {
    return '';
  }
  const path: string = segs.slice(3).join('/');
  return 'https://cdn.jsdelivr.net/gh/' + segs[0] + '/' + segs[1] + '@' + segs[2] + '/' + path;
}

async function fetchText(url: string): Promise<string> {
  const req: ApiRequest = { url: url, method: 'GET' };
  const empty: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
  const body: string = await requestText(req, empty);
  return body.trim();
}

/**
 * 统一入口：用户输入「规则名」/「规则链接」/「整段规则 JSON」都能吃。
 * 规则名按官方两个镜像依次试；链接失败时再试 github 网页链接与 jsdelivr 镜像。
 */
export async function loadRuleSite(input: string): Promise<RuleSiteResult> {
  const raw: string = (input ?? '').trim();
  if (raw.length === 0) {
    return { site: null, msg: '先填规则名或规则链接' };
  }
  if (raw.startsWith('{')) {
    return ruleToSite(raw);
  }

  const urls: string[] = [];
  if (/^https?:\/\//i.test(raw)) {
    urls.push(raw);
    const r1: string = blobToRaw(raw);
    if (r1.length > 0) {
      urls.push(r1);
    }
    const r2: string = rawToMirror(raw);
    if (r2.length > 0) {
      urls.push(r2);
    }
    const r3: string = r1.length > 0 ? rawToMirror(r1) : '';
    if (r3.length > 0) {
      urls.push(r3);
    }
  } else {
    // 规则名：允许带 .json 后缀，其余字符一律当输错
    const nm: string = raw.replace(/\.json$/i, '').trim();
    if (!/^[A-Za-z0-9_.\-]+$/.test(nm)) {
      return { site: null, msg: '填规则名（如 giriGiriLove）或规则链接' };
    }
    for (const b of RULE_REPOS) {
      urls.push(b + nm + '.json');
    }
  }

  let lastErr: string = '';
  for (const u of urls) {
    try {
      const txt: string = await fetchText(u);
      if (!txt.startsWith('{')) {
        lastErr = '这条地址返回的不是规则 JSON';
        continue;
      }
      return ruleToSite(txt);
    } catch (e) {
      lastErr = (e as Error).message;
    }
  }
  if (lastErr.indexOf('404') >= 0) {
    lastErr = '没有这条规则（规则名拼错了？）';
  }
  return { site: null, msg: '没取到规则：' + (lastErr.length > 0 ? lastErr : '网络不通') };
}

// ---------------- JSONPath 子集 ----------------
// 支持 $、$.a.b、$.a[*]、$[*]、$.a[0]。Kazumi 规则只用这几种。

function step(cur: Object[], seg: string): Object[] {
  let key: string = seg;
  let idx: number = -1;
  let all: boolean = false;
  const b: number = seg.indexOf('[');
  if (b >= 0) {
    key = seg.substring(0, b);
    const e: number = seg.indexOf(']', b);
    const inside: string = e > b ? seg.substring(b + 1, e) : '*';
    if (inside === '*') {
      all = true;
    } else {
      idx = Number(inside);
    }
  }
  const out: Object[] = [];
  for (const c of cur) {
    let v: Object | null = null;
    if (key.length > 0) {
      const o: Record<string, Object> | null = J.obj(c);
      v = o === null ? null : o[key] ?? null;
    } else if (all) {
      for (const a of J.arrOf(c)) {
        out.push(a);
      }
      continue;
    } else if (idx >= 0 && Array.isArray(c)) {
      const arr: Object[] = c as Object[];
      v = idx < arr.length ? arr[idx] : null;
    } else {
      v = c;
    }
    if (v === null || v === undefined) {
      continue;
    }
    if (all) {
      for (const a of J.arrOf(v)) {
        out.push(a);
      }
    } else if (idx >= 0) {
      const arr: Object[] = J.arrOf(v);
      if (idx < arr.length) {
        out.push(arr[idx]);
      }
    } else {
      out.push(v);
    }
  }
  return out;
}

export function pick(root: Object, path: string): Object[] {
  if (path.length === 0 || path === '$') {
    return [root];
  }
  let p: string = path;
  if (p.startsWith('$.')) {
    p = p.substring(2);
  } else if (p.startsWith('$')) {
    p = p.substring(1);
  }
  const segs: string[] = p.split('.');
  let cur: Object[] = [root];
  for (const s of segs) {
    cur = step(cur, s);
    if (cur.length === 0) {
      break;
    }
  }
  return cur;
}

function pickFirst(root: Object, path: string): Object | null {
  if (path.length === 0) {
    return null;
  }
  const a: Object[] = pick(root, path);
  return a.length > 0 ? a[0] : null;
}

function pickStr(root: Object, path: string, def: string): string {
  const v: Object | null = pickFirst(root, path);
  if (v === null) {
    return def;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number') {
    return String(v as number);
  }
  return def;
}

// ---------------- 变量与请求 ----------------
// ArkTS 严格模式：动态 key 容器只能用 Record<string, Object>（项目 J 工具类同款），
// 字面量通过 JSON.parse 构造，取值统一走 J.str()。

function newBag(): Record<string, Object> {
  return JSON.parse('{}') as Record<string, Object>;
}

function fill(s: string, vars: Record<string, Object>): string {
  let out: string = s;
  for (const k of Object.keys(vars)) {
    out = out.split('@' + k).join(J.str(vars, k, ''));
  }
  return out;
}

function fillObj(o: Record<string, Object>, vars: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = newBag();
  for (const k of Object.keys(o)) {
    const v: Object | undefined = o[k];
    if (typeof v === 'string') {
      out[k] = fill(v as string, vars);
    } else if (v !== null && v !== undefined) {
      out[k] = String(v);
    }
  }
  return out;
}

function buildUrl(req: ApiRequest, vars: Record<string, Object>): string {
  let url: string = fill(req.url, vars);
  const q: Record<string, Object> = fillObj(req.query ?? newBag(), vars);
  const keys: string[] = Object.keys(q);
  if (keys.length > 0) {
    const parts: string[] = [];
    for (const k of keys) {
      parts.push(k + '=' + encodeURIComponent(J.str(q, k, '')));
    }
    url += (url.includes('?') ? '&' : '?') + parts.join('&');
  }
  return url;
}

function requestText(req: ApiRequest, vars: Record<string, Object>): Promise<string> {
  const url: string = buildUrl(req, vars);
  const isPost: boolean = (req.method ?? 'GET').toUpperCase() === 'POST';
  const header: Record<string, Object> = JSON.parse(
    '{"User-Agent":"' + UA + '","Accept":"application/json, text/plain, */*",' +
    '"Accept-Language":"zh-CN,zh;q=0.9"}') as Record<string, Object>;
  const hs: Record<string, Object> = fillObj(req.headers ?? newBag(), vars);
  for (const k of Object.keys(hs)) {
    header[k] = J.str(hs, k, '');
  }
  let extra: string = '';
  if (isPost) {
    const body: Record<string, Object> = fillObj(req.body ?? newBag(), vars);
    if ((req.bodyType ?? 'json').toLowerCase() === 'form') {
      header['Content-Type'] = 'application/x-www-form-urlencoded';
      const parts: string[] = [];
      for (const k of Object.keys(body)) {
        parts.push(k + '=' + encodeURIComponent(J.str(body, k, '')));
      }
      extra = parts.join('&');
    } else {
      header['Content-Type'] = 'application/json';
      extra = JSON.stringify(body);
    }
  }
  const hBag: Record<string, Object> = newBag();
  for (const k of Object.keys(header)) {
    hBag[k] = J.str(header, k, '');
  }
  const h: Record<string, string> = JSON.parse(JSON.stringify(hBag)) as Record<string, string>;
  return new Promise<string>((resolve, reject) => {
    const r = http.createHttp();
    const opt: http.HttpRequestOptions = {
      method: isPost ? http.RequestMethod.POST : http.RequestMethod.GET,
      header: h,
      connectTimeout: 15000,
      readTimeout: 15000,
      expectDataType: http.HttpDataType.STRING
    };
    if (isPost) {
      opt.extraData = extra;
    }
    r.request(url, opt).then((resp: http.HttpResponse) => {
      r.destroy();
      if (resp.responseCode === 200) {
        const body: string = typeof resp.result === 'string' ? resp.result as string : '';
        resolve(body.startsWith('\uFEFF') ? body.substring(1) : body);
      } else {
        reject(new Error('HTTP ' + resp.responseCode));
      }
    }).catch((err: BusinessError) => {
      r.destroy();
      reject(new Error(err.message));
    });
  });
}

// ---------------- 对外能力 ----------------

export class KazumiRuleApi {
  /**
   * 详情页元信息缓存（详情页地址 → 片名/海报/简介）。
   * 网页（XPath）规则的详情接口只给选集链接，片名海报简介都没有；
   * 列表接口其实带全了（vod_content / vod_pic / vod_year），
   * 抓详情页时也能从 meta 标签里抠出来，放这里给详情页补上。
   */
  private static cmsMeta: Map<string, CmsMeta> = new Map<string, CmsMeta>();

  static isApiRule(r: KazumiRule | null): boolean {
    return r !== null && r.searchApi !== null && r.chapterApi !== null;
  }

  /** 网页（XPath）模式：没有剧集 API，剧集要从详情页的 XPath 里抠 */
  static isXPathRule(r: KazumiRule | null): boolean {
    return r !== null && r.chapterApi === null && r.chapterRoads.length > 0 && r.chapterResult.length > 0;
  }

  /** nested：剧集给的是播放页 id/地址，真要播还得让页面自己跑出 m3u8 */
  static isNested(r: KazumiRule | null): boolean {
    if (r === null || r.chapterApi === null) {
      return false;
    }
    // Kazumi 只有 nested / delimited 两种；不是 delimited 一律按 nested 处理
    return r.chapterFormat !== 'delimited';
  }

  static async search(r: KazumiRule, wd: string, page: number): Promise<KazumiListResult> {
    if (r.searchApi === null) {
      // 网页模式：在搜索页里跑规则给的 XPath
      if (r.searchURL.length > 0 && r.searchList.length > 0 && r.searchResult.length > 0) {
        return await KazumiRuleApi.searchXPath(r, wd);
      }
      const empty: KazumiListResult = { items: new Array<VodItem>(), total: 0 };
      return empty;
    }
    const limit: number = Number((r.searchApi.query ?? {})['limit'] ?? 24) || 24;
    const vars: Record<string, Object> = JSON.parse(
      '{"keyword":"","page":"","offset":""}') as Record<string, Object>;
    vars['keyword'] = wd;
    vars['page'] = String(page);
    vars['offset'] = String((page - 1) * limit);
    const text: string = await requestText(r.searchApi, vars);
    const root: Object = JSON.parse(text) as Object;
    const rows: Object[] = pick(root, r.searchListPath);
    const items: VodItem[] = [];
    for (const row of rows) {
      const name: string = pickStr(row, r.searchNamePath, '');
      if (name.length === 0) {
        continue;
      }
      let source: string = pickStr(row, r.searchSourcePath, '');
      // 剧集是网页模式的规则（TvTFun / dalvdm / moonci 这类）只给 id，
      // 要用 sourceTemplate 拼成详情页地址，详情页里才有选集
      if (source.length > 0 && r.searchSourceTemplate.length > 0) {
        const sv: Record<string, Object> = JSON.parse('{"source":""}') as Record<string, Object>;
        sv['source'] = source;
        source = fill(r.searchSourceTemplate, sv);
      }
      const pic: string = r.searchPicPath.length > 0
        ? pickStr(row, r.searchPicPath, '') : J.str(J.obj(row), 'vod_pic', '');
      // 年份一定要带上：豆瓣同名条目极多（"来自远方"就有 2021 美国歌舞 / 2026 日本动画
      // / 2015 委内瑞拉 三部），没有年份时匹配只能取搜出来排第一的那条，
      // 结果番剧被配上欧美片的封面、剧照和 9.2 分。vod_area 一并带上供后续校验。
      const obj: Record<string, Object> | null = J.obj(row);
      const item: VodItem = {
        vod_id: source,
        vod_name: name,
        vod_pic: pic,
        site_key: r.name,
        type_name: categoryName(r.category),
        vod_year: J.str(obj, 'vod_year', ''),
        vod_area: J.str(obj, 'vod_area', ''),
        vod_douban_id: J.str(obj, 'vod_douban_id', ''),
        vod_remarks: J.str(obj, 'vod_remarks', ''),
        vod_content: J.str(obj, 'vod_content', '')
      };
      items.push(item);
    }
    let total: number = items.length;
    for (const p of ['$.info.total', '$.total', '$.data.total']) {
      const s: string = pickStr(root, p, '');
      if (s.length > 0) {
        const n: number = Number(s);
        if (!Number.isNaN(n)) {
          total = n;
          break;
        }
      }
    }
    return { items: items, total: total };
  }

  static async getDetail(r: KazumiRule, source: string): Promise<VodDetail | null> {
    if (r.chapterApi === null) {
      // 网页模式：source 已经是详情页地址（网页搜索给的链接，或 API 搜索按模板拼出来的）
      if (!/^https?:\/\//i.test(source)) {
        return null;
      }
      return await KazumiRuleApi.detailXPath(r, source);
    }
    const vars: Record<string, Object> = JSON.parse(
      '{"source":"","keyword":"","episodeUrl":""}') as Record<string, Object>;
    vars['source'] = source;
    const text: string = await requestText(r.chapterApi, vars);
    const root: Object = JSON.parse(text) as Object;

    const info: Record<string, Object> | null = J.obj(pickFirst(root, '$.info'));
    const d: VodDetail = {
      vod_id: source,
      vod_name: info === null ? '' : J.str(info, 'vod_name', ''),
      vod_pic: info === null ? '' : J.str(info, 'vod_pic', ''),
      type_name: categoryName(r.category),
      // 同上：没有年份，详情页的海报/剧照/评分就会按片名盲配到同名条目
      vod_year: info === null ? '' : J.str(info, 'vod_year', ''),
      vod_douban_id: info === null ? '' : J.str(info, 'vod_douban_id', ''),
      vod_content: info === null ? '' : J.str(info, 'vod_content', ''),
      vod_remarks: info === null ? '' : J.str(info, 'vod_remarks', ''),
      vod_play_from: '',
      vod_play_url: ''
    };

    if (KazumiRuleApi.isNested(r)) {
      const built: NestedLines = KazumiRuleApi.nestedLines(r, root, source);
      if (built.froms.length === 0) {
        return null;
      }
      d.vod_play_from = built.froms.join('$$$');
      d.vod_play_url = built.urls.join('$$$');
      return d;
    }

    const froms: string = pickStr(root, r.roadNamesPath, '');
    const urls: string = pickStr(root, r.roadEpisodesPath, '');
    if (froms.length === 0 || urls.length === 0) {
      return null;
    }
    d.vod_play_from = froms;
    d.vod_play_url = urls;
    return d;
  }

  /**
   * nested 格式：线路里是一集一集的播放页，每个播放页要靠无头 WebView
   * 真跑一遍 JS 才能拿到 m3u8（播放时由 WebSniffer 兜）。
   * 这里只负责把「集名 $ 播放页地址」拼成苹果CMS 同构的串。
   */
  private static nestedLines(r: KazumiRule, root: Object, source: string): NestedLines {
    const roads: Object[] = pick(root, r.roadsPath);
    const froms: string[] = [];
    const urls: string[] = [];
    let roadNo: number = 0;
    for (const road of roads) {
      roadNo++;
      let rn: string = r.roadNamePath.length > 0 ? pickStr(road, r.roadNamePath, '') : '';
      if (rn.length === 0) {
        rn = '线路' + roadNo;
      }
      const eps: Object[] = pick(road, r.episodesPath);
      const parts: string[] = [];
      let epNo: number = 0;
      for (const ep of eps) {
        const id: string = pickStr(ep, r.episodeUrlPath, '');
        if (id.length === 0) {
          continue;
        }
        epNo++;
        const vars: Record<string, Object> = JSON.parse(
          '{"source":"","episodeUrl":""}') as Record<string, Object>;
        vars['source'] = source;
        vars['episodeUrl'] = id;
        let u: string = r.episodePageUrl.length > 0 ? fill(r.episodePageUrl, vars) : id;
        const q: Record<string, Object> = fillObj(r.episodePageQuery, vars);
        const keys: string[] = Object.keys(q);
        if (keys.length > 0) {
          const kv: string[] = [];
          for (const k of keys) {
            kv.push(k + '=' + encodeURIComponent(J.str(q, k, '')));
          }
          u += (u.includes('?') ? '&' : '?') + kv.join('&');
        }
        let nm: string = r.episodeNamePath.length > 0 ? pickStr(ep, r.episodeNamePath, '') : '';
        if (nm.length === 0) {
          nm = '第' + epNo + '集';
        }
        parts.push(nm + '$' + u);
      }
      if (parts.length > 0) {
        froms.push(rn);
        urls.push(parts.join('#'));
      }
    }
    return { froms: froms, urls: urls };
  }

  // ---------------- 全库浏览（macCMS 数据接口） ----------------

  /**
   * 网页规则站的「全部内容」入口。
   *
   * 这类规则的 searchURL 是搜索页，拿空关键词去搜，多数站只回一两条推荐，
   * 点播页因此是空的。但它们基本都是 macCMS，模板自带 index.php/ajax/data
   * 这个数据接口：只认 page / limit，回的是全库按更新时间倒序，每项还带
   * detail_link —— 正好就是详情页要走的那条地址。
   *
   * 返回 null 表示这个站没有该接口（不是 macCMS，或者被关了），由调用方兜底。
   */
  static async browseCms(r: KazumiRule, page: number): Promise<KazumiListResult | null> {
    const base: string = (r.baseURL ?? '').trim();
    if (base.length === 0 || !base.startsWith('http')) {
      return null;
    }
    const root: string = base.endsWith('/') ? base : base + '/';
    const limit: number = 30;
    const url: string = root + 'index.php/ajax/data?mid=1&limit=' + limit + '&page=' + page;
    let data: CmsDataResp;
    try {
      data = await HttpUtil.getJsonWith<CmsDataResp>(url, root, CMS_UA);
    } catch (e) {
      // 关了接口的站会回首页 HTML / "closed"，不是 JSON 就在这儿退出
      return null;
    }
    const rows: CmsDataItem[] = data.list ?? [];
    if (rows.length === 0) {
      return null;
    }
    const items: VodItem[] = [];
    for (const x of rows) {
      const name: string = (x.vod_name ?? '').trim();
      const link: string = (x.detail_link ?? '').trim();
      if (name.length === 0 || link.length === 0) {
        continue;
      }
      const href: string = link.startsWith('http') ? link
        : (link.startsWith('/') ? root + link.substring(1) : root + link);
      // 封面可能是相对路径，也可能是 "/" 这种占位，占位的直接留空
      let pic: string = (x.vod_pic ?? '').trim();
      if (pic === '/' || pic === '') {
        pic = '';
      } else if (pic.startsWith('//')) {
        pic = 'https:' + pic;
      } else if (pic.startsWith('/')) {
        pic = root + pic.substring(1);
      }
      const tn: string = x.type === undefined || x.type === null ? '' : (x.type.type_name ?? '');
      const content: string = KazumiRuleApi.cleanText(
        (x.vod_content ?? '').trim().length > 0 ? (x.vod_content ?? '') : (x.vod_blurb ?? ''));
      const item: VodItem = {
        vod_id: href,
        vod_name: name,
        vod_pic: pic,
        site_key: r.name,
        // 站点自己的分类名（TV番剧 / 剧场电影…）比规则里那个统一值更准
        type_name: tn.length > 0 ? tn : categoryName(r.category),
        vod_remarks: (x.vod_remarks ?? '').trim(),
        vod_year: (x.vod_year ?? '').trim(),
        vod_area: (x.vod_area ?? '').trim(),
        vod_content: content
      };
      // 列表里就带了片名/海报/简介，详情页直接取用，不用再抓一次页面
      const meta: CmsMeta = {
        name: name,
        pic: pic,
        content: content,
        year: (x.vod_year ?? '').trim(),
        area: (x.vod_area ?? '').trim(),
        remarks: (x.vod_remarks ?? '').trim(),
        typeName: tn
      };
      KazumiRuleApi.cmsMeta.set(href, meta);
      if (KazumiRuleApi.cmsMeta.size > 400) {
        // 只留最近翻过的几页，别让翻几百页把内存撑起来
        const keys: string[] = [];
        KazumiRuleApi.cmsMeta.forEach((v: CmsMeta, k: string) => {
          keys.push(k);
        });
        for (let i = 0; i < keys.length - 200; i++) {
          KazumiRuleApi.cmsMeta.delete(keys[i]);
        }
      }
      items.push(item);
    }
    if (items.length === 0) {
      return null;
    }
    const total: number = data.total ?? items.length;
    const out: KazumiListResult = { items: items, total: total };
    out.pageCount = data.pagecount ?? 1;
    return out;
  }

  // ---------------- 网页（XPath）模式 ----------------

  /**
   * 搜索页：把 @keyword 填进 searchURL，在隐藏 WebView 里打开，
   * 再按 searchList / searchName / searchResult 三段 XPath 取「名字 + 详情页链接」。
   * 详情页链接直接当 vod_id 存着，取详情时再打开它。
   */
  private static async searchXPath(r: KazumiRule, wd: string): Promise<KazumiListResult> {
    const url: string = r.searchURL.split('@keyword').join(encodeURIComponent(wd));
    const rows = await sniffer.xpathRows(url, r.searchList, r.searchName, r.searchResult, 14000);
    const items: VodItem[] = [];
    for (const row of rows) {
      const item: VodItem = {
        vod_id: row.href,
        vod_name: row.name,
        vod_pic: '',
        site_key: r.name,
        type_name: categoryName(r.category)
      };
      items.push(item);
    }
    const out: KazumiListResult = { items: items, total: items.length };
    return out;
  }

  /**
   * 分类浏览：打开站点的列表页（MacCMS 的 vodshow），按预设 XPath 取
   * 「片名 + 详情链接 + 海报」。规则本身没有分类概念，分类是 App 侧补的，
   * 见 utils/RuleCategories.ets。
   *
   * 列表页链接直接当 vod_id 存，和搜索走的同一条详情链路。
   */
  static async browseCategory(r: KazumiRule, cat: RuleCategory, page: number): Promise<KazumiListResult> {
    // MacCMS 第一页没有页码段（`1-----------.html`），模板统一写成 path + '@page---'，
    // 所以第 1 页要把 @page 换成空串才得到真实地址，换成 '1' 成了 `1--------1---`。
    const url: string = cat.url.split('@page').join(page <= 1 ? '' : String(page));
    const rows = await sniffer.xpathRows(url, cat.list, cat.nameX, cat.href, 16000, cat.pic);
    const items: VodItem[] = [];
    for (const row of rows) {
      const item: VodItem = {
        vod_id: row.href,
        vod_name: row.name,
        vod_pic: row.pic === undefined ? '' : row.pic,
        site_key: r.name,
        type_name: categoryName(r.category)
      };
      items.push(item);
    }
    const out: KazumiListResult = { items: items, total: items.length };
    return out;
  }

  /** 详情页：chapterRoads 圈出线路容器，chapterResult 取里面的选集链接 */
  private static async detailXPath(r: KazumiRule, pageUrl: string): Promise<VodDetail | null> {
    // 选集要从页面 DOM 里抠，元信息（片名/海报/简介）优先用列表接口带回来的，
    // 没有就抓一次页面从 meta 标签里取 —— 之前这两样全丢，详情页只剩一列集数
    const meta: CmsMeta = await KazumiRuleApi.metaOf(r, pageUrl);
    const roads = await sniffer.xpathRoads(pageUrl, r.chapterRoads, r.chapterResult, 16000);
    if (roads.length === 0) {
      return null;
    }
    const froms: string[] = [];
    const urls: string[] = [];
    for (const road of roads) {
      const parts: string[] = [];
      for (const it of road.items) {
        const nm: string = it.name.length > 0 ? it.name : '正片';
        parts.push(nm + '$' + it.href);
      }
      if (parts.length > 0) {
        froms.push(road.name);
        urls.push(parts.join('#'));
      }
    }
    if (froms.length === 0) {
      return null;
    }
    const d: VodDetail = {
      vod_id: pageUrl,
      vod_name: meta.name,
      vod_pic: meta.pic,
      type_name: meta.typeName.length > 0 ? meta.typeName : categoryName(r.category),
      vod_year: meta.year,
      vod_douban_id: '',
      vod_content: meta.content,
      vod_remarks: meta.remarks,
      vod_play_from: froms.join('$$$'),
      vod_play_url: urls.join('$$$')
    };
    return d;
  }

  /**
   * 详情页元信息：先用列表接口缓存的（准确、零请求），没有就抓一次页面。
   * 抓页面统一用桌面 UA —— 番剧站按 UA 分流，手机 UA 拿到的是另一套模板。
   */
  private static async metaOf(r: KazumiRule, pageUrl: string): Promise<CmsMeta> {
    const hit: CmsMeta | undefined = KazumiRuleApi.cmsMeta.get(pageUrl);
    const base: string = (r.baseURL ?? '').trim();
    let meta: CmsMeta = hit === undefined
      ? { name: '', pic: '', content: '', year: '', area: '', remarks: '', typeName: '' }
      : hit;
    if (meta.content.length > 0 && meta.pic.length > 0) {
      return meta;
    }
    let html: string = '';
    try {
      html = await HttpUtil.getTextWith(pageUrl, base.length > 0 ? base : pageUrl, CMS_UA);
    } catch (e) {
      return meta;
    }
    if (html.length === 0) {
      return meta;
    }
    const page: CmsMeta = KazumiRuleApi.parsePageMeta(html);
    // 逐字段补：缓存里有的不覆盖（缓存来自接口，比正则抓的干净）
    meta = {
      name: meta.name.length > 0 ? meta.name : page.name,
      pic: meta.pic.length > 0 ? meta.pic : page.pic,
      content: meta.content.length > 0 ? meta.content : page.content,
      year: meta.year.length > 0 ? meta.year : page.year,
      area: meta.area.length > 0 ? meta.area : page.area,
      remarks: meta.remarks.length > 0 ? meta.remarks : page.remarks,
      typeName: meta.typeName.length > 0 ? meta.typeName : page.typeName
    };
    KazumiRuleApi.cmsMeta.set(pageUrl, meta);
    return meta;
  }

  /**
   * 从详情页 HTML 里抠元信息。苹果CMS 各套模板结构不同，按「通用 → 具体」的顺序试：
   * 片名：og:title → <title> 去掉《》和 "- 站点名" 尾巴
   * 简介：og:description → meta description（很多模板写成「片名剧情:…」）
   * 海报：og:image → 第一个指向图床 / upload 的 img
   */
  private static parsePageMeta(html: string): CmsMeta {
    const meta: CmsMeta = { name: '', pic: '', content: '', year: '', area: '', remarks: '', typeName: '' };
    meta.name = KazumiRuleApi.cleanName(
      KazumiRuleApi.metaContent(html, 'og:title'), KazumiRuleApi.tagText(html, 'title'));
    meta.content = KazumiRuleApi.cleanText(
      KazumiRuleApi.metaContent(html, 'og:description').length > 0
        ? KazumiRuleApi.metaContent(html, 'og:description')
        : KazumiRuleApi.metaContent(html, 'description'));
    // 简介里常带「片名剧情:」这类前缀，去掉
    const colon: number = meta.content.indexOf('剧情:');
    if (colon > 0 && colon < 40) {
      meta.content = meta.content.substring(colon + 3).trim();
    }
    meta.pic = KazumiRuleApi.metaContent(html, 'og:image');
    if (meta.pic.length === 0) {
      meta.pic = KazumiRuleApi.firstPic(html);
    }
    const y: RegExpMatchArray | null = html.match(/(?:上映时间|年份|首播)[：:]\s*((?:19|20)\d{2})/);
    if (y !== null && y[1] !== undefined) {
      meta.year = y[1];
    }
    const t: RegExpMatchArray | null = html.match(/类型[：:]\s*([^<]{2,60})/);
    if (t !== null) {
      const tn: string = t[1].trim();
      // 详情页的「类型」常是一串题材（校园,青春,音乐…），当分类标签太长，只收短的
      if (tn.length <= 8 && tn.indexOf(',') < 0 && tn.indexOf('，') < 0) {
        meta.typeName = tn;
      }
    }
    return meta;
  }

  /** <meta property/name="key" content="...">，属性顺序不固定，两头都试 */
  private static metaContent(html: string, key: string): string {
    const patterns: string[] = [
      '<meta[^>]+(?:property|name)=["\']' + key + '["\'][^>]*?content=["\']([^"\']*)["\']',
      '<meta[^>]+content=["\']([^"\']*)["\'][^>]*?(?:property|name)=["\']' + key + '["\']'
    ];
    for (const p of patterns) {
      const m: RegExpMatchArray | null = html.match(new RegExp(p, 'i'));
      if (m !== null && m[1] !== undefined) {
        return KazumiRuleApi.decode(m[1]).trim();
      }
    }
    return '';
  }

  private static tagText(html: string, tag: string): string {
    const m: RegExpMatchArray | null = html.match(new RegExp('<' + tag + '[^>]*>([\\s\\S]*?)</' + tag + '>', 'i'));
    return m === null || m[1] === undefined ? '' : KazumiRuleApi.decode(m[1]).trim();
  }

  /**
   * 详情页里最像海报的那张图。
   * 各套模板写法差别很大：有的 og:image，有的 class="author-img"，有的走懒加载
   * （data-original / data-src，src 只是个占位图）。按「标签里有 poster/cover 字样」
   * 优先，其次指向图床 / upload 目录的，都拿不到就留空。
   */
  private static firstPic(html: string): string {
    const re: RegExp = /<img\b[^>]*>/gi;
    let fallback: string = '';
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const tag: string = m[0];
      const sm: RegExpMatchArray | null = tag.match(/(?:data-original|data-src|src)\s*=\s*["']([^"']+)["']/i);
      if (sm !== null && sm[1] !== undefined) {
        const src: string = KazumiRuleApi.decode(sm[1]).trim();
        if (/^https?:\/\//i.test(src)) {
          if (/author-img|poster|cover|thumb|vod-pic/i.test(tag)) {
            return src;
          }
          if (fallback.length === 0 && /doubanio|upload|\/pic|qpic/i.test(src)) {
            fallback = src;
          }
        }
      }
      m = re.exec(html);
    }
    return fallback;
  }

  /** 片名清理：og:title 一般干净，<title> 常带《》和站点名 */
  private static cleanName(og: string, title: string): string {
    if (og.length > 0) {
      return og;
    }
    let s: string = title;
    const cut: number = s.search(/\s[-_|]\s/);
    if (cut > 0) {
      s = s.substring(0, cut);
    }
    s = s.split('《').join('').split('》').join('');
    s = s.replace(/(简介|详情|在线观看|在线收看)+$/g, '');
    return s.trim();
  }

  /** 去 HTML 标签与多余空白 */
  private static cleanText(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    return KazumiRuleApi.decode(raw)
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  private static decode(s: string): string {
    return s.replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, '\'')
      .replace(/&amp;/g, '&');
  }

  /** 详情 → 播放线路，直接复用苹果CMS 解析器 */
  static lines(d: VodDetail) {
    return SiteApi.parseLines(d);
  }
}
