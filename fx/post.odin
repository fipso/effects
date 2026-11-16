// Post effects: color grading and pixel filters over what a group draws.
//
//   if fx.group({contrast = 0.5, sat = 0, post = fx.rgb_split(8)}) { … }
//
// Grading is a color matrix (cheap anywhere); posts are SkSL image filters
// that read the group's pixels through `uniform shader src;`. Uniforms are in
// stage pixels. On the CPU every post costs a full pass per sample it reads,
// so keep them to the frames that need them.
package fx

import "core:math"

Post :: struct {
	sksl:   cstring,
	u:      [16]f32, // uniforms in declaration order
	n:      int,
	radius: f32, // how far it samples away from a pixel, in px
}

// Any SkSL image filter: `uniform shader src;` plus float uniforms.
post :: proc(sksl: cstring, radius: f32, uniforms: ..f32) -> Post {
	p := Post{sksl = sksl, radius = radius, n = min(len(uniforms), 16)}
	copy(p.u[:], uniforms)
	return p
}

// Red and blue pulled apart by px along angle (degrees): chromatic aberration.
rgb_split :: proc(px: f32, angle: f32 = 0) -> Post {
	if px < 0.05 do return {}
	a := angle * math.RAD_PER_DEG
	return post(RGB_SPLIT, px, math.cos(a) * px, math.sin(a) * px)
}

RGB_SPLIT :: `
uniform shader src;
uniform float2 d;
half4 main(float2 p) {
	half4 a = src.eval(p - d);
	half4 b = src.eval(p);
	half4 c = src.eval(p + d);
	return half4(a.r, b.g, c.b, max(b.a, max(a.a, c.a)));
}`

// Digital glitch: horizontal slices shoved sideways plus a color split,
// re-rolled 24 times a second. amount 0..1.
glitch :: proc(amount: f32, seed: f32 = 0) -> Post {
	if amount < 0.01 do return {}
	tick := math.floor(S.t * 24) + seed * 101
	return post(GLITCH, S.w * 0.12 * amount + 24 * amount, tick, amount, S.w, S.h)
}

GLITCH :: `
uniform shader src;
uniform float tick;
uniform float amount;
uniform float2 size;
float h(float n) { return fract(sin(n * 12.9898 + 4.1414) * 43758.5453); }
half4 main(float2 p) {
	float rows = 6 + floor(h(tick) * 18);
	float band = floor(p.y / size.y * rows);
	float r = h(band * 1.37 + tick * 7.13);
	float shove = r > 1 - amount * 0.6 ? (h(band * 3.1 + tick) - 0.5) * size.x * 0.12 * amount : 0;
	float2 q = p + float2(shove, 0);
	float d = 24 * amount * (0.4 + h(tick * 1.7));
	half4 a = src.eval(q - float2(d, 0));
	half4 b = src.eval(q);
	half4 c = src.eval(q + float2(d, 0));
	return half4(a.r, b.g, c.b, b.a);
}`

// Radial blur toward center: the rush of a zoom. amount 0..1 is how far
// along the ray it smears (0.15 is a lot).
zoom_blur :: proc(center: Vec2, amount: f32) -> Post {
	if amount < 0.002 do return {}
	return post(ZOOM_BLUR, S.w * amount, center.x, center.y, amount)
}

ZOOM_BLUR :: `
uniform shader src;
uniform float2 c;
uniform float k;
half4 main(float2 p) {
	half4 acc = half4(0);
	for (int i = 0; i < 12; i++) {
		float s = 1 - k * float(i) / 11;
		acc += src.eval(c + (p - c) * s);
	}
	return acc / 12;
}`

// Big square pixels of size px.
pixelate :: proc(px: f32) -> Post {
	if px < 1.5 do return {}
	return post(PIXELATE, px, px)
}

PIXELATE :: `
uniform shader src;
uniform float s;
half4 main(float2 p) { return src.eval((floor(p / s) + 0.5) * s); }`

// Maps brightness onto a gradient from dark to light (keeps alpha).
duotone :: proc(dark, light: Color) -> Post {
	d, l := unpack(dark), unpack(light)
	return post(DUOTONE, 0, d.r, d.g, d.b, l.r, l.g, l.b)
}

