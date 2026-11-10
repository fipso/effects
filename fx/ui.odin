// Building blocks for product mockups. Immediate ones (backdrop, window,
// phone, cursor, highlight, kinetic text, caption) draw at stage coordinates;
// layout ones (sidebar, topbar, pill, button, kpi, table rows, bars, avatar,
// bubble) are called inside fx.layout.
package fx

import "core:fmt"
import "core:math"
import "core:sync"
import sk "../sk"

// ---------------------------------------------------------------- backdrops

Backdrop :: enum {
	Night,
	Paper,
}

// Vignetted surface with an engineering-paper grid; offset drifts the grid.
backdrop :: proc(kind: Backdrop, r: Rect = {}, grid := true, offset := Vec2{}) {
	r := r == {} ? stage() : r
	// The gradient is smooth, so it is baked at half resolution once.
	bake(kind == .Night ? "backdrop/night" : "backdrop/paper", r, 0.5, proc(r: Rect, data: rawptr) {
		night := data != nil
		stops: [3]Color = night ? {0xff1b1b17, 0xff111110, 0xff0b0b0a} : {0xfff7f6f1, 0xfff3f2ec, 0xffe9e7de}
		ellipse_gradient(r, {r.x + r.w * 0.5, r.y + r.h * 0.45}, r.w * 0.9, r.h * 0.8, {{stops[0], 0}, {stops[1], 0.55}, {stops[2], 1}})
	}, kind == .Night ? rawptr(uintptr(1)) : nil)
	if !grid do return
	base: Color = kind == .Night ? 0xf2f0e6 : 0x16160f
	minor := with_alpha(base, kind == .Night ? 0.03 : 0.035)
	major := with_alpha(base, kind == .Night ? 0.07 : 0.075)
	grid_lines(r, 48, minor, offset)
	grid_lines(r, 240, major, offset)
}

grid_lines :: proc(r: Rect, step: f32, c: Color, offset := Vec2{}) {
	ox := math.mod(offset.x, step)
	oy := math.mod(offset.y, step)
	for x := r.x + (ox < 0 ? ox + step : ox); x < r.x + r.w; x += step do vline(x, r.y, r.h, c)
	for y := r.y + (oy < 0 ? oy + step : oy); y < r.y + r.h; y += step do hline(r.x, y, r.w, c)
}

// Fills r with an elliptical radial gradient (CSS radial-gradient(ellipse rx ry at c)).
ellipse_gradient :: proc(r: Rect, c: Vec2, rx, ry: f32, stops: []Stop) {
	cv := S.cv
	sk.canvas_save(cv)
	sk.canvas_clip_rect(cv, r.x, r.y, r.w, r.h)
	sk.canvas_translate(cv, c.x, c.y)
	sk.canvas_scale(cv, 1, ry / rx)
	p := with_stops(radial({0, 0}, rx), ..stops)
	big := r.w + r.h
	rect_paint({-big, -big * rx / ry, 2 * big, 2 * big * rx / ry}, p)
	sk.canvas_restore(cv)
}

// Darkened edges; baked once per strength.
vignette :: proc(strength: f32 = 0.42, r: Rect = {}) {
	r := r == {} ? stage() : r
	s := new_clone(strength, context.temp_allocator)
	bake(fmt.tprintf("vignette/%.3f", strength), r, 0.5, proc(r: Rect, data: rawptr) {
		a := (^f32)(data)^
		ellipse_gradient(r, center(r), r.w * 0.75, r.h * 0.7, {{0, 0}, {0, 0.55}, {with_alpha(0, a), 1}})
	}, s)
}

@(private = "file")
noise: struct {
	once: sync.Once,
	img:  ^sk.Image,
}

NOISE_SIZE :: 256

