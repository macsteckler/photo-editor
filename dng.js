'use strict';
// Minimal DNG reader for iPhone RAW files.
//  - Apple ProRAW (LinearRaw, 3 samples/pixel) and Bayer CFA DNGs
//  - Uncompressed, lossless JPEG (LJ92) and Deflate compression
// Produces 16-bit sensor samples plus the metadata needed to develop them:
// black/white levels, CFA layout, white balance, camera->sRGB matrix, crop, orientation.
const DNG = (() => {
  const TYPE_SIZE = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8 };

  function isDNG(u8) {
    return u8.length > 8 && ((u8[0] === 0x49 && u8[1] === 0x49 && u8[2] === 42 && u8[3] === 0) ||
                             (u8[0] === 0x4d && u8[1] === 0x4d && u8[2] === 0 && u8[3] === 42));
  }

  function parseTIFF(buf) {
    const dv = new DataView(buf);
    const le = dv.getUint16(0) === 0x4949;
    const u16 = o => dv.getUint16(o, le), u32 = o => dv.getUint32(o, le);
    const read = (type, off) => {
      switch (type) {
        case 1: case 7: return dv.getUint8(off);
        case 6: return dv.getInt8(off);
        case 3: return u16(off);
        case 8: return dv.getInt16(off, le);
        case 4: case 13: return u32(off);
        case 9: return dv.getInt32(off, le);
        case 5: { const d = u32(off + 4); return d ? u32(off) / d : 0; }
        case 10: { const d = dv.getInt32(off + 4, le); return d ? dv.getInt32(off, le) / d : 0; }
        case 11: return dv.getFloat32(off, le);
        case 12: return dv.getFloat64(off, le);
        case 16: return Number(dv.getBigUint64(off, le));
        default: return 0;
      }
    };
    const seen = new Set();
    function readIFD(off) {
      if (!off || seen.has(off) || off + 2 > buf.byteLength) return null;
      seen.add(off);
      const n = u16(off), tags = {};
      for (let i = 0; i < n; i++) {
        const e = off + 2 + i * 12;
        const tag = u16(e), type = u16(e + 2), count = u32(e + 4);
        const size = (TYPE_SIZE[type] || 1) * count;
        const voff = size <= 4 ? e + 8 : u32(e + 8);
        if (voff + size > buf.byteLength) continue;
        if ((type === 1 || type === 7 || type === 2) && count > 64) { tags[tag] = { offset: voff, count }; continue; }
        if (count > 300000) continue;
        const step = TYPE_SIZE[type] || 1, vals = new Array(count);
        for (let k = 0; k < count; k++) vals[k] = read(type, voff + k * step);
        tags[tag] = vals;
      }
      const ifd = { tags, sub: [] };
      if (tags[330]) for (const o of tags[330]) { const s = readIFD(o); if (s) ifd.sub.push(s); }
      ifd.next = u32(off + 2 + n * 12);
      return ifd;
    }
    const ifds = [];
    let off = u32(4);
    while (off && ifds.length < 8) { const ifd = readIFD(off); if (!ifd) break; ifds.push(ifd); off = ifd.next; }
    return { ifds, le };
  }

  // ---------------- Lossless JPEG (ITU T.81 process 14) ----------------
  function decodeLJ92(u8, start, end) {
    let p = start;
    const huff = [];
    let W = 0, H = 0, ncomp = 0, prec = 0, comps = [], pred = 1, pt = 0, restart = 0;
    const r16 = q => (u8[q] << 8) | u8[q + 1];
    if (r16(p) !== 0xffd8) throw new Error('Bad lossless JPEG');
    p += 2;
    for (;;) {
      while (u8[p] !== 0xff) p++;
      const m = r16(p); p += 2;
      const len = r16(p);
      if (m === 0xffc4) {
        let q = p + 2; const e = p + len;
        while (q < e) {
          const id = u8[q] & 0x0f; q++;
          const counts = u8.subarray(q, q + 16); q += 16;
          let total = 0; for (const c of counts) total += c;
          const syms = u8.subarray(q, q + total); q += total;
          // 16-bit lookup table: (length << 8) | symbol
          const lut = new Uint16Array(65536);
          let code = 0, k = 0;
          for (let L = 1; L <= 16; L++) {
            for (let i = 0; i < counts[L - 1]; i++) {
              const lo = code << (16 - L), hi = lo + (1 << (16 - L));
              const v = (L << 8) | syms[k++];
              for (let x = lo; x < hi; x++) lut[x] = v;
              code++;
            }
            code <<= 1;
          }
          huff[id] = lut;
        }
      } else if (m === 0xffc3) {
        prec = u8[p + 2]; H = r16(p + 3); W = r16(p + 5); ncomp = u8[p + 7];
      } else if (m === 0xffdd) {
        restart = r16(p + 2);
      } else if (m === 0xffda) {
        const ns = u8[p + 2];
        comps = [];
        for (let i = 0; i < ns; i++) comps.push(huff[u8[p + 4 + i * 2] >> 4]);
        pred = u8[p + 3 + ns * 2];
        pt = u8[p + 5 + ns * 2] & 0x0f;
        p += len;
        break;
      } else if (m === 0xffd9) {
        throw new Error('Lossless JPEG has no scan');
      }
      p += len;
    }
    if (!W || !H || !ncomp) throw new Error('Unsupported JPEG (not lossless)');
    const rowLen = W * ncomp;
    const out = new Uint16Array(rowLen * H);
    // bit reader
    let buf = 0, n = 0;
    const fill = () => {
      while (n <= 24) {
        let b = 0;
        if (p < end) {
          b = u8[p];
          if (b === 0xff) {
            const nx = u8[p + 1];
            if (nx === 0) p += 2; else b = 0; // marker: feed zeros
          } else p++;
        }
        buf = ((buf << 8) | b) >>> 0; n += 8;
      }
    };
    const skipToRestart = () => {
      n = 0; buf = 0;
      while (p < end - 1 && !(u8[p] === 0xff && u8[p + 1] >= 0xd0 && u8[p + 1] <= 0xd7)) p++;
      p += 2;
    };
    const initPred = 1 << (prec - pt - 1);
    let mcu = 0;
    for (let y = 0; y < H; y++) {
      const row = y * rowLen, prev = row - rowLen;
      let fresh = y === 0;
      if (restart && y > 0 && (mcu % restart) === 0) { skipToRestart(); fresh = true; }
      for (let x = 0; x < W; x++) {
        for (let c = 0; c < ncomp; c++) {
          if (n < 16) fill();
          const e = comps[c][(buf >>> (n - 16)) & 0xffff];
          const len = e >> 8; n -= len;
          const s = e & 0xff;
          let diff = 0;
          if (s === 16) diff = -32768;
          else if (s) {
            if (n < s) fill();
            diff = (buf >>> (n - s)) & ((1 << s) - 1); n -= s;
            if (diff < (1 << (s - 1))) diff -= (1 << s) - 1;
          }
          const i = row + x * ncomp + c;
          let P;
          if (fresh) P = x === 0 ? initPred : out[i - ncomp];
          else if (x === 0) P = out[prev + c];
          else {
            const Ra = out[i - ncomp], Rb = out[prev + x * ncomp + c], Rc = out[prev + (x - 1) * ncomp + c];
            switch (pred) {
              case 1: P = Ra; break;
              case 2: P = Rb; break;
              case 3: P = Rc; break;
              case 4: P = Ra + Rb - Rc; break;
              case 5: P = Ra + ((Rb - Rc) >> 1); break;
              case 6: P = Rb + ((Ra - Rc) >> 1); break;
              default: P = (Ra + Rb) >> 1;
            }
          }
          out[i] = (P + diff) & 0xffff;
        }
        mcu++;
      }
    }
    return { data: out, W, H, ncomp };
  }

  async function inflate(u8) {
    const ds = new DecompressionStream('deflate');
    const stream = new Blob([u8]).stream().pipeThrough(ds);
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  function unpackBits(u8, bits, count, le) {
    const out = new Uint16Array(count);
    if (bits === 16) {
      const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
      for (let i = 0; i < count; i++) out[i] = dv.getUint16(i * 2, le);
    } else if (bits === 8) {
      for (let i = 0; i < count; i++) out[i] = u8[i];
    } else {
      let acc = 0, nb = 0, q = 0;
      for (let i = 0; i < count; i++) {
        while (nb < bits) { acc = ((acc << 8) | u8[q++]) >>> 0; nb += 8; }
        out[i] = (acc >>> (nb - bits)) & ((1 << bits) - 1); nb -= bits;
        acc &= (1 << nb) - 1;
      }
    }
    return out;
  }

  // ---------------- Colour ----------------
  const mul = (a, b) => { const r = new Array(9).fill(0);
    for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) for (let k = 0; k < 3; k++) r[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j];
    return r; };
  const inv = m => {
    const [a, b, c, d, e, f, g, h, i] = m;
    const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
    const det = a * A + b * B + c * C;
    return [A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d].map(v => v / det);
  };
  const SRGB_TO_XYZ = [0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041];
  const XYZ_TO_SRGB = inv(SRGB_TO_XYZ);
  const D50_TO_D65 = [0.9555766, -0.0230393, 0.0631636, -0.0282895, 1.0099416, 0.0210077, 0.0122982, -0.0204830, 1.3299098];

  function colorMatrix(t, neutral) {
    const ill1 = t[50778] ? t[50778][0] : 0, ill2 = t[50779] ? t[50779][0] : 0;
    // Prefer the D65 (21) calibration when available
    const pick = (a, b) => (b && (ill2 === 21 || ill1 !== 21)) ? b : (a || b);
    const fm = pick(t[50964], t[50965]);
    const nInv = neutral.map(v => 1 / v);
    if (fm && fm.length === 9) {
      // Forward matrix: white-balanced camera -> XYZ(D50)
      return mul(mul(XYZ_TO_SRGB, D50_TO_D65), mul(fm, [nInv[0], 0, 0, 0, nInv[1], 0, 0, 0, nInv[2]]));
    }
    const cm = pick(t[50721], t[50722]);
    if (cm && cm.length === 9) {
      const camRgb = mul(cm, SRGB_TO_XYZ);
      for (let r = 0; r < 3; r++) { const s = camRgb[r * 3] + camRgb[r * 3 + 1] + camRgb[r * 3 + 2]; for (let c = 0; c < 3; c++) camRgb[r * 3 + c] /= s; }
      return mul(inv(camRgb), [nInv[0], 0, 0, 0, nInv[1], 0, 0, 0, nInv[2]]);
    }
    return [nInv[0], 0, 0, 0, nInv[1], 0, 0, 0, nInv[2]];
  }

  // ---------------- Main ----------------
  // opts.maxPixels: LinearRaw images above this are 2x2 binned while decoding.
  async function decode(arrayBuffer, opts = {}) {
    const maxPixels = opts.maxPixels || 30e6;
    const u8 = new Uint8Array(arrayBuffer);
    const { ifds, le } = parseTIFF(arrayBuffer);
    const all = [];
    const walk = ifd => { all.push(ifd); ifd.sub.forEach(walk); };
    ifds.forEach(walk);
    const main = all.find(f => (f.tags[254] ? f.tags[254][0] : 0) === 0 && f.tags[262] && (f.tags[262][0] === 32803 || f.tags[262][0] === 34892));
    if (!main) throw new Error('No raw image found in this DNG');
    const t0 = ifds[0].tags, t = main.tags;
    const g = (tag, d) => (t[tag] ? t[tag] : (t0[tag] ? t0[tag] : d));
    const W = t[256][0], H = t[257][0];
    const photometric = t[262][0];
    const spp = t[277] ? t[277][0] : 1;
    const bits = t[258] ? t[258][0] : 16;
    const compression = t[259] ? t[259][0] : 1;
    if (t[339] && t[339][0] === 3) throw new Error('Floating-point DNGs are not supported');
    if (compression === 52546) throw new Error('This DNG uses JPEG XL compression. On iPhone, set Settings → Camera → Formats → ProRAW to “JPEG Lossless (Most Compatible)”.');
    if (compression === 34892) throw new Error('Lossy DNGs are not supported');
    if (![1, 7, 8, 32946].includes(compression)) throw new Error('Unsupported DNG compression ' + compression);

    const tiled = !!t[324];
    const tw = tiled ? t[322][0] : W, th = tiled ? t[323][0] : (t[278] ? t[278][0] : H);
    const offsets = tiled ? t[324] : t[273], counts = tiled ? t[325] : t[279];
    const across = Math.ceil(W / tw);
    const bin = (photometric === 34892 && W * H > maxPixels && tw % 2 === 0 && th % 2 === 0) ? 2 : 1;
    const OW = Math.floor(W / bin), OH = Math.floor(H / bin);
    const out = new Uint16Array(OW * OH * spp);
    const lin = t[50712];

    for (let k = 0; k < offsets.length; k++) {
      const tx = (k % across) * tw, ty = Math.floor(k / across) * th;
      const seg = u8.subarray(offsets[k], offsets[k] + counts[k]);
      let tile, tileRow;
      if (compression === 7) {
        const d = decodeLJ92(u8, offsets[k], offsets[k] + counts[k]);
        tile = d.data; tileRow = d.W * d.ncomp; // usually == tw*spp
      } else {
        const raw = (compression === 8 || compression === 32946) ? await inflate(seg) : seg;
        const rows = tiled ? th : Math.min(th, H - ty);
        tile = unpackBits(raw, bits, tw * rows * spp, le);
        tileRow = tw * spp;
        if (t[317] && t[317][0] === 2) {
          for (let y = 0; y < rows; y++) for (let x = spp; x < tw * spp; x++) tile[y * tileRow + x] += tile[y * tileRow + x - spp];
        }
      }
      if (lin) for (let i = 0; i < tile.length; i++) tile[i] = lin[Math.min(tile[i], lin.length - 1)];
      const cols = Math.min(tw, W - tx), rows = Math.min(th, H - ty, Math.floor(tile.length / tileRow));
      if (bin === 1) {
        for (let y = 0; y < rows; y++) {
          const src = y * tileRow, dst = ((ty + y) * W + tx) * spp;
          out.set(tile.subarray(src, src + cols * spp), dst);
        }
      } else {
        for (let y = 0; y + 1 < rows; y += 2) {
          const oy = (ty + y) >> 1; if (oy >= OH) break;
          for (let x = 0; x + 1 < cols; x += 2) {
            const ox = (tx + x) >> 1; if (ox >= OW) break;
            for (let c = 0; c < spp; c++) {
              const a = y * tileRow + x * spp + c;
              out[(oy * OW + ox) * spp + c] = (tile[a] + tile[a + spp] + tile[a + tileRow] + tile[a + tileRow + spp] + 2) >> 2;
            }
          }
        }
      }
      if (opts.onProgress) opts.onProgress((k + 1) / offsets.length);
      if (k % 16 === 15) await new Promise(r => setTimeout(r, 0));
    }

    // Levels
    const black = t[50714] || [0];
    const blackDim = t[50713] || [1, 1];
    const white = t[50717] ? t[50717][0] : (1 << bits) - 1;
    let black4;
    if (spp === 1) {
      // per CFA position (x + 2y), repeating
      black4 = [0, 1, 2, 3].map(i => { const x = i & 1, y = i >> 1;
        return black[((y % blackDim[0]) * blackDim[1] + (x % blackDim[1])) % black.length]; });
    } else {
      black4 = [0, 1, 2, 3].map(i => black[Math.min(i, black.length - 1)]);
    }
    const avgDelta = arr => arr ? arr.reduce((a, b) => a + b, 0) / arr.length : 0;
    const dBlack = avgDelta(t[50715]) + avgDelta(t[50716]);
    black4 = black4.map(v => v + dBlack);

    // Geometry (in binned sensor coordinates)
    const active = t[50829] || [0, 0, H, W]; // top, left, bottom, right
    const cropO = t[50719] || [0, 0], cropS = t[50720] || [active[3] - active[1], active[2] - active[0]];
    const origin = [Math.round((active[1] + cropO[0]) / bin), Math.round((active[0] + cropO[1]) / bin)];
    const size = [Math.min(Math.round(cropS[0] / bin), OW - origin[0]), Math.min(Math.round(cropS[1] / bin), OH - origin[1])];

    // CFA layout: channel index (0 R, 1 G, 2 B) at each 2x2 position relative to the active area
    let cfa = [0, 1, 1, 2];
    if (spp === 1) {
      const dim = t[33421] || [2, 2], pat = t[33422];
      if (!pat || dim[0] !== 2 || dim[1] !== 2) throw new Error('Only 2x2 Bayer sensors are supported');
      cfa = [pat[0], pat[1], pat[2], pat[3]];
      if (cfa.some(c => c > 2)) throw new Error('Unsupported CFA colours');
    }

    const neutral = (g(50728, null) || [1, 1, 1]).slice(0, 3);
    const m = colorMatrix(t0, neutral);
    const baseline = (g(50730, [0]))[0] || 0;
    const orientation = (t0[274] || [1])[0];

    return {
      kind: spp === 1 ? 'cfa' : 'linear',
      width: OW, height: OH, spp, data: out,
      black: black4, white, cfa,
      activeOrigin: [Math.round(active[1] / bin), Math.round(active[0] / bin)],
      cropOrigin: origin, cropSize: size,
      matrix: m, neutral, baselineExposure: baseline, orientation, binned: bin > 1,
      make: readAscii(u8, t0[271]), model: readAscii(u8, t0[272]),
    };
  }
  function readAscii(u8, v) {
    if (!v) return '';
    if (Array.isArray(v)) return String.fromCharCode(...v).replace(/\0.*$/, '');
    return String.fromCharCode(...u8.subarray(v.offset, v.offset + v.count)).replace(/\0.*$/, '');
  }

  return { isDNG, decode, decodeLJ92, parseTIFF };
})();
