// Immediate drawing on the current frame's canvas: shapes, text, icons,
// images, and groups that move, scale, tilt, fade or blur what they contain.
package fx

import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import sk "../sk"

// ---------------------------------------------------------------- paints

fill :: proc(c: Color) -> sk.Paint {return {color = c}}
stroke :: proc(c: Color, w: f32 = 1) -> sk.Paint {return {color = c, stroke = w}}

Stop :: struct {
	c:  Color,
	at: f32,
}

// Linear gradient from a to b through evenly spaced colors (2..8).
linear :: proc(a, b: Vec2, colors: ..Color) -> sk.Paint {
	p := sk.Paint{color = 0xff000000, shader = .Linear, sh = {a.x, a.y, b.x, b.y}}
	set_stops(&p, colors)
	return p
}
radial :: proc(center: Vec2, r: f32, colors: ..Color) -> sk.Paint {
	p := sk.Paint{color = 0xff000000, shader = .Radial, sh = {center.x, center.y, r, 0}}
	set_stops(&p, colors)
	return p
}
// Gradient with explicit stop positions.
with_stops :: proc(p: sk.Paint, stops: ..Stop) -> sk.Paint {
	p := p
	p.stops = i32(min(len(stops), sk.MAX_STOPS))
	for s, i in stops[:p.stops] do p.stop_colors[i], p.stop_pos[i] = s.c, s.at
	return p
}
@(private)
set_stops :: proc(p: ^sk.Paint, colors: []Color) {
	p.stops = i32(min(len(colors), sk.MAX_STOPS))
	for c, i in colors[:p.stops] do p.stop_colors[i] = c
}

// ---------------------------------------------------------------- shapes

rect :: proc(r: Rect, c: Color) {
	p := fill(c)
	sk.canvas_draw_rect(S.cv, r.x, r.y, r.w, r.h, &p)
}
rect_paint :: proc(r: Rect, p: sk.Paint) {
	p := p
	sk.canvas_draw_rect(S.cv, r.x, r.y, r.w, r.h, &p)
}
rrect :: proc(r: Rect, radius: f32, c: Color) {
	p := fill(c)
	rrect_paint(r, radius, p)
}
rrect_paint :: proc(r: Rect, radius: f32, p: sk.Paint) {
	p := p
	radii := [4]f32{radius, radius, radius, radius}
	sk.canvas_draw_rrect(S.cv, r.x, r.y, r.w, r.h, &radii, &p)
}
// Rounded rect with each corner's radius: top-left, top-right, bottom-right, bottom-left.
rrect4 :: proc(r: Rect, radii: [4]f32, p: sk.Paint) {
	p, radii := p, radii
	sk.canvas_draw_rrect(S.cv, r.x, r.y, r.w, r.h, &radii, &p)
}
// A border drawn inside r, like CSS box-sizing: border-box.
border :: proc(r: Rect, c: Color, width: f32 = 1, radius: f32 = 0) {
	p := sk.Paint{color = c, stroke = width, square_cap = true}
	h := width / 2
	radii := [4]f32{max(radius - h, 0), max(radius - h, 0), max(radius - h, 0), max(radius - h, 0)}
	sk.canvas_draw_rrect(S.cv, r.x + h, r.y + h, r.w - width, r.h - width, &radii, &p)
}
hline :: proc(x, y, w: f32, c: Color, width: f32 = 1) {rect({x, y, w, width}, c)}
vline :: proc(x, y, h: f32, c: Color, width: f32 = 1) {rect({x, y, width, h}, c)}
line :: proc(a, b: Vec2, c: Color, width: f32 = 1) {
	p := stroke(c, width)
	sk.canvas_draw_line(S.cv, a.x, a.y, b.x, b.y, &p)
}
circle :: proc(center: Vec2, r: f32, c: Color) {
	p := fill(c)
	sk.canvas_draw_circle(S.cv, center.x, center.y, r, &p)
}
ring :: proc(center: Vec2, r: f32, c: Color, width: f32 = 1) {
	p := stroke(c, width)
	sk.canvas_draw_circle(S.cv, center.x, center.y, r, &p)
}
circle_paint :: proc(center: Vec2, r: f32, p: sk.Paint) {
	p := p
	sk.canvas_draw_circle(S.cv, center.x, center.y, r, &p)
}
// Soft shadow under a rounded rect, CSS box-shadow style.
shadow :: proc(r: Rect, radius: f32 = 0, dy: f32 = 20, blur: f32 = 40, spread: f32 = 0, c: Color = 0x40000000, dx: f32 = 0) {
	sk.canvas_draw_shadow(S.cv, r.x, r.y, r.w, r.h, radius, dx, dy, blur, spread, c)
}
draw_path :: proc(path: ^sk.Path, p: sk.Paint) {
	p := p
	sk.canvas_draw_path(S.cv, path, &p)
}
paint_all :: proc(p: sk.Paint) {
	p := p
	sk.canvas_draw_paint(S.cv, &p)
}

