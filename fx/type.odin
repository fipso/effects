// Type in motion, letter by letter: staggered rises, decoding text, and the
// boxes of single glyphs for anything else.
package fx

import "core:strings"
import "core:unicode/utf8"

Glyph :: struct {
	s:    string, // the character
	x, w: f32, // its place in the line (kerning kept)
}

// Where each character of a one-line text sits. Temp-allocated.
glyphs :: proc(s: string, f: Font) -> []Glyph {
	s := f.upper ? strings.to_upper(s, context.temp_allocator) : s
	f := f
	f.upper = false
	out := make([dynamic]Glyph, 0, len(s), context.temp_allocator)
	for r, off in s {
		n := utf8.rune_size(r)
		ch := s[off:off + n]
		if r == ' ' {
			append(&out, Glyph{ch, 0, 0})
			continue
		}
		w := measure(ch, f).x
		// trailing spaces are not measured, so measure up to and including this glyph
		append(&out, Glyph{ch, measure(s[:off + n], f).x - w, w})
	}
	return out[:]
}

Letters :: struct {
	t0:     f32, // when the first letter starts
	step:   f32, // delay between letters
	dur:    f32, // each letter's move, 0 = 0.5
	rise:   f32, // px it comes up from (negative: drops in)
	blur:   f32, // starts this blurred
	scale:  f32, // starts this much bigger (0.4 = 140%)
	spin:   f32, // starts turned by this many degrees
	out:    f32, // when letters start leaving again (0 = never), mirrored
	ease:   Ease,
	random: bool, // letters start in a shuffled order
}

// One line of text whose letters arrive one after another. anchor as in label.
letters :: proc(s: string, p: Vec2, f: Font, c: Color, l: Letters, anchor := Vec2{0, 0}) -> Rect {
	t := S.t
	gs := glyphs(s, f)
	if len(gs) == 0 do return {}
	f := f
	f.upper = false
	last := gs[len(gs) - 1]
	w := last.x + last.w
	h := measure("Hg", f).y
	x0, y0 := p.x - w * anchor.x, p.y - h * anchor.y
	dur := l.dur > 0 ? l.dur : 0.5
	e: Ease = ease_out5
	if l.ease != nil do e = l.ease
	for g, i in gs {
		if g.w == 0 do continue
		k := l.random ? int(hash01(977, i) * f32(len(gs))) : i
		a := e(prog(t, l.t0 + f32(k) * l.step, l.t0 + f32(k) * l.step + dur))
		if l.out > 0 do a = min(a, 1 - ease_in(prog(t, l.out + f32(k) * l.step * 0.5, l.out + f32(k) * l.step * 0.5 + dur * 0.6)))
		if a <= 0.002 do continue
		gx := x0 + g.x
		if a >= 0.999 {
			text(g.s, gx, y0, f, c)
			continue
		}
		o := Vec2{gx + g.w / 2, y0 + h * 0.6}
		xf := Xf{y = l.rise * (1 - a), o = min(a * 1.6, 1), blur = l.blur * (1 - a), s = 1 + l.scale * (1 - a), rot = l.spin * (1 - a), origin = o}
		pad := l.blur * 3 + 8 + abs(l.scale) * f.size
		xf.bounds = Rect{gx - pad, y0 - pad, g.w + 2 * pad, h + 2 * pad}
		if group(xf) do text(g.s, gx, y0, f, c)
	}
	return {x0, y0, w, h}
}

SCRAMBLE_SET :: "abcdefghijklmnopqrstuvwxyz0123456789<>/\\[]{}=+*#%&"

// text with the characters after the first p (0..1) of it replaced by
// others that change rate times a second: a message being decoded. Best in
// a monospaced font. hide > 0 leaves characters further than that many
// ahead of the decoded part blank.
scramble :: proc(s: string, p: f32, seed: u32 = 1, rate: f32 = 30, hide: int = 0, set := SCRAMBLE_SET) -> string {
	if p >= 1 do return s
	n := utf8.rune_count_in_string(s)
	done := int(clamp01(p) * f32(n + 1))
	b := strings.builder_make(context.temp_allocator)
	tick := int(S.t * rate)
	i := 0
	for r in s {
		switch {
		case i < done || r == ' ' || r == '\n':
			strings.write_rune(&b, r)
		case hide > 0 && i >= done + hide:
			strings.write_byte(&b, ' ')
		case:
			k := int(hash01(seed + u32(i) * 31, tick) * f32(len(set)))
			strings.write_byte(&b, set[min(k, len(set) - 1)])
		}
		i += 1
	}
	return strings.to_string(b)
}