// Film grain: a tile of noise laid over the frame (overlay blend), jumping
// to a new offset 24 times a second.
grain :: proc(amount: f32 = 0.04) {
	sync.once_do(&noise.once, proc() {
		px := make([]u32, NOISE_SIZE * NOISE_SIZE)
		defer delete(px)
		r := rng(0x9e3779b9)
		for &p in px {
			v := u32(rand(&r) * 255)
			p = 0xff000000 | v << 16 | v << 8 | v
		}
		noise.img = sk.image_from_pixels(raw_data(px), NOISE_SIZE, NOISE_SIZE, NOISE_SIZE * 4)
	})
	tick := int(S.t * 24)
	dx := hash01(7, tick) * NOISE_SIZE
	dy := hash01(13, tick) * NOISE_SIZE
	sk.canvas_draw_image_tiled(S.cv, noise.img, 0, 0, S.w, S.h, dx, dy, amount * 6, i32(sk.Blend.Overlay) + 1)
}

// ---------------------------------------------------------------- brand

// The brand mark: an open red bracket, size×size with its top-left at p.
mark :: proc(p: Vec2, size: f32 = 28, c: Color = 0) {
	c := c == 0 ? theme.red : c
	path := sk.path_from_svg("M21 7H9v18h12")
	defer sk.path_free(path)
	cv := S.cv
	sk.canvas_save(cv)
	sk.canvas_translate(cv, p.x, p.y)
	sk.canvas_scale(cv, size / 32, size / 32)
	pt := sk.Paint{color = c, stroke = 2.6, square_cap = true}
	sk.canvas_draw_path(cv, path, &pt)
	sk.canvas_restore(cv)
}

// ---------------------------------------------------------------- windows

// Product window: chrome bar with dots, url and sheet label, red corners.
// Returns the body below the bar.
window :: proc(r: Rect, url := "", sheet := "", night := false) -> Rect {
	th := &theme
	if night {
		shadow(r, 0, 60, 140, -30, 0xcc000000)
		shadow(r, 0, 20, 50, -10, 0x99000000)
	} else {
		shadow(r, 0, 50, 120, -30, 0x5916160f)
		shadow(r, 0, 14, 40, -12, 0x4016160f)
	}
	rect(r, th.sf)
	bar := Rect{r.x, r.y, r.w, 42}
	rect(bar, th.sf2)
	hline(r.x, r.y + 41, r.w, th.bd)
	for i in 0 ..< 3 do ring({r.x + 16 + 5 + f32(i) * 17, r.y + 21}, 4.5, th.bds, 1)
	if url != "" {
		m := measure(url, mono(13))
		u := Rect{r.x + (r.w - m.x - 140) / 2, r.y + 21 - (m.y + 8) / 2, m.x + 140, m.y + 8}
		rect(u, th.sf)
		border(u, th.bd)
		text(url, u.x + 70, u.y + 4, mono(13), th.mut)
	}
	if sheet != "" do label(sheet, {r.x + r.w - 16, r.y + 21}, caps(12, 0.14), th.sub, {1, 0.5})
	border(r, th.bds)
	corners(r, th.red)
	return {r.x, r.y + 42, r.w, r.h - 42}
}

// Red L-brackets at the top-left and bottom-right of r.
corners :: proc(r: Rect, c: Color, size: f32 = 16, off: f32 = 6, width: f32 = 2) {
	x0, y0 := r.x - off, r.y - off
	rect({x0, y0, size, width}, c)
	rect({x0, y0, width, size}, c)
	x1, y1 := r.x + r.w + off, r.y + r.h + off
	rect({x1 - size, y1 - width, size, width}, c)
	rect({x1 - width, y1 - size, width, size}, c)
}

