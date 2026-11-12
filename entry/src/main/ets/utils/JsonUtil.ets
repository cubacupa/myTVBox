/**
 * JSON 安全取值工具。
 * TVBox 配置里同一个字段常出现 数字/字符串/对象 混写（例如 type: 1 或 "1"、
 * searchable: 1 或 true、ext: "..." 或 {...}），这里统一收口，避免 ArkTS 严格模式报错。
 */
export class J {
  static obj(v: Object | null | undefined): Record<string, Object> | null {
    if (v === null || v === undefined) {
      return null;
    }
    if (typeof v !== 'object') {
      return null;
    }
    return v as Record<string, Object>;
  }

  static arrOf(v: Object | null | undefined): Object[] {
    if (v === null || v === undefined) {
      return [];
    }
    if (Array.isArray(v)) {
      return v as Object[];
    }
    return [];
  }

  static arr(o: Record<string, Object> | null, key: string): Object[] {
    if (o === null) {
      return [];
    }
    return J.arrOf(o[key]);
  }

  static str(o: Record<string, Object> | null, key: string, def: string): string {
    if (o === null) {
      return def;
    }
    const v = o[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return String(v as number);
    }
    if (typeof v === 'boolean') {
      return (v as boolean) ? '1' : '0';
    }
    return def;
  }

  static num(o: Record<string, Object> | null, key: string, def: number): number {
    if (o === null) {
      return def;
    }
    const v = o[key];
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n = Number(v as string);
      if (!Number.isNaN(n)) {
        return n;
      }
    }
    return def;
  }

  static bool(o: Record<string, Object> | null, key: string, def: boolean): boolean {
    if (o === null) {
      return def;
    }
    const v = o[key];
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'number') {
      return (v as number) !== 0;
    }
    if (typeof v === 'string') {
      const s = (v as string).toLowerCase();
      return s === '1' || s === 'true' || s === 'yes';
    }
    return def;
  }

  // 保留原始值（对象则转成字符串），用于 ext 这类结构不固定的字段
  static raw(o: Record<string, Object> | null, key: string): string {
    if (o === null) {
      return '';
    }
    const v = o[key];
    if (v === null || v === undefined) {
      return '';
    }
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'object') {
      try {
        return JSON.stringify(v);
      } catch (e) {
        return '';
      }
    }
    return String(v);
  }
}
