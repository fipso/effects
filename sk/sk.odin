// Bindings for shim/sk.h. See there for semantics.
package sk

import "core:c"

foreign import lib "system:skshim"

Surface :: struct {}
Canvas :: struct {}
Path :: struct {}
Image :: struct {}
Text :: struct {}
Gpu :: struct {}

Shader :: enum i32 {
	None   = 0,
	Linear = 1,
	Radial = 2,
	Sweep  = 3,
}

MAX_STOPS :: 8

Paint :: struct {
	color:       u32, // 0xAARRGGBB; with a shader only its alpha is used
	stroke:      f32, // 0 = fill
	blur:        f32, // mask blur sigma
	shader:      Shader,
	sh:          [4]f32, // linear: x0 y0 x1 y1 · radial: cx cy r · sweep: cx cy
	stops:       i32,
	stop_colors: [MAX_STOPS]u32,
	stop_pos:    [MAX_STOPS]f32, // all 0 = evenly spaced
	dash:        [2]f32,
	trim:        [2]f32,
	blend:       i32, // Blend + 1, 0 = src-over
	square_cap:  b32,
}

Blend :: enum i32 {
	Clear, Src, Dst, Src_Over, Dst_Over, Src_In, Dst_In, Src_Out, Dst_Out, Src_Atop, Dst_Atop, Xor,
	Plus, Modulate, Screen, Overlay, Darken, Lighten, Color_Dodge, Color_Burn, Hard_Light, Soft_Light,
	Difference, Exclusion, Multiply, Hue, Saturation, Color, Luminosity,
}

Layer :: struct {
	bounds:        [4]f32, // x y w h, w or h <= 0 = whole canvas
	alpha:         f32,
	blur:          f32,
	gray:          f32,
	bright:        f32,
	backdrop_blur: f32,
	blur_xy:       [2]f32, // directional (motion) blur sigma
	blend:         i32, // Blend + 1, 0 = src-over
	has_matrix:    b32,
	colors:        [20]f32, // color matrix (C: matrix): 4×5 row-major, offsets in 0..1
	sksl:          cstring, // image filter; `uniform shader src;` is the layer's content
	uniforms:      [^]f32,
	n_uniforms:    i32,
	sksl_radius:   f32,
	glow:          [4]f32, // sigma_x, sigma_y, threshold, gain: bright parts blurred and added back
	glow2:         [4]f32, // a second pass (streaks)
}

Text_Style :: struct {
	family:      cstring,
	size:        f32,
	weight:      f32,
	tracking:    f32, // px
	line_height: f32, // multiple of size, 0 = font default
	align:       i32, // 0 left, 1 center, 2 right
	tabular:     b32,
	italic:      b32,
	max_lines:   i32,
	underline:   b32,
}

Text_Metrics :: struct {
	width:         f32,
	height:        f32,
	baseline:      f32,
	max_intrinsic: f32,
	lines:         i32,
}

Gl_Get_Proc :: #type proc "c" (ctx: rawptr, name: cstring) -> rawptr

