// A small flexbox for laying out UI mockups. Build a tree, then it is sized,
// placed and drawn when the layout scope ends:
//
//   if fx.layout(r, {dir = .Col, pad = fx.pads(24), gap = 12}) {
//       if fx.box({dir = .Row, gap = 8, align = .Center}) {
//           fx.glyph("search", 18, ink)
//           fx.txt("Kontakte", font, ink)
//       }
//       fx.item({h = fx.fixed(1), w = fx.grow(), bg = line})
//   }
//
// Every element can be animated with the fields o, dx, dy, s, rot, blur, gray
// (applied around its center). Elements with an id can be found afterwards
// with fx.rect_of, in stage pixels after all transforms.
package fx

import "core:math"
import sk "../sk"

Sizing :: enum u8 {
	Fit, // content size
	Grow, // share of the parent's free space (v = weight)
	Fixed, // v pixels
	Percent, // v (0..1) of the parent's content size
}

Size :: struct {
	kind:     Sizing,
	v:        f32,
	min, max: f32, // 0 = unbounded
}

fixed :: proc "contextless" (v: f32) -> Size {return {kind = .Fixed, v = v}}
grow :: proc "contextless" (weight: f32 = 1, min: f32 = 0, max: f32 = 0) -> Size {return {kind = .Grow, v = weight, min = min, max = max}}
pct :: proc "contextless" (p: f32) -> Size {return {kind = .Percent, v = p}}
fit :: proc "contextless" (min: f32 = 0, max: f32 = 0) -> Size {return {kind = .Fit, min = min, max = max}}

// Padding: top, right, bottom, left.
pads :: proc "contextless" (v: f32) -> [4]f32 {return {v, v, v, v}}
padxy :: proc "contextless" (x, y: f32) -> [4]f32 {return {y, x, y, x}}

Dir :: enum u8 {
	Row,
	Col,
}
Justify :: enum u8 {
	Start,
	Center,
	End,
	Between,
}
Align :: enum u8 {
	Start,
	Center,
	End,
}
Side :: enum u8 {
	Top,
	Right,
	Bottom,
	Left,
}
Sides :: bit_set[Side]

Shadow :: struct {
	dx, dy, blur, spread: f32,
	c:                    Color,
}

Box :: struct {
	id:       string,
	dir:      Dir,
	w, h:     Size,
	pad:      [4]f32, // top right bottom left
	gap:      f32,
	justify:  Justify, // main axis
	align:    Align, // cross axis; use grow() sizing to stretch
	// look
	bg:       Color,
	paint:    Maybe(sk.Paint), // instead of bg, e.g. a gradient
	border:   Color,
	border_w: f32, // default 1 when border is set
	sides:    Sides, // which sides get the border, empty = all
	radius:   f32,
	shadow:   Shadow,
	clip:     bool,
	draw:     proc(r: Rect, data: rawptr), // custom content, after background
	data:     rawptr,
	// floating boxes are placed at `at` inside the parent's padding box and
	// drawn above their siblings without taking space
	float:    bool,
	at:       Vec2,
	// text elements
	wrap:     bool,
	talign:   Text_Align,
	// animation, around the element's center
	o:        Maybe(f32),
	dx, dy:   f32,
	s:        Maybe(f32),
	rot:      f32,
	blur:     f32,
	gray:     f32,
}

@(private = "file")
Kind :: enum u8 {
	Box,
	Text,
	Icon,
	Image,
}

@(private = "file")
Node :: struct {
	kind:                       Kind,
	b:                          Box,
	str:                        string,
	font:                       Font,
	color:                      Color,
	icon_w:                     f32,
	img:                        ^sk.Image,
	img_fit:                    Image_Fit,
	parent, first, last, next:  i32,
	size:                       [2]f32,
	pos:                        [2]f32,
	text:                       ^sk.Text,
}

@(private = "file")
Layout :: struct {
	nodes: [dynamic]Node,
	stack: [dynamic]i32,
	rects: map[string]Rect,
}

@(private = "file", thread_local)
L: Layout

// Clears the ids recorded by earlier layouts; the renderer calls this per frame.
layout_reset :: proc() {
	clear(&L.rects)
}