// ---------------------------------------------------------------- groups

Xf :: struct {
	x, y:     f32, // translate
	s:        Maybe(f32), // scale around origin
	sx, sy:   f32, // extra scale per axis around origin, 0 = 1 (squash and stretch)
	rot:      f32, // degrees around origin
	rx, ry:   f32, // 3D tilt in degrees around origin
	persp:    f32, // perspective distance for the tilt, default 1600
	origin:   Vec2,
	o:        Maybe(f32), // opacity
	blur:     f32, // gaussian blur sigma of the contents
	mblur:    Vec2, // directional blur sigma along x and y (motion blur)
	gray:     f32, // 0..1 desaturate
	bright:   f32, // brightness multiplier, 0 = unchanged
	contrast: f32, // 0 = unchanged, 0.5 = 50% more, negative flattens
	sat:      Maybe(f32), // saturation, 1 = unchanged, 0 = gray, 1.4 = vivid
	tint:     Color, // multiply the colors by this one, 0 = none
	invert:   f32, // 0..1
	blend:    Maybe(sk.Blend), // how the contents land on what is below
	post:     Post, // a filter over the contents' pixels: rgb_split, glitch, zoom_blur …
	clip:     Maybe(Rect), // clip contents to this rect (in the group's coordinates)
	radius:   f32, // corner radius of clip
	bounds:   Maybe(Rect), // hint for the layer size when fading or blurring
}

Group_Entry :: struct {
	count: i32,
}

// Draws what follows in its scope moved/scaled/faded per xf:
//   if fx.group({y = 40 * (1 - k), o = k}) { … }
// Returns false (and draws nothing) when fully transparent.
@(deferred_out = end_group)
group :: proc(xf: Xf) -> bool {
	return group_begin(xf)
}

// group without the automatic end; pair with end_group(true) when it returned true.
group_begin :: proc(xf: Xf) -> bool {
	o := xf.o.? or_else 1
	if o <= 0.002 do return false
	cv := S.cv
	count := sk.canvas_save(cv)
	if xf.x != 0 || xf.y != 0 do sk.canvas_translate(cv, xf.x, xf.y)
	if xf.rx != 0 || xf.ry != 0 {
		m := tilt_matrix(xf.origin, xf.rx, xf.ry, xf.rot, xf.persp)
		sk.canvas_concat44(cv, &m)
	} else if xf.rot != 0 {
		sk.canvas_translate(cv, xf.origin.x, xf.origin.y)
		sk.canvas_rotate(cv, xf.rot)
		sk.canvas_translate(cv, -xf.origin.x, -xf.origin.y)
	}
	s := xf.s.? or_else 1
	sx, sy := s * (xf.sx != 0 ? xf.sx : 1), s * (xf.sy != 0 ? xf.sy : 1)
	if sx != 1 || sy != 1 {
		sk.canvas_translate(cv, xf.origin.x, xf.origin.y)
		sk.canvas_scale(cv, sx, sy)
		sk.canvas_translate(cv, -xf.origin.x, -xf.origin.y)
	}
	if r, ok := xf.clip.?; ok {
		if xf.radius > 0 do sk.canvas_clip_rrect(cv, r.x, r.y, r.w, r.h, xf.radius)
		else do sk.canvas_clip_rect(cv, r.x, r.y, r.w, r.h)
	}
	m, graded := grade_matrix(xf)
	_, blended := xf.blend.?
	if o < 0.998 || xf.blur > 0.05 || xf.mblur.x > 0.05 || xf.mblur.y > 0.05 || graded || blended || xf.post.sksl != nil {
		l := sk.Layer{alpha = o, blur = xf.blur, blur_xy = xf.mblur, has_matrix = b32(graded), colors = m}
		if b, ok := xf.blend.?; ok do l.blend = i32(b) + 1
		post := xf.post
		if post.sksl != nil {
			l.sksl = post.sksl
			l.uniforms = &post.u[0]
			l.n_uniforms = i32(post.n)
			l.sksl_radius = post.radius
		}
		if b, ok := xf.bounds.?; ok {
			pad := xf.blur * 3 + max(xf.mblur.x, xf.mblur.y) * 3 + post.radius
			l.bounds = {b.x - pad, b.y - pad, b.w + 2 * pad, b.h + 2 * pad}
		}
		sk.canvas_save_layer(cv, &l)
	}
	append(&S.groups, Group_Entry{count})
	return true
}

end_group :: proc(ok: bool) {
	if !ok do return
	e := pop(&S.groups)
	sk.canvas_restore_to(S.cv, e.count)
}

