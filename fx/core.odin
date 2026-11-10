// fx: a library for drawing videos as pure functions of time on a Skia canvas.
//
// Everything draws into the current thread's frame (set up by the renderer
// before a video's scenes run), so scene code reads like immediate-mode UI:
// call fx.rect, fx.text, fx.box … with values computed from t.
package fx

import "core:math"
import sk "../sk"

Vec2 :: [2]f32
Color :: u32 // 0xAARRGGBB

Rect :: struct {
	x, y, w, h: f32,
}

// Per-thread state of the frame being drawn.
Frame_State :: struct {
	cv:      ^sk.Canvas,
	t:       f32,
	w, h:    f32,
	preview: bool, // drawn by the editor, not a final render
	scale:   f32, // device pixels per stage pixel
	video:   ^Video,
	groups:  [dynamic]Group_Entry,
}

@(thread_local)
S: Frame_State

canvas :: proc() -> ^sk.Canvas {return S.cv}
now :: proc() -> f32 {return S.t}
stage :: proc() -> Rect {return {0, 0, S.w, S.h}}

// ---------------------------------------------------------------- rects

inset :: proc(r: Rect, d: f32) -> Rect {return {r.x + d, r.y + d, r.w - 2 * d, r.h - 2 * d}}
inset4 :: proc(r: Rect, top, right, bottom, left: f32) -> Rect {
	return {r.x + left, r.y + top, r.w - left - right, r.h - top - bottom}
}
center :: proc(r: Rect) -> Vec2 {return {r.x + r.w / 2, r.y + r.h / 2}}
contains :: proc(r: Rect, p: Vec2) -> bool {return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h}
lerp_rect :: proc(a, b: Rect, p: f32) -> Rect {
	return {lerp(a.x, b.x, p), lerp(a.y, b.y, p), lerp(a.w, b.w, p), lerp(a.h, b.h, p)}
}
// Fits an aw×ah box into r keeping its aspect ratio, centered (CSS object-fit: contain).
contain :: proc(r: Rect, aw, ah: f32) -> Rect {
	s := min(r.w / aw, r.h / ah)
	return {r.x + (r.w - aw * s) / 2, r.y + (r.h - ah * s) / 2, aw * s, ah * s}
}

// ---------------------------------------------------------------- colors

// 0xRRGGBB → opaque color.
rgb :: proc "contextless" (hex: u32) -> Color {return 0xff000000 | hex}
// Color with its alpha multiplied by a.
alpha :: proc(c: Color, a: f32) -> Color {
	ca := f32(c >> 24) * clamp01(a)
	return u32(ca + 0.5) << 24 | (c & 0xffffff)
}
// Color with alpha replaced by a (0..1).
with_alpha :: proc(c: Color, a: f32) -> Color {return u32(clamp01(a) * 255 + 0.5) << 24 | (c & 0xffffff)}
mix :: proc(a, b: Color, p: f32) -> Color {
	p := clamp01(p)
	ch :: proc(a, b: Color, shift: u32, p: f32) -> u32 {
		x := f32((a >> shift) & 0xff)
		y := f32((b >> shift) & 0xff)
		return u32(x + (y - x) * p + 0.5) << shift
	}
	return ch(a, b, 24, p) | ch(a, b, 16, p) | ch(a, b, 8, p) | ch(a, b, 0, p)
}

// ---------------------------------------------------------------- 3D

// Row-major 4×4 for a CSS-like perspective tilt around origin: rotate rx, ry
// (degrees) seen from distance persp.
tilt_matrix :: proc(origin: Vec2, rx, ry, rz, persp: f32) -> [16]f32 {
	M :: matrix[4, 4]f32
	translate :: proc(x, y: f32) -> M {return {1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, 0, 0, 0, 0, 1}}
	ax, ay, az := rx * math.RAD_PER_DEG, ry * math.RAD_PER_DEG, rz * math.RAD_PER_DEG
	cx, sx := math.cos(ax), math.sin(ax)
	cy, sy := math.cos(ay), math.sin(ay)
	cz, sz := math.cos(az), math.sin(az)
	rot_x := M{1, 0, 0, 0, 0, cx, -sx, 0, 0, sx, cx, 0, 0, 0, 0, 1}
	rot_y := M{cy, 0, sy, 0, 0, 1, 0, 0, -sy, 0, cy, 0, 0, 0, 0, 1}
	rot_z := M{cz, -sz, 0, 0, sz, cz, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	p := persp > 0 ? persp : 1600
	perspective := M{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -1 / p, 1}
	m := translate(origin.x, origin.y) * perspective * rot_x * rot_y * rot_z * translate(-origin.x, -origin.y)
	out: [16]f32
	for r in 0 ..< 4 do for c in 0 ..< 4 do out[r * 4 + c] = m[r, c]
	return out
}