// A phone: dark bezel, notch, status bar. Returns the screen.
phone :: proc(r: Rect) -> Rect {
	shadow(r, 54, 60, 120, -30, 0x8c16160f)
	shadow(r, 54, 20, 40, -10, 0x5916160f)
	rrect(r, 54, 0xff121210)
	ring_rect := inset(r, 1)
	rrect_paint(ring_rect, 53, stroke(0xff3a3a33, 2))
	s := inset(r, 14)
	rrect(s, 42, theme.sf)
	rrect({r.x + r.w / 2 - 55, r.y + 24, 110, 30}, 16, 0xff121210)
	label("9:41", {s.x + 34, s.y + 28}, sans(15, 600), theme.ink, {0, 0.5})
	bx := s.x + s.w - 34
	rrect_paint({bx - 24, s.y + 22, 24, 12}, 3, stroke(theme.ink, 1.5))
	for i in 0 ..< 3 {
		h := 6 + f32(i) * 3
		rect({bx - 30 - 14 + f32(i) * 7 - 7, s.y + 34 - h, 4, h}, theme.ink)
	}
	return s
}

// ---------------------------------------------------------------- app chrome (layout)

Nav :: struct {
	icon, label: string,
	sub:         bool, // child of the previous top-level item
	sep:         bool, // a divider instead of an item
}

// The real rail (web/src/layouts/AppShell.vue), German labels.
LIERMANN_NAV := [?]Nav {
	{icon = "agent", label = "Assistent"},
	{icon = "dashboard", label = "Übersicht"},
	{icon = "contacts", label = "Kontakte"},
	{icon = "globe", label = "Outbound"},
	{icon = "linkedin", label = "LinkedIn", sub = true},
	{icon = "feed", label = "LinkedIn Posts", sub = true},
	{icon = "whatsapp", label = "WhatsApp", sub = true},
	{icon = "instagram", label = "Instagram", sub = true},
	{icon = "mail", label = "E-Mail", sub = true},
	{icon = "calls", label = "Anrufe", sub = true},
	{icon = "pipeline", label = "Vertrieb"},
	{icon = "pipeline", label = "Pipelines", sub = true},
	{icon = "calendar", label = "Follow-ups", sub = true},
	{icon = "usage", label = "Performance", sub = true},
	{icon = "layers", label = "Content"},
	{icon = "video", label = "Videos", sub = true},
	{icon = "broadcast", label = "Live", sub = true},
	{icon = "sparkles", label = "Postideen", sub = true},
	{icon = "bell", label = "Aufgaben & Hinweise"},
	{icon = "calendar", label = "Kalender"},
	{sep = true},
	{icon = "calls", label = "Telefon"},
	{icon = "whatsapp", label = "WhatsApp"},
	{icon = "workflows", label = "Flows"},
	{sep = true},
	{icon = "settings", label = "Einstellungen"},
}

Sidebar :: struct {
	active:    string, // label of the highlighted item
	open:      []string, // top-level items whose children are shown
	items:     []Nav, // default: LIERMANN_NAV
	workspace: string,
	user:      string,
	role:      string,
	w:         f32, // default 250
}