// Blurs whatever is already drawn behind r (frosted glass), then draws the
// rest of the scope on top.
@(deferred_out = end_group)
frosted :: proc(r: Rect, sigma: f32, radius: f32 = 0) -> bool {
	cv := S.cv
	count := sk.canvas_save(cv)
	if radius > 0 do sk.canvas_clip_rrect(cv, r.x, r.y, r.w, r.h, radius)
	else do sk.canvas_clip_rect(cv, r.x, r.y, r.w, r.h)
	l := sk.Layer{bounds = {r.x, r.y, r.w, r.h}, alpha = 1, backdrop_blur = sigma}
	sk.canvas_save_layer(cv, &l)
	append(&S.groups, Group_Entry{count})
	return true
}

// ---------------------------------------------------------------- text

Font :: struct {
	family:    cstring,
	size:      f32,
	weight:    f32, // 100..900, 0 = 400
	tracking:  f32, // letter spacing in em, like CSS
	lh:        f32, // line height as a multiple of size, 0 = font default
	tabular:   bool, // tabular figures
	italic:    bool,
	underline: bool,
	upper:     bool, // uppercase the text (CSS text-transform)
	max_lines: int, // 0 = unlimited; truncated text ends in …
}

Text_Align :: enum i32 {
	Left,
	Center,
	Right,
}

// Registers a font file (relative to the project directory unless absolute)
// under a family name. Variable fonts take their weight from Font.weight.
font :: proc(family: string, path: string) -> bool {
	p := resolve(path)
	ok := bool(sk.font_register(strings.clone_to_cstring(family, context.temp_allocator), strings.clone_to_cstring(p, context.temp_allocator)))
	if !ok do fmt.eprintln("fx: cannot load font", p)
	return ok
}

// Lays out text (cached per thread); max_w 0 = one line.
shape :: proc(s: string, f: Font, max_w: f32 = 0, align := Text_Align.Left) -> ^sk.Text {
	s := f.upper ? strings.to_upper(s, context.temp_allocator) : s
	st := sk.Text_Style {
		family      = f.family,
		size        = f.size,
		weight      = f.weight,
		tracking    = f.tracking * f.size,
		line_height = f.lh,
		align       = i32(align),
		tabular     = b32(f.tabular),
		italic      = b32(f.italic),
		max_lines   = i32(f.max_lines),
		underline   = b32(f.underline),
	}
	return sk.text_layout(raw_data(s), c.size_t(len(s)), &st, max_w)
}

metrics :: proc(t: ^sk.Text) -> sk.Text_Metrics {
	m: sk.Text_Metrics
	sk.text_get_metrics(t, &m)
	return m
}

measure :: proc(s: string, f: Font, max_w: f32 = 0) -> Vec2 {
	if s == "" do return {0, 0}
	m := metrics(shape(s, f, max_w))
	return {m.width, m.height}
}

// Draws text with its box's top-left at (x, y); returns the box.
text :: proc(s: string, x, y: f32, f: Font, c: Color, max_w: f32 = 0, align := Text_Align.Left) -> Rect {
	t := shape(s, f, max_w, align)
	m := metrics(t)
	p := fill(c)
	sk.text_draw(S.cv, t, x, y, &p)
	return {x, y, max_w > 0 ? max_w : m.width, m.height}
}

// Draws text positioned by an anchor: {0,0} puts the box's top-left at p,
// {0.5,0.5} centers it on p, {1,0} right-aligns it to p.
label :: proc(s: string, p: Vec2, f: Font, c: Color, anchor := Vec2{0, 0}) -> Rect {
	t := shape(s, f)
	m := metrics(t)
	x, y := p.x - m.width * anchor.x, p.y - m.height * anchor.y
	pt := fill(c)
	sk.text_draw(S.cv, t, x, y, &pt)
	return {x, y, m.width, m.height}
}

// Draws one line of text with its baseline at y.
text_baseline :: proc(s: string, x, y: f32, f: Font, c: Color) -> Rect {
	t := shape(s, f)
	m := metrics(t)
	p := fill(c)
	sk.text_draw(S.cv, t, x, y - m.baseline, &p)
	return {x, y - m.baseline, m.width, m.height}
}

// Text filled with a paint (gradients).
text_paint :: proc(s: string, x, y: f32, f: Font, p: sk.Paint, max_w: f32 = 0, align := Text_Align.Left) {
	p := p
	sk.text_draw(S.cv, shape(s, f, max_w, align), x, y, &p)
}

// ---------------------------------------------------------------- icons

@(private)
icons: struct {
	once:  sync.Once,
	paths: map[string]Icon_Path,
}

Icon_Path :: struct {
	path:   ^sk.Path,
	filled: bool,
}

icon_path :: proc(name: string) -> (Icon_Path, bool) {
	sync.once_do(&icons.once, proc() {
		icons.paths = make(map[string]Icon_Path)
		for d in ICON_DEFS {
			if p := sk.path_from_svg(d.d); p != nil do icons.paths[d.name] = {p, d.filled}
		}
	})
	ip, ok := icons.paths[name]
	return ip, ok
}

