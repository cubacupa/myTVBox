import { J } from './JsonUtil';
import { SiteCfg } from '../model/TvBoxModels';

/**
 * 分类筛选（地区 / 年份）。
 * 优先用配置里 site.ext.filter 的真实维度（TVBox 原生格式），取不到就用内置维度兜底。
 * 选中值直接作为查询参数拼到 ac=videolist 后面，苹果CMS 采集站普遍认 area / year。
 *
 * 注意：排序维度不在这里。采集站 API 根本没有 order 参数（实测 area/year 生效、
 * order=score/hits/up 返回值一字不差），所以排序挪到首页主界面，且「按评分」
 * 改成客户端用已刮到的豆瓣分来排，见 Index.withSort()。
 */
export interface FilterValue {
  n: string;   // 显示名
  v: string;   // 参数值
}

export interface FilterGroup {
  key: string;     // 参数名，如 area / year / order
  name: string;    // 显示名，如 地区
  values: FilterValue[];
}

export interface FilterSel {
  key: string;
  value: string;
  label: string;
}

export class FilterUtil {
  // 从 site.ext 里取当前分类的筛选定义
  static fromExt(site: SiteCfg, typeId: string): FilterGroup[] {
    const out: FilterGroup[] = [];
    if (!site.ext || !typeId) {
      return out;
    }
    let root: Record<string, Object> | null = null;
    try {
      root = J.obj(JSON.parse(site.ext) as Object);
    } catch (e) {
      return out;
    }
    if (root === null) {
      return out;
    }
    const filter = J.obj(root['filter']);
    if (filter === null) {
      return out;
    }
    for (const g of J.arr(filter, typeId)) {
      const go = J.obj(g);
      if (go === null) {
        continue;
      }
      const values: FilterValue[] = [];
      for (const v of J.arr(go, 'value')) {
        const vo = J.obj(v);
        if (vo === null) {
          continue;
        }
        const fv: FilterValue = { n: J.str(vo, 'n', ''), v: J.str(vo, 'v', '') };
        if (fv.n) {
          values.push(fv);
        }
      }
      const key = J.str(go, 'key', '');
      if (key && values.length > 0) {
        const fg: FilterGroup = { key: key, name: J.str(go, 'name', key), values: values };
        out.push(fg);
      }
    }
    return out;
  }

  /**
   * 丢掉配置里自带的排序维度。
   * TVBox 配置的 ext.filter 常常有一组 order（latest/hits/score），但采集站的
   * ac=videolist 接口不认这个参数，留着只会让用户以为点了能排。排序统一由首页主界面提供。
   */
  static withoutSort(groups: FilterGroup[]): FilterGroup[] {
    const out: FilterGroup[] = [];
    for (const g of groups) {
      const key: string = g.key.toLowerCase();
      if (key === 'order' || key === 'sort' || g.name.indexOf('排序') >= 0) {
        continue;
      }
      out.push(g);
    }
    return out;
  }

  // 内置维度：地区 / 年份
  static builtin(): FilterGroup[] {
    const areas: FilterValue[] = [
      { n: '全部', v: '' },
      { n: '大陆', v: '大陆' },
      { n: '中国香港', v: '香港' },
      { n: '中国台湾', v: '台湾' },
      { n: '美国', v: '美国' },
      { n: '韩国', v: '韩国' },
      { n: '日本', v: '日本' },
      { n: '泰国', v: '泰国' },
      { n: '其他', v: '其他' }
    ];
    const years: FilterValue[] = [{ n: '全部', v: '' }];
    const now = new Date().getFullYear();
    for (let y = now; y >= now - 10; y--) {
      years.push({ n: '' + y, v: '' + y });
    }
    years.push({ n: '更早', v: '2010' });

    const g1: FilterGroup = { key: 'area', name: '地区', values: areas };
    const g2: FilterGroup = { key: 'year', name: '年份', values: years };
    return [g1, g2];
  }

  // 默认选中项（每组第一个）
  static defaultSels(groups: FilterGroup[]): FilterSel[] {
    const out: FilterSel[] = [];
    for (const g of groups) {
      const fallback: FilterValue = { n: '全部', v: '' };
      const first: FilterValue = g.values.length > 0 ? g.values[0] : fallback;
      const s: FilterSel = { key: g.key, value: first.v, label: first.n };
      out.push(s);
    }
    return out;
  }

  // 把选中项拼成查询串：area=大陆&year=2026
  static toQuery(sels: FilterSel[]): string {
    const parts: string[] = [];
    for (const s of sels) {
      if (s.value) {
        parts.push(s.key + '=' + encodeURIComponent(s.value));
      }
    }
    return parts.join('&');
  }
}