@(default_calling_convention = "c", link_prefix = "sk_")
foreign lib {
	surface_raster :: proc(w, h: i32) -> ^Surface ---
	surface_free :: proc(s: ^Surface) ---
	surface_canvas :: proc(s: ^Surface) -> ^Canvas ---
	surface_pixels :: proc(s: ^Surface, row_bytes: ^c.size_t) -> rawptr ---
	surface_snapshot :: proc(s: ^Surface) -> ^Image ---
	surface_write_png :: proc(s: ^Surface, path: cstring) -> b32 ---

	canvas_clear :: proc(cv: ^Canvas, argb: u32) ---
	canvas_save :: proc(cv: ^Canvas) -> i32 ---
	canvas_save_layer :: proc(cv: ^Canvas, l: ^Layer) -> i32 ---
	canvas_restore :: proc(cv: ^Canvas) ---
	canvas_restore_to :: proc(cv: ^Canvas, count: i32) ---
	canvas_translate :: proc(cv: ^Canvas, x, y: f32) ---
	canvas_scale :: proc(cv: ^Canvas, sx, sy: f32) ---
	canvas_rotate :: proc(cv: ^Canvas, degrees: f32) ---
	canvas_concat44 :: proc(cv: ^Canvas, m: ^[16]f32) ---
	canvas_map_rect :: proc(cv: ^Canvas, in_: ^[4]f32, out: ^[4]f32) ---
	canvas_clip_rect :: proc(cv: ^Canvas, x, y, w, h: f32) ---
	canvas_clip_rrect :: proc(cv: ^Canvas, x, y, w, h, r: f32) ---
	canvas_clip_path :: proc(cv: ^Canvas, p: ^Path) ---

	canvas_draw_paint :: proc(cv: ^Canvas, p: ^Paint) ---
	canvas_draw_rect :: proc(cv: ^Canvas, x, y, w, h: f32, p: ^Paint) ---
	canvas_draw_rrect :: proc(cv: ^Canvas, x, y, w, h: f32, radii: ^[4]f32, p: ^Paint) ---
	canvas_draw_circle :: proc(cv: ^Canvas, cx, cy, r: f32, p: ^Paint) ---
	canvas_draw_oval :: proc(cv: ^Canvas, x, y, w, h: f32, p: ^Paint) ---
	canvas_draw_line :: proc(cv: ^Canvas, x0, y0, x1, y1: f32, p: ^Paint) ---
	canvas_draw_path :: proc(cv: ^Canvas, path: ^Path, p: ^Paint) ---
	canvas_draw_shadow :: proc(cv: ^Canvas, x, y, w, h, r, dx, dy, blur, spread: f32, color: u32) ---

	path_new :: proc() -> ^Path ---
	path_from_svg :: proc(d: cstring) -> ^Path ---
	path_free :: proc(p: ^Path) ---
	path_move_to :: proc(p: ^Path, x, y: f32) ---
	path_line_to :: proc(p: ^Path, x, y: f32) ---
	path_quad_to :: proc(p: ^Path, x1, y1, x2, y2: f32) ---
	path_cubic_to :: proc(p: ^Path, x1, y1, x2, y2, x3, y3: f32) ---
	path_close :: proc(p: ^Path) ---
	path_add_rrect :: proc(p: ^Path, x, y, w, h, r: f32) ---
	path_add_circle :: proc(p: ^Path, cx, cy, r: f32) ---
	path_bounds :: proc(p: ^Path, out: ^[4]f32) ---
	path_length :: proc(p: ^Path) -> f32 ---

	image_from_file :: proc(path: cstring) -> ^Image ---
	image_free :: proc(i: ^Image) ---
	image_size :: proc(i: ^Image, w, h: ^i32) ---
	image_from_pixels :: proc(bgra: rawptr, w, h: i32, row_bytes: c.size_t) -> ^Image ---
	canvas_draw_image_tiled :: proc(cv: ^Canvas, i: ^Image, x, y, w, h, dx, dy, alpha: f32, blend: i32) ---
	canvas_draw_image :: proc(cv: ^Canvas, i: ^Image, src: ^[4]f32, x, y, w, h, alpha: f32) ---

	font_register :: proc(family: cstring, path: cstring) -> b32 ---
	text_layout :: proc(utf8: [^]u8, len: c.size_t, st: ^Text_Style, max_width: f32) -> ^Text ---
	text_get_metrics :: proc(t: ^Text, out: ^Text_Metrics) ---
	text_draw :: proc(cv: ^Canvas, t: ^Text, x, y: f32, p: ^Paint) ---
	frame_end :: proc() ---

	canvas_draw_sksl :: proc(cv: ^Canvas, sksl: cstring, uniforms: [^]f32, n: c.size_t, x, y, w, h: f32, err: [^]u8, err_len: c.size_t) -> b32 ---

	gpu_new_gl :: proc(get: Gl_Get_Proc, ctx: rawptr) -> ^Gpu ---
	gpu_free :: proc(g: ^Gpu) ---
	gpu_window_surface :: proc(g: ^Gpu, w, h, samples, stencil: i32) -> ^Surface ---
	gpu_offscreen :: proc(g: ^Gpu, w, h: i32) -> ^Surface ---
	gpu_flush :: proc(g: ^Gpu) ---
}