// App sidebar. Items get ids "nav/<label>" for fx.rect_of.
sidebar :: proc(sb: Sidebar) {
	th := &theme
	items := sb.items == nil ? LIERMANN_NAV[:] : sb.items
	if box({w = fixed(sb.w > 0 ? sb.w : 250), h = grow(), dir = .Col, pad = {18, 12, 18, 12}, gap = 3, bg = th.sf2, border = th.bd, sides = {.Right}}) {
		if box({dir = .Row, gap = 10, align = .Center, pad = {0, 12, 16, 8}}) {
			item({w = fixed(22), h = fixed(22), draw = proc(r: Rect, _: rawptr) {mark({r.x, r.y}, 22)}})
			txt("Liermann", sans(19, 600, -0.01), th.ink)
		}
		show_children := false
		for n in items {
			if n.sep {
				item({w = grow(), h = fixed(1), bg = th.bd})
				continue
			}
			if !n.sub {
				show_children = false
				for o in sb.open do if o == n.label do show_children = true
			} else if !show_children do continue
			on := n.label == sb.active
			fg := on ? th.sf : th.mut
			has_kids := false
			if !n.sub {
				for j := index_of(items, n) + 1; j < len(items) && items[j].sub; j += 1 do has_kids = true
			}
			id := fmt.tprintf("nav/%s", n.label)
			pad: [4]f32 = n.sub ? {6, 12, 6, 34} : {9, 12, 9, 12}
			if box({id = id, w = grow(), dir = .Row, gap = 12, align = .Center, pad = pad, bg = on ? th.ink : 0}) {
				glyph(n.icon, n.sub ? 15 : 17, fg)
				txt(n.label, sans(n.sub ? 14 : 16), fg)
				if has_kids {
					spacer()
					glyph(show_children ? "chevronDown" : "chevronRight", 14, alpha(fg, 0.6))
				}
			}
		}
		spacer()
		if box({w = grow(), dir = .Col, gap = 8, pad = {14, 0, 0, 0}, border = th.bd, sides = {.Top}}) {
			txt("Arbeitsbereich", caps(11, 0.12), th.sub)
			if box({w = grow(), pad = padxy(10, 7), border = th.bds, bg = th.sf}) {
				txt(sb.workspace != "" ? sb.workspace : "Weber & Kraus GmbH", sans(14.5), th.ink)
			}
			if box({dir = .Row, gap = 10, align = .Center, pad = {4, 0, 0, 0}}) {
				avatar("LB", 30)
				if box({dir = .Col}) {
					txt(sb.user != "" ? sb.user : "Lisa Brandt", sans(14, 600), th.ink)
					txt(sb.role != "" ? sb.role : "Inhaber", sans(12.5), th.sub)
				}
			}
		}
	}
}

@(private = "file")
index_of :: proc(items: []Nav, n: Nav) -> int {
	for it, i in items do if it.label == n.label && it.sub == n.sub && it.icon == n.icon do return i
	return -1
}

// The top bar over every page: workspace, role, bell, language, theme.
topbar :: proc(title := "Weber & Kraus GmbH", role := "Inhaber") {
	th := &theme
	if box({w = grow(), h = fixed(52), dir = .Row, gap = 12, align = .Center, pad = padxy(20, 0), bg = th.sf, border = th.bd, sides = {.Bottom}}) {
		glyph("panelLeft", 17, th.mut)
		txt(title, sans(15.5, 600), th.ink)
		pill(role)
		spacer()
		glyph("bell", 17, th.mut)
		txt("EN", mono(13), th.mut)
		glyph("moon", 17, th.mut)
	}
}

Tone :: enum {
	Neutral,
	Ok,
	Warn,
	Red,
	Ink,
}

tone_colors :: proc(tone: Tone) -> (fg, bg, line: Color) {
	th := &theme
	switch tone {
	case .Neutral:
		return th.mut, 0, th.bds
	case .Ok:
		return th.ok, th.ok_soft, alpha(th.ok, 0.35)
	case .Warn:
		return th.warn, th.warn_soft, alpha(th.warn, 0.35)
	case .Red:
		return th.red, th.red_soft, alpha(th.red, 0.35)
	case .Ink:
		return th.sf, th.ink, th.ink
	}
	return
}

pill :: proc(s: string, tone := Tone.Neutral, b: Box = {}) {
	fg, bg, line := tone_colors(tone)
	b := b
	b.dir, b.pad, b.align, b.gap = .Row, padxy(9, 4), .Center, 6
	b.bg, b.border = bg, line
	if box(b) do txt(s, caps(12, 0.06), fg)
}

button :: proc(s: string, icon := "", primary := false, b: Box = {}) {
	th := &theme
	b := b
	b.dir, b.pad, b.align, b.gap = .Row, padxy(14, 9), .Center, 8
	b.bg = primary ? th.ink : th.sf
	b.border = primary ? th.ink : th.bds
	fg := primary ? th.sf : th.ink
	if box(b) {
		if icon != "" do glyph(icon, 16, fg)
		txt(s, sans(14.5, 500), fg)
	}
}

