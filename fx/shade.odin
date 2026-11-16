// Pictures made by shaders: SkSL filling a rect, optionally drawn smaller
// and scaled up (smooth fields cost a fraction that way on the CPU), and a
// few ready-made ones: a nebula of warped noise, a raymarched iridescent
// orb, a tunnel.
//
//   fx.nebula(fx.stage(), s.t, {deep = 0xff0a0908, mid = 0xffd97757, hot = 0xfff3eee3})
package fx

import "core:c"
import "core:fmt"
import "core:math"
import sk "../sk"

@(private = "file", thread_local)
lowres: struct {
	s:    ^sk.Surface,
	w, h: i32,
}

// fx.shader drawn at res (0..1) of r's pixels and scaled up to it: for
// smooth pictures. The shader still sees stage coordinates. Opaque: what was
// behind r is replaced.
shader_scaled :: proc(sksl: cstring, r: Rect, res: f32, uniforms: ..f32) {
	k := clamp(res, 0.05, 1) * S.scale
	w, h := max(i32(math.ceil(r.w * k)), 1), max(i32(math.ceil(r.h * k)), 1)
	if lowres.s == nil || lowres.w != w || lowres.h != h {
		if lowres.s != nil do sk.surface_free(lowres.s)
		lowres.s = sk.surface_raster(w, h)
		lowres.w, lowres.h = w, h
	}
	cv := sk.surface_canvas(lowres.s)
	sk.canvas_clear(cv, 0)
	sk.canvas_save(cv)
	sk.canvas_scale(cv, f32(w) / r.w, f32(h) / r.h)
	sk.canvas_translate(cv, -r.x, -r.y)
	err: [512]u8
	if !sk.canvas_draw_sksl(cv, sksl, raw_data(uniforms), c.size_t(len(uniforms)), r.x, r.y, r.w, r.h, &err[0], len(err)) {
		fmt.eprintln("fx: shader:", cstring(&err[0]))
	}
	sk.canvas_restore(cv)
	img := sk.surface_snapshot(lowres.s)
	defer sk.image_free(img)
	sk.canvas_draw_image(S.cv, img, nil, r.x, r.y, r.w, r.h, 1)
}

@(private)
rgb3 :: proc(c: Color) -> [3]f32 {
	u := unpack(c)
	return {u.r, u.g, u.b}
}

// ---------------------------------------------------------------- nebula

Nebula :: struct {
	deep, mid, hot: Color, // background, the filaments, their brightest cores
	scale:          f32, // size of the structures, 0 = 1 (bigger = larger clouds)
	detail:         f32, // 0..1 how wispy, 0 = 0.5
	level:          f32, // overall brightness, 0 = 1
	flow:           Vec2, // drift of the whole field, stage heights per second
	seed:           f32,
	res:            f32, // render resolution, 0 = 1/3
}

// Slow filaments of warped noise: a sky, a mind, a field to put things in.
nebula :: proc(r: Rect, t: f32, n: Nebula) {
	d, m, h := rgb3(n.deep), rgb3(n.mid), rgb3(n.hot)
	shader_scaled(
		NEBULA, r, n.res > 0 ? n.res : 1.0 / 3,
		t, r.x, r.y, r.w, r.h, d.r, d.g, d.b, m.r, m.g, m.b, h.r, h.g, h.b,
		n.scale > 0 ? n.scale : 1, n.detail > 0 ? n.detail : 0.5, n.level > 0 ? n.level : 1, n.flow.x, n.flow.y, n.seed,
	)
}

NOISE_SKSL :: `
float h12(float2 p) {
	float3 p3 = fract(float3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vn(float2 p) {
	float2 i = floor(p), f = fract(p);
	f = f * f * (3 - 2 * f);
	return mix(mix(h12(i), h12(i + float2(1, 0)), f.x), mix(h12(i + float2(0, 1)), h12(i + float2(1, 1)), f.x), f.y);
}
float fbm(float2 p) {
	float a = 0.5, s = 0;
	for (int i = 0; i < 4; i++) { s += a * vn(p); p = float2(p.x * 1.6 + p.y * 1.2, p.y * 1.6 - p.x * 1.2) + 11.3; a *= 0.5; }
	return s / 0.9375;
}`