// Where the element with this id was drawn, in stage pixels after all transforms.
rect_of :: proc(id: string) -> (Rect, bool) {
	r, ok := L.rects[id]
	return r, ok
}

layout_begin :: proc(r: Rect, b: Box = {}) {
	assert(len(L.stack) == 0, "fx: layouts cannot nest")
	clear(&L.nodes)
	root := b
	root.w, root.h = fixed(r.w), fixed(r.h)
	push_node({kind = .Box, b = root, pos = {r.x, r.y}})
}

layout_end :: proc() {
	assert(len(L.stack) == 1, "fx: unbalanced boxes in layout")
	pop(&L.stack)
	compute(0)
	draw_node(0)
}

@(deferred_none = layout_end)
layout :: proc(r: Rect, b: Box = {}) -> bool {
	layout_begin(r, b)
	return true
}

// A container; children follow in its scope.
@(deferred_none = close)
box :: proc(b: Box) -> bool {
	push_node({kind = .Box, b = b})
	return true
}

close :: proc() {
	pop(&L.stack)
}

// A box without children (dividers, swatches, bars).
item :: proc(b: Box) {
	push_node({kind = .Box, b = b})
	pop(&L.stack)
}

// Text; set b.wrap to wrap at the width the layout gives it.
txt :: proc(s: string, f: Font, c: Color, b: Box = {}) {
	b := b
	if b.wrap && b.w == {} do b.w = grow()
	push_node({kind = .Text, b = b, str = s, font = f, color = c})
	pop(&L.stack)
}

// An icon from the icon set, size×size.
glyph :: proc(name: string, size: f32, c: Color, b: Box = {}, width: f32 = 1.6) {
	b := b
	b.w, b.h = fixed(size), fixed(size)
	push_node({kind = .Icon, b = b, str = name, color = c, icon_w = width})
	pop(&L.stack)
}

picture :: proc(img: ^sk.Image, b: Box, fit := Image_Fit.Cover) {
	push_node({kind = .Image, b = b, img = img, img_fit = fit})
	pop(&L.stack)
}

// Takes the free space along the parent's main axis.
spacer :: proc(weight: f32 = 1) {
	parent := &L.nodes[L.stack[len(L.stack) - 1]]
	b: Box
	if parent.b.dir == .Row do b.w = grow(weight)
	else do b.h = grow(weight)
	item(b)
}

@(private = "file")
push_node :: proc(n: Node) {
	n := n
	n.first, n.last, n.next, n.parent = -1, -1, -1, -1
	idx := i32(len(L.nodes))
	if len(L.stack) > 0 {
		p := L.stack[len(L.stack) - 1]
		n.parent = p
		pn := &L.nodes[p]
		if pn.last >= 0 do L.nodes[pn.last].next = idx
		else do pn.first = idx
		pn.last = idx
	}
	append(&L.nodes, n)
	append(&L.stack, idx)
}

// ---------------------------------------------------------------- sizing

@(private = "file")
size_spec :: proc(n: ^Node, a: int) -> Size {return a == 0 ? n.b.w : n.b.h}
@(private = "file")
pad_sum :: proc(n: ^Node, a: int) -> f32 {return a == 0 ? n.b.pad[1] + n.b.pad[3] : n.b.pad[0] + n.b.pad[2]}
@(private = "file")
main_axis :: proc(n: ^Node) -> int {return n.b.dir == .Row ? 0 : 1}
@(private = "file")
bound :: proc(v: f32, s: Size) -> f32 {
	v := max(v, s.min)
	return s.max > 0 ? min(v, s.max) : v
}

@(private = "file")
compute :: proc(root: i32) {
	fit_pass(root, 0)
	grow_pass(root, 0)
	shape_text()
	fit_pass(root, 1)
	grow_pass(root, 1)
	place(root)
}

