// Metal port of the film pipeline in index.html. Compiled at runtime.
enum FilmShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct FilmUniforms {
  float4 p0; // wb.rgb, exposure
  float4 p1; // contrast, fade, saturation, strength
  float4 p2; // split: shadows (a,b), highlights (a,b)
  float4 p3; // green: hue shift, chroma, lightness ; mono
  float4 p4; // blue: hue shift, chroma, lightness ; bypass
  float4 p5; // warm: hue shift, chroma ; halation ; bloom
  float4 p6; // grain, grain size, softness, vignette
  float4 p7; // frame, seed, srgb input, source lod
};

constexpr sampler lsamp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

float3 dec(float3 c) { c = clamp(c, float3(0.0), float3(1.0)); return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c)); }
float3 enc(float3 c) { c = max(c, float3(0.0)); return mix(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), c)); }

float3 readLinear(texture2d<float, access::sample> t, float2 uv, constant FilmUniforms& U) {
  float3 s = t.sample(lsamp, uv, level(U.p7.w)).rgb;
  return U.p7.z > 0.5 ? dec(s) : max(s, float3(0.0));
}

kernel void prefilter(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant FilmUniforms& U [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
  uint W = dst.get_width(), H = dst.get_height();
  if (gid.x >= W || gid.y >= H) return;
  float2 dsz = float2(W, H);
  float2 uv = (float2(gid) + 0.5) / dsz;
  float fp = float(src.get_width()) / dsz.x;
  int n = clamp(int(round(fp * 0.5)), 1, 6);
  bool srgb = U.p7.z > 0.5;
  float3 acc = float3(0.0);
  for (int j = 0; j < n; j++) {
    for (int i = 0; i < n; i++) {
      float2 o = (float2(i, j) + 0.5) / float(n) - 0.5;
      float3 s = src.sample(lsamp, uv + o / dsz, level(0.0)).rgb;
      if (srgb) {
        float m = max(s.r, max(s.g, s.b));
        acc += dec(s) * (1.0 + 5.0 * smoothstep(0.82, 1.0, m));
      } else {
        acc += min(max(s, float3(0.0)), float3(32.0));
      }
    }
  }
  float3 c = acc / float(n * n);
  c *= U.p0.rgb * exp2(U.p0.w);
  float br = max(c.r, max(c.g, c.b));
  float thr = 0.9, knee = 0.4;
  float rq = clamp(br - thr + knee, 0.0, 2.0 * knee); rq = rq * rq / (4.0 * knee);
  c *= max(rq, br - thr) / max(br, 1e-4);
  dst.write(float4(c, 1.0), gid);
}

kernel void downsample(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
  float2 t = 1.0 / float2(src.get_width(), src.get_height());
  float3 c = src.sample(lsamp, uv + float2(-1, -1) * t, level(0.0)).rgb + src.sample(lsamp, uv + float2(1, -1) * t, level(0.0)).rgb
           + src.sample(lsamp, uv + float2(-1, 1) * t, level(0.0)).rgb + src.sample(lsamp, uv + float2(1, 1) * t, level(0.0)).rgb;
  dst.write(float4(c * 0.25, 1.0), gid);
}

kernel void upsample(texture2d<float, access::sample> low [[texture(0)]],
                     texture2d<float, access::sample> high [[texture(1)]],
                     texture2d<float, access::write> dst [[texture(2)]],
                     constant float& r [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
  float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
  float2 t = 1.0 / float2(low.get_width(), low.get_height());
  float3 s = low.sample(lsamp, uv, level(0.0)).rgb * 4.0
    + (low.sample(lsamp, uv + float2(t.x, 0), level(0.0)).rgb + low.sample(lsamp, uv - float2(t.x, 0), level(0.0)).rgb
     + low.sample(lsamp, uv + float2(0, t.y), level(0.0)).rgb + low.sample(lsamp, uv - float2(0, t.y), level(0.0)).rgb) * 2.0
    + low.sample(lsamp, uv + t, level(0.0)).rgb + low.sample(lsamp, uv - t, level(0.0)).rgb
    + low.sample(lsamp, uv + float2(t.x, -t.y), level(0.0)).rgb + low.sample(lsamp, uv + float2(-t.x, t.y), level(0.0)).rgb;
  s /= 16.0;
  dst.write(float4(mix(high.sample(lsamp, uv, level(0.0)).rgb, s, float3(r)), 1.0), gid);
}

float hash12(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(float2 p) {
  float2 i = floor(p), f = fract(p); float2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash12(i), hash12(i + float2(1, 0)), u.x), mix(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), u.x), u.y);
}
float3 toLab(float3 c) {
  float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
  float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
  float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
  l = pow(max(l, 0.0), 1.0 / 3.0); m = pow(max(m, 0.0), 1.0 / 3.0); s = pow(max(s, 0.0), 1.0 / 3.0);
  return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
}
float3 fromLab(float3 c) {
  float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
  float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
  float s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
  l = l * l * l; m = m * m * m; s = s * s * s;
  return float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}
float hueW(float h, float center, float width) {
  float d = h - center * 0.0174533; d = atan2(sin(d), cos(d));
  float w = width * 0.0174533;
  return exp(-(d * d) / (w * w));
}
float3 filmCurve(float3 x, float contrast) {
  float k = 0.2 * contrast; float mid = 0.41;
  float3 hi = mid + (1.0 - mid) * tanh(x * k / (1.0 - mid));
  float3 lo = mid + mid * tanh(x * k * 1.05 / mid);
  return mix(lo, hi, step(float3(0.0), x));
}