NEBULA :: `
uniform float t;
uniform float4 rect;
uniform float3 deep;
uniform float3 mid;
uniform float3 hot;
uniform float scale;
uniform float detail;
uniform float level;
uniform float2 flow;
uniform float seed;
` + NOISE_SKSL + `
half4 main(float2 p) {
	float2 u = (p - rect.xy - 0.5 * rect.zw) / rect.w / scale + flow * t + seed * 7.31;
	float2 q = float2(fbm(u * 1.7 + float2(0, t * 0.05)), fbm(u * 1.7 + float2(5.2, 1.3 - t * 0.04)));
	float2 w = u * 1.4 + (q - 0.5) * 2.6;
	float f = fbm(w + float2(t * 0.02, 0));
	// ridges: bright where the noise crosses its middle
	float ridge = 1 - abs(2 * f - 1);
	float fil = pow(ridge, mix(2.5, 9.0, detail));
	float cloud = smoothstep(0.4, 0.95, f) * 0.3 + smoothstep(0.3, 1.0, q.x) * 0.12;
	float a = (cloud * 0.55 + fil * 0.9) * level;
	float3 col = deep + mid * a * (0.35 + 0.65 * q.y);
	col += hot * pow(fil, 3.0) * smoothstep(0.5, 0.85, q.x) * level * 0.6;
	return half4(half3(col), 1);
}`

// ---------------------------------------------------------------- orb

Orb :: struct {
	radius:  f32, // of the body, in px
	morph:   f32, // 0 = a sphere … 1 = restless
	spin:    f32, // turns of its surface pattern, in radians
	a, b, c: Color, // the film's colors across the fresnel
	glow:    f32, // halo strength, 0 = 0.6
	res:     f32, // render resolution, 0 = 0.5
}

// A raymarched body with an iridescent skin and a halo, centered in r (which
// should be square, about three times the radius wide). Transparent around it.
orb :: proc(r: Rect, t: f32, o: Orb) {
	a, b, cc := rgb3(o.a), rgb3(o.b), rgb3(o.c)
	k := clamp(o.res > 0 ? o.res : 0.5, 0.05, 1)
	w, h := i32(math.ceil(r.w * k * S.scale)), i32(math.ceil(r.h * k * S.scale))
	s := sk.surface_raster(max(w, 1), max(h, 1))
	defer sk.surface_free(s)
	cv := sk.surface_canvas(s)
	sk.canvas_scale(cv, f32(w) / r.w, f32(h) / r.h)
	sk.canvas_translate(cv, -r.x, -r.y)
	u := [?]f32{t, r.x, r.y, r.w, r.h, o.radius, o.morph, o.spin, a.r, a.g, a.b, b.r, b.g, b.b, cc.r, cc.g, cc.b, o.glow > 0 ? o.glow : 0.6}
	err: [512]u8
	if !sk.canvas_draw_sksl(cv, ORB, &u[0], len(u), r.x, r.y, r.w, r.h, &err[0], len(err)) {
		fmt.eprintln("fx: shader:", cstring(&err[0]))
	}
	img := sk.surface_snapshot(s)
	defer sk.image_free(img)
	sk.canvas_draw_image(S.cv, img, nil, r.x, r.y, r.w, r.h, 1)
}