// Bottom-up: content sizes.
@(private = "file")
fit_pass :: proc(i: i32, a: int) {
	for k := L.nodes[i].first; k >= 0; k = L.nodes[k].next do fit_pass(k, a)
	n := &L.nodes[i]
	content: f32
	switch n.kind {
	case .Box:
		along := a == main_axis(n)
		count := 0
		for k := n.first; k >= 0; k = L.nodes[k].next {
			c := &L.nodes[k]
			if c.b.float do continue
			if along do content += c.size[a]
			else do content = max(content, c.size[a])
			count += 1
		}
		if along && count > 1 do content += n.b.gap * f32(count - 1)
		content += pad_sum(n, a)
	case .Text:
		if a == 0 {
			m := metrics(shape(n.str, n.font))
			content = n.b.wrap ? 0 : math.ceil(m.width)
		} else {
			content = metrics(n.text).height
		}
	case .Icon, .Image:
	}
	s := size_spec(n, a)
	switch s.kind {
	case .Fixed:
		n.size[a] = s.v
	case .Fit, .Grow:
		n.size[a] = bound(content, s)
	case .Percent:
		n.size[a] = 0
	}
}

// Top-down: percentages, growing into free space, shrinking wrapped text.
@(private = "file")
grow_pass :: proc(i: i32, a: int) {
	n := &L.nodes[i]
	inner := n.size[a] - pad_sum(n, a)
	if a == main_axis(n) {
		used, weights, shrinkable: f32
		count := 0
		for k := n.first; k >= 0; k = L.nodes[k].next {
			c := &L.nodes[k]
			s := size_spec(c, a)
			if c.b.float {
				if s.kind == .Percent do c.size[a] = s.v * inner
				if s.kind == .Grow do c.size[a] = bound(inner, s)
				continue
			}
			count += 1
			if s.kind == .Percent do c.size[a] = s.v * inner
			if s.kind == .Grow do weights += s.v
			if s.kind == .Grow || (c.kind == .Text && c.b.wrap) do shrinkable += c.size[a]
			used += c.size[a]
		}
		if count > 1 do used += n.b.gap * f32(count - 1)
		free := inner - used
		if free > 0 && weights > 0 {
			for k := n.first; k >= 0; k = L.nodes[k].next {
				c := &L.nodes[k]
				s := size_spec(c, a)
				if c.b.float || s.kind != .Grow do continue
				c.size[a] = bound(c.size[a] + free * s.v / weights, s)
			}
		} else if free < 0 && shrinkable > 0 {
			k := max(0, 1 + free / shrinkable)
			for j := n.first; j >= 0; j = L.nodes[j].next {
				c := &L.nodes[j]
				if c.b.float do continue
				if size_spec(c, a).kind == .Grow || (c.kind == .Text && c.b.wrap) do c.size[a] *= k
			}
		}
	} else {
		for k := n.first; k >= 0; k = L.nodes[k].next {
			c := &L.nodes[k]
			s := size_spec(c, a)
			if s.kind == .Grow do c.size[a] = bound(inner, s)
			if s.kind == .Percent do c.size[a] = s.v * inner
			if c.kind == .Text && c.b.wrap && !c.b.float && c.size[a] > inner do c.size[a] = inner
		}
	}
	for k := n.first; k >= 0; k = L.nodes[k].next do grow_pass(k, a)
}

@(private = "file")
shape_text :: proc() {
	for &n in L.nodes {
		if n.kind != .Text do continue
		n.text = shape(n.str, n.font, n.b.wrap ? n.size[0] : 0, n.b.talign)
	}
}