// Draws a 24-unit icon scaled to size with its top-left at (x, y).
icon :: proc(name: string, x, y, size: f32, c: Color, width: f32 = 1.6) {
	ip, ok := icon_path(name)
	if !ok do return
	cv := S.cv
	sk.canvas_save(cv)
	sk.canvas_translate(cv, x, y)
	k := size / 24
	sk.canvas_scale(cv, k, k)
	p := ip.filled ? fill(c) : stroke(c, width)
	sk.canvas_draw_path(cv, ip.path, &p)
	sk.canvas_restore(cv)
}

// ---------------------------------------------------------------- images

@(private)
images: struct {
	lock:   sync.Mutex,
	loaded: map[string]^sk.Image,
}

// Loads an image (relative to the project directory unless absolute), once.
load_image :: proc(path: string) -> ^sk.Image {
	sync.guard(&images.lock)
	if img, ok := images.loaded[path]; ok do return img
	img := sk.image_from_file(strings.clone_to_cstring(resolve(path), context.temp_allocator))
	if img == nil do fmt.eprintln("fx: cannot load image", path)
	images.loaded[strings.clone(path)] = img
	return img
}

image_size :: proc(img: ^sk.Image) -> Vec2 {
	w, h: i32
	sk.image_size(img, &w, &h)
	return {f32(w), f32(h)}
}

Image_Fit :: enum {
	Fill, // stretch to r
	Contain,
	Cover, // fill r, cropping the image
}

// Draws an image into r; focus picks which part stays in view when Cover
// crops (0..1 on each axis), zoom crops further in.
image :: proc(img: ^sk.Image, r: Rect, alpha: f32 = 1, fit := Image_Fit.Cover, focus := Vec2{0.5, 0.5}, zoom: f32 = 1) {
	if img == nil do return
	sz := image_size(img)
	switch fit {
	case .Fill:
		sk.canvas_draw_image(S.cv, img, nil, r.x, r.y, r.w, r.h, alpha)
	case .Contain:
		d := contain(r, sz.x, sz.y)
		sk.canvas_draw_image(S.cv, img, nil, d.x, d.y, d.w, d.h, alpha)
	case .Cover:
		s := max(r.w / sz.x, r.h / sz.y) * max(zoom, 1)
		cw, ch := r.w / s, r.h / s
		src := [4]f32{(sz.x - cw) * clamp01(focus.x), (sz.y - ch) * clamp01(focus.y), cw, ch}
		sk.canvas_draw_image(S.cv, img, &src, r.x, r.y, r.w, r.h, alpha)
	}
}

// ---------------------------------------------------------------- baked layers

@(private)
baked: struct {
	lock:   sync.Mutex,
	images: map[string]^sk.Image,
}

// Draws into r an image of what paint() draws there, rendered once at res
// times r's size and reused by every frame and thread. For static layers:
// gradients, vignettes, complex backgrounds.
bake :: proc(key: string, r: Rect, res: f32, paint: proc(r: Rect, data: rawptr), data: rawptr = nil, alpha: f32 = 1) {
	k := fmt.tprintf("%s/%.1fx%.1f/%.2f", key, r.w, r.h, res)
	img: ^sk.Image
	{
		sync.guard(&baked.lock)
		img = baked.images[k]
		if img == nil {
			s := sk.surface_raster(i32(r.w * res + 0.5), i32(r.h * res + 0.5))
			defer sk.surface_free(s)
			saved := S.cv
			S.cv = sk.surface_canvas(s)
			sk.canvas_scale(S.cv, res, res)
			sk.canvas_translate(S.cv, -r.x, -r.y)
			paint(r, data)
			S.cv = saved
			img = sk.surface_snapshot(s)
			baked.images[strings.clone(k)] = img
		}
	}
	sk.canvas_draw_image(S.cv, img, nil, r.x, r.y, r.w, r.h, alpha)
}

// ---------------------------------------------------------------- shaders

// Fills r with an SkSL shader; uniforms are passed as floats in declaration order.
shader :: proc(sksl: cstring, r: Rect, uniforms: ..f32) {
	err: [512]u8
	if !sk.canvas_draw_sksl(S.cv, sksl, raw_data(uniforms), c.size_t(len(uniforms)), r.x, r.y, r.w, r.h, &err[0], len(err)) {
		fmt.eprintln("fx: shader:", cstring(&err[0]))
	}
}

// Path relative to the project directory, unless absolute.
resolve :: proc(path: string) -> string {
	if filepath.is_abs(path) || PROJECT_DIR == "" do return path
	return join({PROJECT_DIR, path})
}

// Joins path elements (temp allocator unless given one).
join :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}