ORB :: `
uniform float t;
uniform float4 rect;
uniform float radius;
uniform float morph;
uniform float spin;
uniform float3 ca;
uniform float3 cb;
uniform float3 cc;
uniform float glow;
float map(float3 p) {
	float d = length(p) - 1.0;
	float3 q = p * 2.3 + float3(0, t * 0.6, spin);
	d += morph * 0.16 * (sin(q.x + sin(q.z * 1.3 + t)) * sin(q.y + sin(q.x * 1.1 - t * 0.7)) * sin(q.z + sin(q.y * 1.2)));
	d += morph * 0.035 * sin(p.x * 9 + t * 2) * sin(p.y * 9 - t * 1.6) * sin(p.z * 9);
	return d * 0.75;
}
half4 main(float2 fc) {
	float2 u = (fc - rect.xy - 0.5 * rect.zw) / radius;
	float3 ro = float3(0, 0, -4.2);
	float3 rd = normalize(float3(u, 4.0));
	float d = 2.6;
	float near = 10;
	float m = 1;
	for (int i = 0; i < 34; i++) {
		m = map(ro + rd * d);
		near = min(near, m);
		d += max(m, 0.004);
	}
	float hit = smoothstep(0.03, 0.0, m);
	float3 p = ro + rd * d;
	float2 e = float2(0.004, 0);
	float3 n = normalize(float3(map(p + e.xyy) - map(p - e.xyy), map(p + e.yxy) - map(p - e.yxy), map(p + e.yyx) - map(p - e.yyx)));
	float fres = pow(1 - clamp(dot(n, -rd), 0, 1), 2.2);
	float band = fres * 1.6 + 0.25 * sin(n.y * 3 + t * 0.9 + spin) + 0.18 * n.x;
	float3 film = mix(ca, cb, smoothstep(0.15, 0.75, band));
	film = mix(film, cc, smoothstep(0.7, 1.35, band));
	float3 l = normalize(float3(-0.5, 0.7, -0.6));
	float diff = clamp(dot(n, l), 0, 1);
	float spec = pow(clamp(dot(reflect(rd, n), l), 0, 1), 28);
	float3 body = film * (0.10 + 0.5 * diff + 1.25 * fres) + spec * 0.9 + 0.03;
	float halo = glow * 0.045 / (0.05 + max(near, 0) * max(near, 0) * 9.0);
	float3 hc = mix(ca, cb, 0.4) * halo;
	float3 col = mix(hc, body, hit);
	float a = clamp(max(hit, halo * 1.4), 0, 1);
	// fade the halo out before the rect's edge
	float edge = smoothstep(0.5, 0.36, length((fc - rect.xy - 0.5 * rect.zw) / rect.zw));
	a *= mix(edge, 1, hit);
	return half4(half3(col) * half(mix(edge, 1, hit)), half(a));
}`

// ---------------------------------------------------------------- tunnel

// An endless tunnel of rings and ribs flying toward the viewer, in color on
// black. speed in rings per second, twist in turns along its length.
tunnel :: proc(r: Rect, t: f32, color, accent: Color, speed: f32 = 1, twist: f32 = 0.15, ribs: f32 = 12, res: f32 = 0.5) {
	a, b := rgb3(color), rgb3(accent)
	shader_scaled(TUNNEL, r, res, t, r.x, r.y, r.w, r.h, a.r, a.g, a.b, b.r, b.g, b.b, speed, twist, ribs)
}

TUNNEL :: `
uniform float t;
uniform float4 rect;
uniform float3 ca;
uniform float3 cb;
uniform float speed;
uniform float twist;
uniform float ribs;
half4 main(float2 p) {
	float2 u = (p - rect.xy - 0.5 * rect.zw) / rect.w;
	float r = length(u) + 1e-4;
	float d = 0.5 / r;
	float a = atan(u.y, u.x) / 6.2831853 + twist * d + t * 0.02;
	float zz = d * 1.5 + t * speed;
	// thin lines where the walls' cells meet, wider (in cells) far away so they stay visible
	float lw = 0.035 + 0.02 * d;
	float ring = 1 - smoothstep(0.0, lw, abs(fract(zz) - 0.5));
	float rib = 1 - smoothstep(0.0, lw * 0.7, abs(fract(a * ribs) - 0.5));
	float cell = fract(sin(dot(floor(float2(zz + 0.5, a * ribs + 0.5)), float2(12.9898, 78.233))) * 43758.5453);
	float lit = step(0.84, cell) * (0.35 + 0.65 * (0.5 + 0.5 * sin(t * 7 + cell * 40)));
	float fog = smoothstep(0.03, 0.4, r);
	float3 col = ca * (ring * 1.1 + rib * 0.55) * (0.5 + 1.2 * r) + cb * lit * 0.34 * (0.4 + r);
	col *= fog;
	col += cb * 0.5 * exp(-r * 11.0);
	return half4(half3(col), 1);
}`