// KPI tile: label, big number, note.
kpi :: proc(label, value: string, note := "", b: Box = {}) {
	th := &theme
	b := b
	b.dir, b.pad, b.gap = .Col, padxy(14, 12), 4
	if b.bg == 0 do b.bg = th.sf
	if b.border == 0 do b.border = th.bds
	if box(b) {
		txt(label, sans(13), th.mut)
		f := sans(32, 600, -0.02)
		f.tabular = true
		txt(value, f, th.ink)
		if note != "" do txt(note, sans(12.5), th.sub)
	}
}

avatar :: proc(initials: string, size: f32 = 26, b: Box = {}) {
	th := &theme
	b := b
	b.w, b.h, b.justify, b.align, b.dir = fixed(size), fixed(size), .Center, .Center, .Row
	if b.bg == 0 do b.bg = th.sf2
	if b.border == 0 do b.border = th.bds
	if box(b) do txt(initials, mono(size * 0.4), th.ink)
}

// Chat bubble; mine = dark, right-aligned by the caller's layout.
bubble :: proc(s: string, mine := false, max_w: f32 = 420, b: Box = {}) {
	th := &theme
	b := b
	b.pad = padxy(13, 10)
	b.bg = mine ? th.ink : th.sf2
	if !mine do b.border = th.bd
	if b.w == {} do b.w = fit(0, max_w)
	if box(b) {
		f := sans(15)
		f.lh = 1.4
		txt(s, f, mine ? th.sf : th.ink, {wrap = true})
	}
}

// ---------------------------------------------------------------- tables (layout)

Col :: struct {
	title: string,
	w:     Size, // default grow()
	align: Text_Align,
	mono:  bool,
}

table_head :: proc(cols: []Col, b: Box = {}) {
	th := &theme
	b := b
	b.w, b.dir, b.gap, b.pad, b.align = grow(), .Row, 10, padxy(0, 8), .Center
	b.border, b.sides = th.bd, {.Bottom}
	if box(b) {
		for c in cols do cell(c, c.title, caps(10.5, 0.1), th.sub)
	}
}

table_row :: proc(cols: []Col, cells: []string, b: Box = {}) {
	th := &theme
	b := b
	b.w, b.dir, b.gap, b.align = grow(), .Row, 10, .Center
	if b.pad == {} do b.pad = padxy(0, 8)
	if b.border == 0 do b.border, b.sides = th.bd, {.Bottom}
	if box(b) {
		for c, i in cols {
			s := i < len(cells) ? cells[i] : ""
			f := c.mono ? mono(13) : sans(14.5)
			f.tabular = c.mono
			cell(c, s, f, th.ink)
		}
	}
}

@(private = "file")
cell :: proc(c: Col, s: string, f: Font, color: Color) {
	j: Justify = c.align == .Right ? .End : c.align == .Center ? .Center : .Start
	if box({w = c.w == {} ? grow() : c.w, dir = .Row, justify = j}) do txt(s, f, color)
}

// ---------------------------------------------------------------- charts (layout)

@(private = "file")
Bars_Data :: struct {
	values: []f32,
	max:    f32,
	accent: int,
	p:      f32,
	gap:    f32,
}

// Column chart grown to p (0..1); the accent column is red.
bars :: proc(values: []f32, max_v: f32 = 0, accent := -1, p: f32 = 1, b: Box = {}) {
	m := max_v
	if m == 0 do for v in values do m = max(m, v)
	d := new_clone(Bars_Data{values, m, accent, p, 8}, context.temp_allocator)
	b := b
	if b.w == {} do b.w = grow()
	if b.h == {} do b.h = fixed(150)
	b.data = d
	b.draw = proc(r: Rect, data: rawptr) {
		d := (^Bars_Data)(data)
		n := f32(len(d.values))
		if n == 0 do return
		bw := (r.w - d.gap * (n - 1)) / n
		for v, i in d.values {
			h := r.h * v / d.max * ease_out(clamp01(d.p * 1.3 - f32(i) / n * 0.3))
			rect({r.x + f32(i) * (bw + d.gap), r.y + r.h - h, bw, h}, i == d.accent ? theme.red : theme.ink)
		}
		hline(r.x, r.y + r.h, r.w, theme.bd)
	}
	item(b)
}