kernel void finalize(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::sample> hal [[texture(1)]],
                     texture2d<float, access::sample> blm [[texture(2)]],
                     texture2d<float, access::write> dst [[texture(3)]],
                     constant FilmUniforms& U [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
  uint W = dst.get_width(), H = dst.get_height();
  if (gid.x >= W || gid.y >= H) return;
  float2 full = float2(W, H);
  float2 p = float2(gid) + 0.5;
  float2 uv = p / full;
  float shortS = min(full.x, full.y);
  float3 wb = U.p0.rgb; float exposure = U.p0.w;
  float strength = U.p1.w;

  float3 lin = readLinear(src, uv, U);
  if (U.p4.w > 0.5) { dst.write(float4(enc(lin * exp2(exposure)), 1.0), gid); return; }

  float soft = U.p6.z;
  if (soft > 0.0) {
    float2 r = float2(shortS / 1400.0) / full;
    float3 b = lin * 0.2;
    for (int i = 0; i < 8; i++) {
      float a = float(i) * 0.7853982 + 0.3;
      float2 off = float2(cos(a), sin(a)) * r * ((i % 2 == 0) ? 1.0 : 0.55);
      b += readLinear(src, uv + off, U) * 0.1;
    }
    lin = mix(lin, b, float3(clamp(soft, 0.0, 1.0) * 0.85));
  }
  float3 orig = lin;

  lin *= wb * exp2(exposure);
  float2 q = (p - 0.5 * full) / (0.5 * length(full));
  lin *= 1.0 - U.p6.w * 0.7 * smoothstep(0.12, 1.0, dot(q, q));

  float3 h = hal.sample(lsamp, uv, level(0.0)).rgb;
  float3 bl = blm.sample(lsamp, uv, level(0.0)).rgb;
  float hl = dot(h, float3(0.45, 0.4, 0.15));
  lin += U.p5.z * hl * float3(1.0, 0.2, 0.035) * 0.45;
  lin += U.p5.w * bl * 0.18;

  const float off = 0.004;
  float3 lg = log2(lin + off);
  float mn = dot(lg, float3(0.2126, 0.7152, 0.0722));
  lg = mn + (lg - mn) * U.p1.z * 0.88;
  lin = max(exp2(lg) - off, float3(0.0));

  float3 y = filmCurve(log2((lin + 1e-5) / 0.18), U.p1.x);
  y = U.p1.y + (0.985 - U.p1.y) * y;

  float3 lab = toLab(dec(y));
  float C = length(lab.yz);
  float hh = atan2(lab.z, lab.y);
  float cw = smoothstep(0.015, 0.05, C);
  float wg = hueW(hh, 140.0, 38.0) * cw;
  float wbl = hueW(hh, 252.0, 40.0) * cw;
  float ww = hueW(hh, 50.0, 32.0) * cw;
  hh += 0.0174533 * (U.p3.x * wg + U.p4.x * wbl + U.p5.x * ww);
  C *= mix(1.0, U.p3.y, wg) * mix(1.0, U.p4.y, wbl) * mix(1.0, U.p5.y, ww);
  lab.x *= mix(1.0, U.p3.z, wg) * mix(1.0, U.p4.z, wbl);
  C = 0.17 * tanh(C / 0.17);
  lab.yz = C * float2(cos(hh), sin(hh)) * (1.0 - U.p3.w);
  float ws = 1.0 - smoothstep(0.08, 0.6, lab.x);
  float whl = smoothstep(0.5, 0.95, lab.x);
  lab.yz += U.p2.xy * ws + U.p2.zw * whl;
  float3 col = enc(clamp(fromLab(lab), float3(0.0), float3(1.0)));

  col = mix(enc(clamp(orig * wb * exp2(exposure), float3(0.0), float3(1.0))), col, float3(strength));

  float grain = U.p6.x;
  if (grain > 0.0) {
    float cellIdeal = shortS * U.p6.y / 2200.0;
    float cell = max(cellIdeal, 1.0);
    float ampS = cellIdeal / cell;
    float2 gp = p / cell + U.p7.y * float2(37.1, 91.7);
    float n = (vn(gp) - 0.5) + (vn(gp * 2.13 + 11.3) - 0.5) * 0.6 + (vn(gp * 0.47 + 3.7) - 0.5) * 0.4;
    float3 nc = float3(vn(gp * 1.3 + 71.0), vn(gp * 1.3 + 143.0), vn(gp * 1.3 + 213.0)) - 0.5;
    float Y = dot(col, float3(0.2126, 0.7152, 0.0722));
    float resp = mix(0.5, 1.0, 1.0 - abs(2.0 * Y - 1.0)) * (1.0 - 0.7 * smoothstep(0.85, 1.0, Y));
    col += grain * strength * 0.2 * ampS * resp * (float3(n) + nc * 0.4 * (1.0 - U.p3.w));
  }

  if (U.p7.x > 0.5) {
    float seed = U.p7.y;
    float2 c = (p - 0.5 * full) / shortS;
    float2 offs = (float2(hash12(float2(seed, 1.0)), hash12(float2(seed, 2.0))) - 0.5) * 0.006;
    float2 he = 0.5 * full / shortS - float2(0.011);
    float rad = 0.028;
    float2 d = abs(c - offs) - (he - rad);
    float sd = length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - rad;
    float ang = atan2(c.y, c.x);
    sd += (vn(float2(ang * 90.0, seed * 7.0)) - 0.5) * 0.0018 + (vn(float2(ang * 12.0, seed * 3.0)) - 0.5) * 0.002;
    float px = 1.2 / shortS;
    float inside = 1.0 - smoothstep(-px, px, sd);
    col *= 1.0 - 0.35 * smoothstep(-0.03, 0.0, sd);
    col = mix(float3(0.012, 0.011, 0.012), col, float3(inside));
  }
  dst.write(float4(clamp(col, float3(0.0), float3(1.0)), 1.0), gid);
}
"""#
}
