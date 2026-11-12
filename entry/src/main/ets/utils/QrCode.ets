/**
 * 极简 QR 码编码器 —— 纯手写，零外部依赖。
 *
 * 为什么自己写：ohpm 上的二维码包要么体积大、要么带 native so，电视上装不了也难调。
 * 这里只用 UTF-8 字节模式（URL 全是 ASCII），支持版本 1~10、四档纠错等级。
 * 版本 10 + L 级最多能装 271 字节，局域网地址 + token 顶多 60 字节，绰绰有余。
 *
 * 流程（对着 ISO/IEC 18004 标准走的）：
 *   数据编码 → 补位 → 分块 → Reed-Solomon 纠错 → 交织 → 放置功能图形
 *   → 蛇形填数据 → 8 种掩码各算一遍代价、取最低 → 写格式/版本信息
 */

export const ECL_L: number = 0;
export const ECL_M: number = 1;
export const ECL_Q: number = 2;
export const ECL_H: number = 3;

/** 编码结果。modules[y][x] === true 表示该格是黑块 */
export class QrResult {
  ok: boolean = false;
  err: string = '';
  size: number = 0;
  version: number = 0;
  mask: number = 0;
  modules: boolean[][] = [];
}

export class QrCode {
  /**
   * Reed-Solomon 分块参数表。
   * 每项 5 个数：[每块纠错码字数, 第1组块数, 第1组每块数据码字数, 第2组块数, 第2组每块数据码字数]
   * 索引 = (version - 1) * 4 + ecl，ecl 顺序 L / M / Q / H
   */
  private static RS: number[][] = [
    // v1
    [7, 1, 19, 0, 0], [10, 1, 16, 0, 0], [13, 1, 13, 0, 0], [17, 1, 9, 0, 0],
    // v2
    [10, 1, 34, 0, 0], [16, 1, 28, 0, 0], [22, 1, 22, 0, 0], [28, 1, 16, 0, 0],
    // v3
    [15, 1, 55, 0, 0], [26, 1, 44, 0, 0], [18, 2, 17, 0, 0], [22, 2, 13, 0, 0],
    // v4
    [20, 1, 80, 0, 0], [18, 2, 32, 0, 0], [26, 2, 24, 0, 0], [16, 4, 9, 0, 0],
    // v5
    [26, 1, 108, 0, 0], [24, 2, 43, 0, 0], [18, 2, 15, 2, 16], [22, 2, 11, 2, 12],
    // v6
    [18, 2, 68, 0, 0], [16, 4, 27, 0, 0], [24, 4, 19, 0, 0], [28, 4, 15, 0, 0],
    // v7
    [20, 2, 78, 0, 0], [18, 4, 31, 0, 0], [18, 2, 14, 4, 15], [26, 4, 13, 1, 14],
    // v8
    [24, 2, 97, 0, 0], [22, 2, 38, 2, 39], [22, 4, 18, 2, 19], [26, 4, 14, 2, 15],
    // v9
    [30, 2, 116, 0, 0], [22, 3, 36, 2, 37], [20, 4, 16, 4, 17], [24, 4, 12, 4, 13],
    // v10
    [18, 2, 68, 2, 69], [26, 4, 43, 1, 44], [24, 6, 19, 2, 20], [28, 6, 15, 2, 16]
  ];

  /** 校正图形中心坐标表（版本 1 没有） */
  private static ALIGN: number[][] = [
    [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]
  ];

  private static MAX_VERSION: number = 10;

  // ---------------- 对外入口 ----------------