DUOTONE :: `
uniform shader src;
uniform float3 dark;
uniform float3 light;
half4 main(float2 p) {
	half4 c = src.eval(p);
	if (c.a <= 0) return c;
	half l = dot(c.rgb / c.a, half3(0.2126, 0.7152, 0.0722));
	return half4(mix(half3(dark), half3(light), l) * c.a, c.a);
}`

// Horizontal scanlines every px pixels, darkening by amount.
scanlines :: proc(px: f32 = 4, amount: f32 = 0.25) -> Post {
	return post(SCANLINES, 0, px, amount)
}

SCANLINES :: `
uniform shader src;
uniform float s;
uniform float k;
half4 main(float2 p) {
	half4 c = src.eval(p);
	float w = 0.5 + 0.5 * cos(6.2831853 * p.y / s);
	return half4(c.rgb * (1 - k * w), c.a);
}`

// Print-style halftone: a grid of dots cell px apart, turned by angle
// (degrees), each as big as the brightness under it and in its color at
// full strength, on black. amount 0..1 blends in from the picture.
halftone :: proc(cell: f32, angle: f32 = 45, amount: f32 = 1) -> Post {
	if cell < 2 || amount < 0.01 do return {}
	a := angle * math.RAD_PER_DEG
	return post(HALFTONE, cell, cell, math.cos(a), math.sin(a), min(amount, 1))
}

HALFTONE :: `
uniform shader src;
uniform float cell;
uniform float2 rot;
uniform float amount;
half4 main(float2 p) {
	float2 q = float2(rot.x * p.x + rot.y * p.y, rot.x * p.y - rot.y * p.x);
	float2 g = (floor(q / cell) + 0.5) * cell;
	half4 s = src.eval(float2(rot.x * g.x - rot.y * g.y, rot.y * g.x + rot.x * g.y));
	half l = dot(s.rgb, half3(0.2126, 0.7152, 0.0722));
	half top = max(max(s.r, s.g), max(s.b, 0.04));
	float m = clamp(cell * 0.7071 * sqrt(l) - length(q - g) + 0.5, 0, 1);
	half4 dots = half4(s.rgb / top * m, s.a);
	return amount >= 1 ? dots : mix(src.eval(p), dots, amount);
}`

// Ordered dither (8×8 Bayer) in px-sized pixels: the brightness cut down
// to levels shades between dark and light (2 = 1-bit). amount 0..1 blends
// in from the picture.
dither :: proc(px: f32 = 2, dark: Color = 0xff000000, light: Color = 0xffffffff, levels: f32 = 2, amount: f32 = 1) -> Post {
	if amount < 0.01 do return {}
	d, l := unpack(dark), unpack(light)
	return post(DITHER, px, max(px, 1), max(levels, 2) - 1, min(amount, 1), d.r, d.g, d.b, l.r, l.g, l.b)
}

DITHER :: `
uniform shader src;
uniform float px;
uniform float n;
uniform float amount;
uniform float3 dark;
uniform float3 light;
float b2(float2 a) { a = floor(a); return fract(a.x * 0.5 + a.y * a.y * 0.75); }
float b8(float2 a) { return (b2(a * 0.25) * 0.25 + b2(a * 0.5)) * 0.25 + b2(a); }
half4 main(float2 p) {
	float2 g = floor(p / px);
	half4 s = src.eval((g + 0.5) * px);
	half l = dot(s.rgb, half3(0.2126, 0.7152, 0.0722));
	half k = clamp(floor(l * n + b8(g)) / n, 0, 1);
	half4 d = half4(mix(half3(dark), half3(light), k) * s.a, s.a);
	return amount >= 1 ? d : mix(src.eval(p), d, amount);
}`

// ---------------------------------------------------------------- glow

// Bloom for a group: what is brighter than threshold is blurred by radius
// and added back, amount strong. streak adds a second, wide horizontal blur
// (an anamorphic lens flare) at streak_amount of amount. Runs after the
// group's blur and post; made of Skia's own blur, so cheap on the CPU. Best
// on a group that paints its own background (the glow adds alpha too).
Glow :: struct {
	radius:        f32, // blur sigma in px
	amount:        f32, // 0 = off; 1 adds the blurred highlights at full strength
	threshold:     f32, // 0..1: only what is brighter glows
	streak:        f32, // horizontal sigma of the streak pass, 0 = none
	streak_amount: f32, // of amount, default 0.6
}

