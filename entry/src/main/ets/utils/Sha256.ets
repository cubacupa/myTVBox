/**
 * SHA-256（纯 ArkTS 实现，不依赖任何系统加密能力）。
 *
 * 为什么不用 @kit.CryptoArchitectureKit：
 * 它的 `createRandom` 在 tv 类型设备上明确不可用（编译期警告
 * "This API is unavailable to tv"），`createKdf` 也只标了「部分设备可用」。
 * 家长锁在智慧屏上必须一定能存、一定能验，不能赌 syscap，所以这里自带实现。
 *
 * 实现范围只覆盖本工程用到的场景：输入是几十字节以内的小数据、单次摘要。
 * 没有做流式 update，也没有处理超过 2^32 位（512MB）的消息长度。
 */

/** SHA-256 轮常量：前 64 个质数立方根小数部分的前 32 位 */
const K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

/** 32 位循环右移 */
function ror(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) | 0;
}

export class Sha256 {
  /** 对一段字节求 SHA-256，返回 32 字节摘要 */
  static digest(msg: Uint8Array): Uint8Array {
    let h0: number = 0x6a09e667 | 0;
    let h1: number = 0xbb67ae85 | 0;
    let h2: number = 0x3c6ef372 | 0;
    let h3: number = 0xa54ff53a | 0;
    let h4: number = 0x510e527f | 0;
    let h5: number = 0x9b05688c | 0;
    let h6: number = 0x1f83d9ab | 0;
    let h7: number = 0x5be0cd19 | 0;

    const len: number = msg.length;
    // 填充：消息 + 0x80 + 若干 0，直到长度 ≡ 56 (mod 64)，再补 8 字节长度
    const total: number = (((len + 9) + 63) >> 6) << 6;
    const buf: Uint8Array = new Uint8Array(total);
    buf.set(msg);
    buf[len] = 0x80;
    const bits: number = len * 8;
    buf[total - 4] = (bits >>> 24) & 0xff;
    buf[total - 3] = (bits >>> 16) & 0xff;
    buf[total - 2] = (bits >>> 8) & 0xff;
    buf[total - 1] = bits & 0xff;

    const w: number[] = new Array<number>(64);
    for (let off = 0; off < total; off += 64) {
      for (let i = 0; i < 16; i++) {
        const p: number = off + i * 4;
        w[i] = ((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) | 0;
      }
      for (let i = 16; i < 64; i++) {
        const x: number = w[i - 15];
        const y: number = w[i - 2];
        const s0: number = (ror(x, 7) ^ ror(x, 18) ^ (x >>> 3)) | 0;
        const s1: number = (ror(y, 17) ^ ror(y, 19) ^ (y >>> 10)) | 0;
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }

      let a: number = h0;
      let b: number = h1;
      let c: number = h2;
      let d: number = h3;
      let e: number = h4;
      let f: number = h5;
      let g: number = h6;
      let h: number = h7;

      for (let i = 0; i < 64; i++) {
        const bigS1: number = (ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)) | 0;
        const ch: number = ((e & f) ^ (~e & g)) | 0;
        const t1: number = (h + bigS1 + ch + K[i] + w[i]) | 0;
        const bigS0: number = (ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)) | 0;
        const maj: number = ((a & b) ^ (a & c) ^ (b & c)) | 0;
        const t2: number = (bigS0 + maj) | 0;
        h = g;
        g = f;
        f = e;
        e = (d + t1) | 0;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) | 0;
      }

      h0 = (h0 + a) | 0;
      h1 = (h1 + b) | 0;
      h2 = (h2 + c) | 0;
      h3 = (h3 + d) | 0;
      h4 = (h4 + e) | 0;
      h5 = (h5 + f) | 0;
      h6 = (h6 + g) | 0;
      h7 = (h7 + h) | 0;
    }

    const out: Uint8Array = new Uint8Array(32);
    const hs: number[] = [h0, h1, h2, h3, h4, h5, h6, h7];
    for (let i = 0; i < 8; i++) {
      const v: number = hs[i];
      out[i * 4] = (v >>> 24) & 0xff;
      out[i * 4 + 1] = (v >>> 16) & 0xff;
      out[i * 4 + 2] = (v >>> 8) & 0xff;
      out[i * 4 + 3] = v & 0xff;
    }
    return out;
  }

  /**
   * 把 PIN 与盐做成摘要，并重复迭代若干轮。
   *
   * 这不是标准 PBKDF2，只是「加盐 + 迭代」：对 4 位数字这种低熵口令来说，
   * 迭代能把离线枚举的成本乘上迭代次数，够用且实现可控。
   * 轮数不宜太高 —— 校验是同步的、跑在 UI 线程，电视 CPU 也弱。
   */
  static stretch(pin: string, salt: Uint8Array, rounds: number): Uint8Array {
    const pinBytes: Uint8Array = new Uint8Array(pin.length);
    for (let i = 0; i < pin.length; i++) {
      pinBytes[i] = pin.charCodeAt(i) & 0xff;
    }
    const seed: Uint8Array = new Uint8Array(salt.length + pinBytes.length);
    seed.set(salt);
    seed.set(pinBytes, salt.length);

    let h: Uint8Array = Sha256.digest(seed);
    for (let i = 0; i < rounds; i++) {
      h = Sha256.digest(h);
    }
    return h;
  }

  static toHex(b: Uint8Array): string {
    let s: string = '';
    for (let i = 0; i < b.length; i++) {
      const v: number = b[i];
      s += (v < 16 ? '0' : '') + v.toString(16);
    }
    return s;
  }

  static fromHex(s: string): Uint8Array {
    const n: number = Math.floor(s.length / 2);
    const out: Uint8Array = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      out[i] = parseInt(s.substring(i * 2, i * 2 + 2), 16);
    }
    return out;
  }
}