  static encode(text: string, ecl: number): QrResult {
    const out = new QrResult();
    const bytes = QrCode.utf8(text);
    if (bytes.length === 0) {
      out.err = '内容为空';
      return out;
    }

    // 1) 选最小可用版本
    let version = 0;
    let p: number[] = [];
    for (let v = 1; v <= QrCode.MAX_VERSION; v++) {
      const row = QrCode.rsParam(v, ecl);
      const totalData = row[1] * row[2] + row[3] * row[4];
      const countBits = v < 10 ? 8 : 16;
      if (4 + countBits + bytes.length * 8 <= totalData * 8) {
        version = v;
        p = row;
        break;
      }
    }
    if (version === 0) {
      out.err = '内容太长，超过版本 10 的容量';
      return out;
    }

    const totalData = p[1] * p[2] + p[3] * p[4];

    // 2) 数据编码：模式指示 0100（字节模式）+ 字符计数 + 数据
    const bits: number[] = [];
    QrCode.pushBits(bits, 4, 4);
    QrCode.pushBits(bits, bytes.length, version < 10 ? 8 : 16);
    for (let i = 0; i < bytes.length; i++) {
      QrCode.pushBits(bits, bytes[i], 8);
    }
    const capBits = totalData * 8;
    const left = capBits - bits.length;
    const term = left > 4 ? 4 : (left > 0 ? left : 0);
    QrCode.pushBits(bits, 0, term);
    while (bits.length % 8 !== 0) {
      bits.push(0);
    }
    const dataCw: number[] = [];
    for (let i = 0; i < bits.length; i += 8) {
      let b = 0;
      for (let k = 0; k < 8; k++) {
        b = (b << 1) | bits[i + k];
      }
      dataCw.push(b);
    }
    // 填充码字 0xEC / 0x11 交替，直到用完数据容量
    let flip = 0;
    while (dataCw.length < totalData) {
      dataCw.push(flip === 0 ? 0xEC : 0x11);
      flip = 1 - flip;
    }

    // 3) 分块 + RS 纠错 + 交织
    const ecCount = p[0];
    const blocks: number[][] = [];
    let off = 0;
    for (let i = 0; i < p[1]; i++) {
      blocks.push(dataCw.slice(off, off + p[2]));
      off += p[2];
    }
    for (let i = 0; i < p[3]; i++) {
      blocks.push(dataCw.slice(off, off + p[4]));
      off += p[4];
    }
    const gen = QrCode.rsGen(ecCount);
    const ecBlocks: number[][] = [];
    for (let i = 0; i < blocks.length; i++) {
      ecBlocks.push(QrCode.rsRemainder(blocks[i], gen, ecCount));
    }
    let maxData = 0;
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].length > maxData) {
        maxData = blocks[i].length;
      }
    }
    const stream: number[] = [];
    for (let i = 0; i < maxData; i++) {
      for (let b = 0; b < blocks.length; b++) {
        if (i < blocks[b].length) {
          stream.push(blocks[b][i]);
        }
      }
    }
    for (let i = 0; i < ecCount; i++) {
      for (let b = 0; b < ecBlocks.length; b++) {
        stream.push(ecBlocks[b][i]);
      }
    }

    // 4) 搭矩阵骨架
    const size = version * 4 + 17;
    const mod: boolean[][] = [];
    const fn: boolean[][] = [];
    for (let y = 0; y < size; y++) {
      const rowM: boolean[] = [];
      const rowF: boolean[] = [];
      for (let x = 0; x < size; x++) {
        rowM.push(false);
        rowF.push(false);
      }
      mod.push(rowM);
      fn.push(rowF);
    }

    QrCode.placeFinder(mod, fn, size, 0, 0);
    QrCode.placeFinder(mod, fn, size, size - 7, 0);
    QrCode.placeFinder(mod, fn, size, 0, size - 7);

    // 定位图形之间的定时图形
    for (let i = 8; i < size - 8; i++) {
      const dark = i % 2 === 0;
      mod[6][i] = dark;
      fn[6][i] = true;
      mod[i][6] = dark;
      fn[i][6] = true;
    }

    // 校正图形（跳过与三个定位图形重叠的角）
    const al = QrCode.ALIGN[version - 1];
    for (let i = 0; i < al.length; i++) {
      for (let j = 0; j < al.length; j++) {
        if ((i === 0 && j === 0)
          || (i === 0 && j === al.length - 1)
          || (i === al.length - 1 && j === 0)) {
          continue;
        }
        QrCode.placeAlign(mod, fn, al[i], al[j]);
      }
    }

    // 固定黑点（格式信息下方）
    mod[size - 8][8] = true;
    fn[size - 8][8] = true;

    // 先把格式/版本信息区占住，否则 placeData 会把数据位写进这些格子，
    // 最后又被格式信息覆盖掉，等于丢数据位。这里写的值只是占位，选完掩码会重写。
    QrCode.drawFormat(mod, fn, size, ecl, 0);
    if (version >= 7) {
      QrCode.drawVersion(mod, fn, size, version);
    }

    // 5) 蛇形填数据
    const dataBits: number[] = [];
    for (let i = 0; i < stream.length; i++) {
      QrCode.pushBits(dataBits, stream[i], 8);
    }
    QrCode.placeData(mod, fn, size, dataBits);

    // 6) 逐掩码试算，取代价最低的
    let bestMask = 0;
    let bestScore = -1;
    for (let m = 0; m < 8; m++) {
      const trial = QrCode.applyMask(mod, fn, size, m);
      QrCode.drawFormat(trial, fn, size, ecl, m);
      if (version >= 7) {
        QrCode.drawVersion(trial, fn, size, version);
      }
      const score = QrCode.penalty(trial, size);
      if (bestScore < 0 || score < bestScore) {
        bestScore = score;
        bestMask = m;
      }
    }

    const finalMod = QrCode.applyMask(mod, fn, size, bestMask);
    QrCode.drawFormat(finalMod, fn, size, ecl, bestMask);
    if (version >= 7) {
      QrCode.drawVersion(finalMod, fn, size, version);
    }

    out.ok = true;
    out.version = version;
    out.mask = bestMask;
    out.size = size;
    out.modules = finalMod;
    return out;
  }

  /** 自检用：把矩阵排成 0/1 文本，方便和别的实现逐格对照 */
  static dump(r: QrResult): string {
    const lines: string[] = [];
    lines.push('version=' + r.version + ' mask=' + r.mask + ' size=' + r.size);
    for (let y = 0; y < r.size; y++) {
      let s = '';
      for (let x = 0; x < r.size; x++) {
        s += r.modules[y][x] ? '1' : '0';
      }
      lines.push(s);
    }
    return lines.join('\n');
  }

  // ---------------- 内部实现 ----------------

  private static rsParam(version: number, ecl: number): number[] {
    const row = QrCode.RS[(version - 1) * 4 + ecl];
    const copy: number[] = [];
    for (let i = 0; i < row.length; i++) {
      copy.push(row[i]);
    }
    return copy;
  }

  private static pushBits(bits: number[], value: number, len: number): void {
    for (let i = len - 1; i >= 0; i--) {
      bits.push((value >> i) & 1);
    }
  }

  private static utf8(s: string): number[] {
    const out: number[] = [];
    let i = 0;
    while (i < s.length) {
      const c = s.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
        i++;
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6));
        out.push(0x80 | (c & 0x3F));
        i++;
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        const c2 = s.charCodeAt(i + 1);
        const cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
        out.push(0xF0 | (cp >> 18));
        out.push(0x80 | ((cp >> 12) & 0x3F));
        out.push(0x80 | ((cp >> 6) & 0x3F));
        out.push(0x80 | (cp & 0x3F));
        i += 2;
      } else {
        out.push(0xE0 | (c >> 12));
        out.push(0x80 | ((c >> 6) & 0x3F));
        out.push(0x80 | (c & 0x3F));
        i++;
      }
    }
    return out;
  }

  /** GF(256) 乘法，原始多项式 0x11D。用移位实现，省一张 512 项的表 */
  private static gfMul(a: number, b: number): number {
    let r = 0;
    let x = a;
    let y = b;
    while (y > 0) {
      if ((y & 1) !== 0) {
        r ^= x;
      }
      x <<= 1;
      if ((x & 0x100) !== 0) {
        x ^= 0x11D;
      }
      y >>= 1;
    }
    return r & 0xFF;
  }

  /** 生成多项式 g(x) = (x - a^0)(x - a^1)…(x - a^(ec-1))，系数从高次到低次 */
  private static rsGen(ec: number): number[] {
    let gen: number[] = [1];
    let root = 1;
    for (let i = 0; i < ec; i++) {
      const next: number[] = [];
      for (let k = 0; k <= gen.length; k++) {
        next.push(0);
      }
      for (let j = 0; j < gen.length; j++) {
        next[j] ^= gen[j];
        next[j + 1] ^= QrCode.gfMul(gen[j], root);
      }
      gen = next;
      root = QrCode.gfMul(root, 2);
    }
    return gen;
  }

  /** 取余数，得到 ec 个纠错码字 */
  private static rsRemainder(data: number[], gen: number[], ec: number): number[] {
    const res: number[] = [];
    for (let i = 0; i < ec; i++) {
      res.push(0);
    }
    for (let i = 0; i < data.length; i++) {
      const factor = data[i] ^ res[0];
      for (let k = 0; k < ec - 1; k++) {
        res[k] = res[k + 1];
      }
      res[ec - 1] = 0;
      if (factor !== 0) {
        for (let k = 0; k < ec; k++) {
          res[k] ^= QrCode.gfMul(gen[k + 1], factor);
        }
      }
    }
    return res;
  }

  private static placeFinder(mod: boolean[][], fn: boolean[][], size: number, cx: number, cy: number): void {
    for (let dy = -1; dy <= 7; dy++) {
      for (let dx = -1; dx <= 7; dx++) {
        const x = cx + dx;
        const y = cy + dy;
        if (x < 0 || y < 0 || x >= size || y >= size) {
          continue;
        }
        let dark = false;
        if (dx >= 0 && dx <= 6 && dy >= 0 && dy <= 6) {
          const edge = dx === 0 || dx === 6 || dy === 0 || dy === 6;
          const core = dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4;
          dark = edge || core;
        }
        mod[y][x] = dark;
        fn[y][x] = true;
      }
    }
  }

  private static placeAlign(mod: boolean[][], fn: boolean[][], cy: number, cx: number): void {
    for (let dy = -2; dy <= 2; dy++) {
      for (let dx = -2; dx <= 2; dx++) {
        const ring = Math.max(Math.abs(dx), Math.abs(dy));
        mod[cy + dy][cx + dx] = ring !== 1;
        fn[cy + dy][cx + dx] = true;
      }
    }
  }

  private static placeData(mod: boolean[][], fn: boolean[][], size: number, dataBits: number[]): void {
    let bitIdx = 0;
    let dir = -1;
    let x = size - 1;
    const total = dataBits.length;
    while (x > 0) {
      if (x === 6) {
        x--;
      }
      for (let i = 0; i < size; i++) {
        const y = dir === -1 ? size - 1 - i : i;
        for (let k = 0; k < 2; k++) {
          const xx = x - k;
          if (!fn[y][xx]) {
            const bit = bitIdx < total ? dataBits[bitIdx] : 0;
            mod[y][xx] = bit === 1;
            bitIdx++;
          }
        }
      }
      dir = -dir;
      x -= 2;
    }
  }

  private static maskHit(m: number, y: number, x: number): boolean {
    switch (m) {
      case 0:
        return (y + x) % 2 === 0;
      case 1:
        return y % 2 === 0;
      case 2:
        return x % 3 === 0;
      case 3:
        return (y + x) % 3 === 0;
      case 4:
        return (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0;
      case 5:
        return ((y * x) % 2 + (y * x) % 3) === 0;
      case 6:
        return (((y * x) % 2 + (y * x) % 3) % 2) === 0;
      default:
        return (((y + x) % 2 + (y * x) % 3) % 2) === 0;
    }
  }

  private static applyMask(mod: boolean[][], fn: boolean[][], size: number, m: number): boolean[][] {
    const out: boolean[][] = [];
    for (let y = 0; y < size; y++) {
      const row: boolean[] = [];
      for (let x = 0; x < size; x++) {
        let v = mod[y][x];
        if (!fn[y][x] && QrCode.maskHit(m, y, x)) {
          v = !v;
        }
        row.push(v);
      }
      out.push(row);
    }
    return out;
  }

  /** 格式信息：5 位数据 + BCH(15,5)，再异或 0x5412 */
  private static formatBits(ecl: number, mask: number): number {
    // 格式信息里的等级编码：L=01 M=00 Q=11 H=10
    const eclBits: number[] = [1, 0, 3, 2];
    const data = (eclBits[ecl] << 3) | mask;
    let d = data << 10;
    const g = 0x537;
    while (QrCode.bitLen(d) - QrCode.bitLen(g) >= 0) {
      d ^= g << (QrCode.bitLen(d) - QrCode.bitLen(g));
    }
    return ((data << 10) | d) ^ 0x5412;
  }

  private static bitLen(n: number): number {
    let d = 0;
    let v = n;
    while (v !== 0) {
      d++;
      v >>>= 1;
    }
    return d;
  }

  private static drawFormat(mod: boolean[][], fn: boolean[][], size: number, ecl: number, mask: number): void {
    const bits = QrCode.formatBits(ecl, mask);
    for (let i = 0; i < 15; i++) {
      const dark = ((bits >> i) & 1) === 1;
      // 竖向（左上角左侧 + 左下角）
      let y1 = 0;
      if (i < 6) {
        y1 = i;
      } else if (i < 8) {
        y1 = i + 1;
      } else {
        y1 = size - 15 + i;
      }
      mod[y1][8] = dark;
      fn[y1][8] = true;
      // 横向（左上角上方 + 右上角）
      let x1 = 0;
      if (i < 8) {
        x1 = size - i - 1;
      } else if (i < 9) {
        x1 = 15 - i - 1 + 1;
      } else {
        x1 = 15 - i - 1;
      }
      mod[8][x1] = dark;
      fn[8][x1] = true;
    }
  }

  /** 版本信息：6 位版本 + BCH(18,6)，只出现在版本 7 及以上 */
  private static drawVersion(mod: boolean[][], fn: boolean[][], size: number, version: number): void {
    let d = version << 12;
    const g = 0x1F25;
    while (QrCode.bitLen(d) - QrCode.bitLen(g) >= 0) {
      d ^= g << (QrCode.bitLen(d) - QrCode.bitLen(g));
    }
    const bits = (version << 12) | d;
    for (let i = 0; i < 18; i++) {
      const dark = ((bits >> i) & 1) === 1;
      const a = Math.floor(i / 3);
      const b = i % 3 + size - 8 - 3;
      mod[a][b] = dark;
      fn[a][b] = true;
      mod[b][a] = dark;
      fn[b][a] = true;
    }
  }

  /** 掩码罚分（标准四条规则），分数越低越好扫 */
  private static penalty(mat: boolean[][], size: number): number {
    let score = 0;
    // 规则 1：同色连续 5 格以上
    for (let y = 0; y < size; y++) {
      let run = 1;
      for (let x = 1; x < size; x++) {
        if (mat[y][x] === mat[y][x - 1]) {
          run++;
        } else {
          if (run >= 5) {
            score += 3 + (run - 5);
          }
          run = 1;
        }
      }
      if (run >= 5) {
        score += 3 + (run - 5);
      }
    }
    for (let x = 0; x < size; x++) {
      let run = 1;
      for (let y = 1; y < size; y++) {
        if (mat[y][x] === mat[y - 1][x]) {
          run++;
        } else {
          if (run >= 5) {
            score += 3 + (run - 5);
          }
          run = 1;
        }
      }
      if (run >= 5) {
        score += 3 + (run - 5);
      }
    }
    // 规则 2：2x2 同色块
    for (let y = 0; y < size - 1; y++) {
      for (let x = 0; x < size - 1; x++) {
        const v = mat[y][x];
        if (v === mat[y][x + 1] && v === mat[y + 1][x] && v === mat[y + 1][x + 1]) {
          score += 3;
        }
      }
    }
    // 规则 3：形如 1011101 0000 / 0000 1011101 的类定位图形
    for (let y = 0; y < size; y++) {
      for (let x = 0; x + 10 < size; x++) {
        if (QrCode.hitFinderLike(mat[y][x], mat[y][x + 1], mat[y][x + 2], mat[y][x + 3],
          mat[y][x + 4], mat[y][x + 5], mat[y][x + 6], mat[y][x + 7],
          mat[y][x + 8], mat[y][x + 9], mat[y][x + 10])) {
          score += 40;
        }
      }
    }
    for (let x = 0; x < size; x++) {
      for (let y = 0; y + 10 < size; y++) {
        if (QrCode.hitFinderLike(mat[y][x], mat[y + 1][x], mat[y + 2][x], mat[y + 3][x],
          mat[y + 4][x], mat[y + 5][x], mat[y + 6][x], mat[y + 7][x],
          mat[y + 8][x], mat[y + 9][x], mat[y + 10][x])) {
          score += 40;
        }
      }
    }
    // 规则 4：黑白比例偏离 50%
    let dark = 0;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        if (mat[y][x]) {
          dark++;
        }
      }
    }
    const total = size * size;
    const pct = dark * 100 / total;
    const dev = Math.abs(pct - 50);
    score += Math.floor(dev / 5) * 10;
    return score;
  }

  private static hitFinderLike(
    a0: boolean, a1: boolean, a2: boolean, a3: boolean, a4: boolean, a5: boolean,
    a6: boolean, a7: boolean, a8: boolean, a9: boolean, a10: boolean): boolean {
    const p1 = a0 && !a1 && a2 && a3 && a4 && !a5 && a6 && !a7 && !a8 && !a9 && !a10;
    const p2 = !a0 && !a1 && !a2 && !a3 && a4 && !a5 && a6 && a7 && a8 && !a9 && a10;
    return p1 || p2;
  }
}