glow :: proc(radius: f32 = 24, amount: f32 = 0.8, threshold: f32 = 0.5, streak: f32 = 0) -> Glow {
	return {radius = radius, amount = amount, threshold = threshold, streak = streak}
}

// ---------------------------------------------------------------- lenses

// A lens over the group: barrel distortion (distort > 0 bulges, < 0
// pinches), colors pulled apart toward the edges by chroma px at the
// corners, and the edges darkened by vignette (0..1).
lens :: proc(distort: f32 = 0.06, chroma: f32 = 6, vignette: f32 = 0) -> Post {
	if abs(distort) < 0.001 && chroma < 0.05 && vignette < 0.005 do return {}
	return post(LENS, abs(distort) * S.w * 0.5 + chroma, S.w, S.h, distort, chroma, vignette)
}

LENS :: `
uniform shader src;
uniform float2 size;
uniform float k;
uniform float chroma;
uniform float vig;
half4 main(float2 p) {
	float2 c = size * 0.5;
	float2 u = (p - c) / c.y;
	float r2 = dot(u, u);
	// the corners stay where they are and the middle comes closer (or, pinching, the other way round)
	float corner = (c.x * c.x) / (c.y * c.y) + 1;
	float2 q = c + u * (1 + k * (r2 - (k > 0 ? corner : 0))) * c.y;
	float2 d = normalize(u + 1e-5) * chroma * r2 * 0.3;
	half4 a = src.eval(q - d);
	half4 b = src.eval(q);
	half4 e = src.eval(q + d);
	half3 col = half3(a.r, b.g, e.b);
	col *= half(1 - vig * smoothstep(0.3, 2.6, r2));
	return half4(col, b.a);
}`

// A ring-shaped ripple pushing pixels outward: the shock of an impact.
// radius and width in px, strength in px at the crest.
shockwave :: proc(center: Vec2, radius, width, strength: f32) -> Post {
	if abs(strength) < 0.05 || radius <= 0 do return {}
	return post(SHOCKWAVE, abs(strength), center.x, center.y, radius, max(width, 1), strength)
}

SHOCKWAVE :: `
uniform shader src;
uniform float2 c;
uniform float radius;
uniform float width;
uniform float strength;
half4 main(float2 p) {
	float2 v = p - c;
	float d = length(v);
	float x = (d - radius) / width;
	float w = exp(-x * x) * strength;
	float2 n = v / max(d, 1e-3);
	half4 a = src.eval(p - n * w * 1.25);
	half4 b = src.eval(p - n * w);
	half4 e = src.eval(p - n * w * 0.75);
	return half4(a.r, b.g, e.b, b.a) * half(1 + 0.6 * exp(-x * x) * min(abs(strength) / 40, 1));
}`

// The group folded into n mirrored wedges around center, turned by angle
// (degrees): a kaleidoscope.
kaleido :: proc(center: Vec2, n: f32 = 6, angle: f32 = 0, zoom: f32 = 1) -> Post {
	if n < 1 do return {}
	return post(KALEIDO, max(S.w, S.h), center.x, center.y, n, angle * math.RAD_PER_DEG, zoom, S.w, S.h)
}

KALEIDO :: `
uniform shader src;
uniform float2 c;
uniform float n;
uniform float rot;
uniform float zoom;
uniform float2 size;
half4 main(float2 p) {
	float2 v = (p - c) / zoom;
	float r = length(v);
	float seg = 3.14159265 / n;
	float a = atan(v.y, v.x) + rot;
	a = abs(mod(a, 2 * seg) - seg);
	float2 q = c + r * float2(cos(a - rot), sin(a - rot));
	// fold back what leaves the stage, so the wedges are always full
	q = abs(q);
	q = size - abs(size - q);
	return src.eval(q);
}`