// Horizontal meter: track and a fill of v (0..1) grown to p.
meter :: proc(v: f32, p: f32 = 1, c: Color = 0, b: Box = {}) {
	Meter :: struct {
		v, p: f32,
		c:    Color,
	}
	b := b
	if b.w == {} do b.w = grow()
	if b.h == {} do b.h = fixed(10)
	if b.bg == 0 do b.bg = theme.sf3
	b.data = new_clone(Meter{v, p, c == 0 ? theme.ink : c}, context.temp_allocator)
	b.draw = proc(r: Rect, data: rawptr) {
		m := (^Meter)(data)
		rect({r.x, r.y, r.w * clamp01(m.v) * clamp01(m.p), r.h}, m.c)
	}
	item(b)
}

// ---------------------------------------------------------------- pointer & highlight

Cursor_Key :: struct {
	t:     f32,
	p:     Vec2, // where the pointer's tip is
	click: bool,
}

CURSOR_SVG :: "M5 3l14 8-6.2 1.6L9.6 19z"

// Animated mouse pointer moving between keys, visible over [from, to].
cursor :: proc(ks: []Cursor_Key, from, to: f32, size: f32 = 34) {
	t := S.t
	o := win(t, from, to, 0.25, 0.3)
	if o <= 0 || len(ks) == 0 do return
	k := 0
	for k < len(ks) - 1 && t > ks[k + 1].t do k += 1
	a, b := ks[k], ks[min(k + 1, len(ks) - 1)]
	p := a.t == b.t ? 0 : ease_in_out(prog(t, a.t, b.t))
	pos := lerp2(a.p, b.p, p)
	press, ring_p: f32 = 0, -1
	for q in ks {
		if q.click && t >= q.t && t < q.t + 0.45 {
			press = 1 - abs(prog(t, q.t, q.t + 0.2) * 2 - 1)
			ring_p = prog(t, q.t, q.t + 0.45)
		}
	}
	if ring_p >= 0 {
		r := 28 * (0.3 + ring_p * 1.6)
		ring(pos, r, alpha(theme.red, (1 - ring_p) * o), 2)
	}
	path, _ := ensure_cursor_path()
	cv := S.cv
	s := size / 24 * (1 - press * 0.15)
	sk.canvas_save(cv)
	sk.canvas_translate(cv, pos.x, pos.y)
	sk.canvas_scale(cv, s, s)
	sk.canvas_translate(cv, -5, -3) // the tip
	sh := sk.Paint{color = with_alpha(0, 0.3 * o), blur = 3 / s}
	sk.canvas_save(cv)
	sk.canvas_translate(cv, 0, 4 / s)
	sk.canvas_draw_path(cv, path, &sh)
	sk.canvas_restore(cv)
	fp := fill(alpha(theme.ink, o))
	sk.canvas_draw_path(cv, path, &fp)
	sp := stroke(alpha(theme.sf, o), 1.4)
	sk.canvas_draw_path(cv, path, &sp)
	sk.canvas_restore(cv)
}

@(private = "file")
cursor_path: struct {
	once: sync.Once,
	path: ^sk.Path,
}
@(private = "file")
ensure_cursor_path :: proc() -> (^sk.Path, bool) {
	// Paths are immutable once parsed, so threads can share this one.
	sync.once_do(&cursor_path.once, proc() {cursor_path.path = sk.path_from_svg(CURSOR_SVG)})
	return cursor_path.path, true
}

