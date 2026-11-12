/**
 * TVBox 配置用的"宽松 JSON"解析。
 *
 * 真实配置几乎都不是严格 JSON，标准 JSON.parse 直接失败：
 *   1) // 行注释、/* *\/ 块注释（用于标注源地址、分组分隔）
 *   2) 对象/数组末尾的尾逗号        { "a": 1, }
 *   3) 字符串内未转义的控制字符      "name": "a<换行>b"
 *   4) 文件头的 BOM
 *
 * 处理时必须用状态机区分"字符串内 / 字符串外"，否则会把
 * "https://xxx" 里的 // 当注释删掉，反而把配置改坏。
 */
export class LenientJson {
  static parse<T>(text: string): T {
    const cleaned: string = LenientJson.clean(text);
    try {
      return JSON.parse(cleaned) as T;
    } catch (e) {
      // 少数配置里混着完全不属于 JSON 的裸文字行（例如 "   ## json   "），
      // 清洗注释后依旧报错，这里把不含任何 JSON 结构字符的行剔掉再试一次。
      try {
        return JSON.parse(LenientJson.stripJunkLines(cleaned)) as T;
      } catch (e2) {
        throw new Error((e as Error).message);
      }
    }
  }

  /**
   * 删掉"既不是注释也不是 JSON 结构"的裸文字行。
   * 判定很保守：整行不含 { } [ ] " : 任一字符才丢，避免误删真实字段。
   */
  static stripJunkLines(s: string): string {
    const lines: string[] = s.split('\n');
    const keep: string[] = [];
    for (const ln of lines) {
      let hasJson: boolean = false;
      for (let k = 0; k < ln.length; k++) {
        const c: string = ln.charAt(k);
        if (c === '{' || c === '}' || c === '[' || c === ']' || c === '"' || c === ':') {
          hasJson = true;
          break;
        }
      }
      if (hasJson) {
        keep.push(ln);
      }
    }
    return keep.join('\n');
  }

  static clean(text: string): string {
    let s: string = text ?? '';
    // 去 BOM
    if (s.length > 0 && s.charCodeAt(0) === 0xFEFF) {
      s = s.substring(1);
    }
    const n: number = s.length;
    const out: string[] = [];
    let i: number = 0;
    let inStr: boolean = false;

    while (i < n) {
      const c: string = s.charAt(i);

      if (inStr) {
        // 转义序列整体透传，避免把 \" 误判为字符串结束
        if (c === '\\') {
          out.push(c);
          if (i + 1 < n) {
            out.push(s.charAt(i + 1));
            i += 2;
            continue;
          }
          i++;
          continue;
        }
        // 裸控制字符（换行/制表符等）转成 \u00XX，否则 JSON.parse 报错
        const code: number = s.charCodeAt(i);
        if (code < 0x20) {
          out.push(LenientJson.hex4(code));
          i++;
          continue;
        }
        out.push(c);
        if (c === '"') {
          inStr = false;
        }
        i++;
        continue;
      }

      if (c === '"') {
        inStr = true;
        out.push(c);
        i++;
        continue;
      }

      // 字符串外的注释
      if (c === '/' && i + 1 < n) {
        const c2: string = s.charAt(i + 1);
        if (c2 === '/') {
          i += 2;
          while (i < n && s.charAt(i) !== '\n') {
            i++;
          }
          continue;
        }
        if (c2 === '*') {
          i += 2;
          while (i + 1 < n && !(s.charAt(i) === '*' && s.charAt(i + 1) === '/')) {
            i++;
          }
          i = Math.min(i + 2, n);
          continue;
        }
      }

      // 尾逗号：逗号后（跳过空白）紧跟 } 或 ] 时丢弃
      if (c === ',') {
        let j: number = i + 1;
        while (j < n) {
          const cj: string = s.charAt(j);
          if (cj === ' ' || cj === '\t' || cj === '\r' || cj === '\n') {
            j++;
            continue;
          }
          break;
        }
        if (j < n) {
          const nx: string = s.charAt(j);
          if (nx === '}' || nx === ']') {
            i++;
            continue;
          }
        }
      }

      out.push(c);
      i++;
    }
    return out.join('');
  }

  private static hex4(code: number): string {
    let h: string = code.toString(16);
    while (h.length < 4) {
      h = '0' + h;
    }
    return '\\u' + h;
  }
}