// Pixels pushed around by flowing noise: heat haze, liquid, a melting
// picture. amount in px, scale the size of the swirls in px.
warp :: proc(amount: f32, scale: f32 = 240, speed: f32 = 0.4, seed: f32 = 0) -> Post {
	if abs(amount) < 0.05 do return {}
	return post(WARP, abs(amount), amount, max(scale, 1), S.t * speed + seed * 37)
}

WARP :: `
uniform shader src;
uniform float amount;
uniform float scale;
uniform float t;
float h(float2 p) { p = fract(p * float2(0.1031, 0.1030)); p += dot(p, p.yx + 33.33); return fract((p.x + p.y) * p.x); }
float n(float2 p) {
	float2 i = floor(p), f = fract(p);
	f = f * f * (3 - 2 * f);
	return mix(mix(h(i), h(i + float2(1, 0)), f.x), mix(h(i + float2(0, 1)), h(i + float2(1, 1)), f.x), f.y);
}
half4 main(float2 p) {
	float2 q = p / scale;
	float2 d = float2(n(q + float2(t, 0)) + 0.5 * n(q * 2.1 - t), n(q + float2(5.2, t * 0.9)) + 0.5 * n(q * 2.1 + t + 3.1)) - 0.75;
	return src.eval(p + d * amount * 1.33);
}`

// Everything right of (or, with a negative width, left of) edge is the
// column of pixels at the edge, smeared: a stretched frame.
stretch :: proc(edge: f32, horizontal := true, forward := true) -> Post {
	return post(STRETCH, max(S.w, S.h), edge, horizontal ? 1 : 0, forward ? 1 : -1)
}

STRETCH :: `
uniform shader src;
uniform float edge;
uniform float horiz;
uniform float dir;
half4 main(float2 p) {
	float2 q = p;
	if (horiz > 0.5) { q.x = dir > 0 ? min(p.x, edge) : max(p.x, edge); }
	else { q.y = dir > 0 ? min(p.y, edge) : max(p.y, edge); }
	return src.eval(q);
}`

// ---------------------------------------------------------------- grading

RGBA :: struct {
	r, g, b, a: f32,
}

unpack :: proc(c: Color) -> RGBA {
	return {f32((c >> 16) & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32(c & 0xff) / 255, f32(c >> 24) / 255}
}

Matrix5 :: matrix[5, 5]f32

// The color matrix for an Xf's grade (gray, bright, contrast, sat, tint,
// invert), row-major 4×5; false when it changes nothing.
grade_matrix :: proc(xf: Xf) -> (out: [20]f32, ok: bool) {
	sat := (xf.sat.? or_else 1) * (1 - clamp01(xf.gray))
	bright := xf.bright > 0 ? xf.bright : 1
	if sat == 1 && bright == 1 && xf.contrast == 0 && xf.tint == 0 && xf.invert == 0 do return
	m: Matrix5 = 1
	if sat != 1 {
		LR, LG, LB :: 0.2126, 0.7152, 0.0722
		q := 1 - sat
		m = Matrix5 {
			LR * q + sat, LG * q, LB * q, 0, 0,
			LR * q, LG * q + sat, LB * q, 0, 0,
			LR * q, LG * q, LB * q + sat, 0, 0,
			0, 0, 0, 1, 0,
			0, 0, 0, 0, 1,
		} * m
	}
	if bright != 1 {
		m = Matrix5{bright, 0, 0, 0, 0, 0, bright, 0, 0, 0, 0, 0, bright, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1} * m
	}
	if xf.contrast != 0 {
		f := 1 + xf.contrast
		o := 0.5 * (1 - f)
		m = Matrix5{f, 0, 0, 0, o, 0, f, 0, 0, o, 0, 0, f, 0, o, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1} * m
	}
	if xf.tint != 0 {
		c := unpack(xf.tint)
		m = Matrix5{c.r, 0, 0, 0, 0, 0, c.g, 0, 0, 0, 0, 0, c.b, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1} * m
	}
	if xf.invert != 0 {
		a := clamp01(xf.invert)
		f := 1 - 2 * a
		m = Matrix5{f, 0, 0, 0, a, 0, f, 0, 0, a, 0, 0, f, 0, a, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1} * m
	}
	for r in 0 ..< 4 do for c in 0 ..< 5 do out[r * 5 + c] = m[r, c]
	return out, true
}
