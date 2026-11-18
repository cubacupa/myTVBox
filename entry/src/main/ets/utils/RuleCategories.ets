/**
 * 规则站（Kazumi 规则）的分类浏览预设。
 *
 * Kazumi 的规则格式只有「搜索 + 选集」，压根没有分类字段——所以规则站的内容在
 * 客户端永远是一坨平的搜索结果。但这类站（尤其 MacCMS 系）自己在网页上有完整的
 * 分类和筛选：`/vodshow/{type}--------{page}---.html`，还带题材/地区/年份参数。
 *
 * 这里用「站点 → 分类列表」的映射把网页上现成的分类接回来：每个分类只要一个
 * 地址模板（@page 换成页码）加四个 XPath（列表项 / 片名 / 详情链接 / 海报）。
 * 规则本身不用改，也不会被第三方规则覆盖。
 *
 * 分页公式对所有 MacCMS 站通用：把 URL 末尾的 3 个短横去掉，插页码，再补 `---`。
 *   1-----------        → 1--------2---        （无筛选）
 *   1---冒险--------    → 1---冒险-----2---    （带题材）
 *   1-日本----------    → 1-日本-------2---    （带地区）
 *
 * ⚠️ 开源版不预置任何站点：下面 PRESETS 是空的，所以规则站的分类入口默认不出现，
 * 只剩搜索。想接分类，照 RuleCategory 的结构自己填一条映射即可。本工程只做协议
 * 解析与播放，不附带、不推荐任何内容源。
 */

export interface RuleCategory {
  /** 分类显示名（电视上就是 chip 上的字） */
  name: string;
  /** 列表页地址模板，@page 会被替换成页码 */
  url: string;
  /** XPath：一页里的条目容器 */
  list: string;
  /** XPath：条目里的片名（相对容器求值） */
  nameX: string;
  /** XPath：条目里的详情页链接 */
  href: string;
  /** XPath：条目里的海报 img */
  pic: string;
}

/** 站点指纹 → 分类列表。用域名子串匹配，换域名（.top/.com）也能命中。 */
interface Preset {
  /** 命中 baseURL 的子串（小写比较） */
  host: string;
  cats: RuleCategory[];
}

/**
 * 预设表。开源版留空 —— 想启用就按下面这段结构补一条：
 *
 *   const MY_LIST: string = '//div[contains(@class,"video") and contains(@class,"anim")]';
 *   const MY_NAME: string = '//div[@class="video-name"]';
 *   const MY_HREF: string = '//a[@class="video-wrapper"]';
 *   const MY_PIC: string = '//img[@class="videoimg"]';
 *
 *   {
 *     host: 'example.com',
 *     cats: [
 *       { name: '电影', url: 'https://example.com/vodshow/1--------@page---.html',
 *         list: MY_LIST, nameX: MY_NAME, href: MY_HREF, pic: MY_PIC }
 *     ]
 *   }
 *
 * 注意 url 末尾的 `@page---`：第 1 页是空页码，拼出来正好是完整的短横位数。
 */
const PRESETS: Preset[] = [];

function presetsFor(baseURL: string): RuleCategory[] {
  const low: string = baseURL.toLowerCase();
  for (const p of PRESETS) {
    if (low.indexOf(p.host) >= 0) {
      return p.cats;
    }
  }
  return [];
}

/**
 * 取某个规则站的分类，地址用规则的 baseURL（取不到退回 searchURL 的主机名）。
 * 参数只收字符串：ArkTS 不支持结构化类型，直接传规则对象会编译不过。
 */
export function categoriesFor(baseURL: string, searchURL: string): RuleCategory[] {
  const probe: string = baseURL.length > 0 ? baseURL : searchURL;
  return presetsFor(probe);
}