Hl_Key :: struct {
	t:   f32,
	r:   Rect,
	off: bool, // hide from here on
}

// A red highlight box moving between rects at the keys' times.
highlight :: proc(ks: []Hl_Key, dur: f32 = 0.35, pad: f32 = 6, c: Color = 0) {
	t := S.t
	if len(ks) == 0 || t < ks[0].t do return
	c := c == 0 ? theme.red : c
	k := 0
	for k < len(ks) - 1 && t >= ks[k + 1].t do k += 1
	cur := ks[k]
	prev := ks[max(k - 1, 0)]
	m := ep(t, cur.t, cur.t + dur, ease_out5)
	A := k > 0 && !prev.off ? prev.r : cur.r
	B := cur.off ? A : cur.r
	r := inset(lerp_rect(A, B, m), -pad)
	oa: f32 = k > 0 && !prev.off ? 1 : 0
	ob: f32 = cur.off ? 0 : 1
	o := lerp(oa, ob, m)
	if o <= 0.002 do return
	border(r, alpha(c, o), 1.5)
	corners(inset(r, 5), alpha(c, o), 12, 5, 2.5)
}

// ---------------------------------------------------------------- headlines

Word :: struct {
	w:      string,
	t:      f32, // when it rises in
	accent: bool,
	br:     bool, // line break after this word
}

// Words that rise in at their own times. Returns the block's rect.
kinetic :: proc(words: []Word, x, y: f32, f: Font, c: Color, accent: Color = 0, max_w: f32 = 0, dur: f32 = 0.38) -> Rect {
	t := S.t
	accent := accent == 0 ? theme.red : accent
	space := measure("a a", f).x - measure("aa", f).x
	lh := f.size * (f.lh > 0 ? f.lh : 1.05)
	cx, cy, right: f32 = x, y, x
	for w, i in words {
		sz := measure(w.w, f)
		if max_w > 0 && cx > x && cx + sz.x > x + max_w {
			cx = x
			cy += lh
		}
		p := ep(t, w.t - 0.06, w.t - 0.06 + dur)
		if p > 0.002 {
			r := Rect{cx, cy, sz.x, sz.y}
			if group({y = (1 - p) * 26, o = p, blur = (1 - p) * 8, bounds = inset(r, -4)}) {
				text(w.w, cx, cy, f, w.accent ? accent : c)
			}
		}
		cx += sz.x + space
		right = max(right, cx - space)
		if w.br || i == len(words) - 1 {
			if w.br {
				cx = x
				cy += lh
			}
		}
	}
	return {x, y, right - x, cy + lh - y}
}

// Kinetic text timed to a voice-over line; accents are word indices.
vo_text :: proc(id: string, x, y: f32, f: Font, c: Color, accents: []int = nil, breaks: []int = nil, max_w: f32 = 0) -> Rect {
	l := vo_line(id)
	if l == nil do return {}
	words := make([]Word, len(l.words), context.temp_allocator)
	for w, i in l.words {
		words[i] = {w = w.w, t = w.s}
		for a in accents do if a == i do words[i].accent = true
		for b in breaks do if b == i do words[i].br = true
	}
	return kinetic(words, x, y, f, c, max_w = max_w)
}

// Big headline, the captions' style.
headline :: proc(size: f32, weight: f32 = 600) -> Font {
	return {family = theme.sans, size = size, weight = weight, tracking = -0.035, lh = 0.98}
}

caption :: proc(s: string, p: Vec2, size: f32 = 84, c: Color = 0, anchor := Vec2{}) -> Rect {
	return label(s, p, headline(size), c == 0 ? theme.ink : c, anchor)
}

eyebrow :: proc(s: string, p: Vec2, c: Color = 0, anchor := Vec2{}) -> Rect {
	return label(s, p, caps(17, 0.16, 500), c == 0 ? theme.sub : c, anchor)
}