@(private = "file")
place :: proc(i: i32) {
	n := &L.nodes[i]
	ma := main_axis(n)
	ca := 1 - ma
	origin := [2]f32{n.pos[0] + n.b.pad[3], n.pos[1] + n.b.pad[0]}
	inner := [2]f32{n.size[0] - pad_sum(n, 0), n.size[1] - pad_sum(n, 1)}
	total: f32
	count := 0
	for k := n.first; k >= 0; k = L.nodes[k].next {
		if L.nodes[k].b.float do continue
		total += L.nodes[k].size[ma]
		count += 1
	}
	gap := n.b.gap
	cursor: f32
	switch n.b.justify {
	case .Start:
	case .Center:
		cursor = (inner[ma] - total - gap * f32(max(count - 1, 0))) / 2
	case .End:
		cursor = inner[ma] - total - gap * f32(max(count - 1, 0))
	case .Between:
		if count > 1 do gap = (inner[ma] - total) / f32(count - 1)
	}
	for k := n.first; k >= 0; k = L.nodes[k].next {
		c := &L.nodes[k]
		if c.b.float {
			c.pos = {n.pos[0] + c.b.at.x, n.pos[1] + c.b.at.y}
		} else {
			c.pos[ma] = origin[ma] + cursor
			cursor += c.size[ma] + gap
			switch n.b.align {
			case .Start:
				c.pos[ca] = origin[ca]
			case .Center:
				c.pos[ca] = origin[ca] + (inner[ca] - c.size[ca]) / 2
			case .End:
				c.pos[ca] = origin[ca] + inner[ca] - c.size[ca]
			}
		}
		place(k)
	}
}

// ---------------------------------------------------------------- drawing

@(private = "file")
draw_node :: proc(i: i32) {
	n := &L.nodes[i]
	b := &n.b
	r := Rect{n.pos[0], n.pos[1], n.size[0], n.size[1]}
	animated := b.o != nil || b.dx != 0 || b.dy != 0 || b.s != nil || b.rot != 0 || b.blur > 0 || b.gray > 0
	if animated {
		sh := b.shadow
		grow := max(sh.blur + sh.spread + abs(sh.dx) + abs(sh.dy), 0) + 4
		xf := Xf {
			x      = b.dx,
			y      = b.dy,
			s      = b.s,
			rot    = b.rot,
			origin = center(r),
			o      = b.o,
			blur   = b.blur,
			gray   = b.gray,
			bounds = inset(r, -grow),
		}
		if !group_begin(xf) do return
	}
	defer if animated do end_group(true)

	if b.id != "" {
		in_ := [4]f32{r.x, r.y, r.w, r.h}
		out: [4]f32
		sk.canvas_map_rect(S.cv, &in_, &out)
		k := S.scale > 0 ? S.scale : 1
		L.rects[b.id] = {out[0] / k, out[1] / k, out[2] / k, out[3] / k}
	}

	if b.shadow.c != 0 {
		sh := b.shadow
		shadow(r, b.radius, sh.dy, sh.blur, sh.spread, sh.c, sh.dx)
	}
	if p, ok := b.paint.?; ok do rrect_paint(r, b.radius, p)
	else if b.bg != 0 do rrect(r, b.radius, b.bg)
	if b.border != 0 {
		w := b.border_w > 0 ? b.border_w : 1
		if b.sides == {} || b.sides == {.Top, .Right, .Bottom, .Left} {
			border(r, b.border, w, b.radius)
		} else {
			if .Top in b.sides do rect({r.x, r.y, r.w, w}, b.border)
			if .Bottom in b.sides do rect({r.x, r.y + r.h - w, r.w, w}, b.border)
			if .Left in b.sides do rect({r.x, r.y, w, r.h}, b.border)
			if .Right in b.sides do rect({r.x + r.w - w, r.y, w, r.h}, b.border)
		}
	}
	if b.draw != nil do b.draw(r, b.data)

	switch n.kind {
	case .Box:
	case .Text:
		p := fill(n.color)
		sk.text_draw(S.cv, n.text, r.x, r.y, &p)
	case .Icon:
		icon(n.str, r.x, r.y, r.w, n.color, n.icon_w)
	case .Image:
		image(n.img, r, 1, n.img_fit)
	}

	if n.first < 0 do return
	count: i32
	if b.clip {
		count = sk.canvas_save(S.cv)
		if b.radius > 0 do sk.canvas_clip_rrect(S.cv, r.x, r.y, r.w, r.h, b.radius)
		else do sk.canvas_clip_rect(S.cv, r.x, r.y, r.w, r.h)
	}
	for k := n.first; k >= 0; k = L.nodes[k].next do if !L.nodes[k].b.float do draw_node(k)
	for k := n.first; k >= 0; k = L.nodes[k].next do if L.nodes[k].b.float do draw_node(k)
	if b.clip do sk.canvas_restore_to(S.cv, count)
}
