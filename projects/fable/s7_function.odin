// 06 — The function. The film steps back and shows what it is: a window with
// code on the left, a timeline below, and in the middle a preview of itself,
// which contains a preview of itself. The code in the left pane is this
// file, compiled into the video by #load.
package fable

import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import fx "effects:fx"

SOURCE :: #load("s7_function.odin", string)

@(private = "file")
source_lines: []string
@(private = "file")
source_once: sync.Once

// Where the preview sits. Half the stage, so the picture inside is this
// picture at half size, and the point that maps onto itself is FIXED.
PREVIEW :: fx.Rect{480, 110, 960, 540}
FIXED :: fx.Vec2{960, 220}
DEPTH :: 5

// The editor, drawn at stage size. depth 0 is the real one.
editor :: proc(t: f32, depth: int) {
	sync.once_do(&source_once, proc() {source_lines = strings.split_lines(SOURCE)})
	sc := SCENES[len(SCENES) - 2] // this scene
	lt := t - sc.start
	fx.rect(fx.stage(), 0xff0c0b0a)

	// ---- title bar
	fx.rect({0, 0, W, 64}, 0xff141210)
	fx.hline(0, 64, W, bone(0.1))
	for i in 0 ..< 3 do fx.circle({34 + f32(i) * 26, 32}, 7, i == 0 ? fx.alpha(CLAY, 0.9) : bone(0.22))
	fx.label("effects-edit — projects/fable", {MID.x, 32}, mono(19, 500, 0.02), bone(0.72), {0.5, 0.5})
	fx.label("1920 × 1080 · 60 fps · 3600 frames", {W - 28, 32}, mono(17, 400, 0.02), bone(0.4), {1, 0.5})

	// ---- code: this file, scrolling, the line being "run" lit
	code := fx.Rect{24, 86, 432, 580}
	fx.rrect(code, 10, 0xff12100f)
	fx.border(code, bone(0.1), 1, 10)
	fx.label("s7_function.odin", {code.x + 16, code.y + 12}, mono(15, 500), fx.alpha(CLAY, 0.95))
	fx.hline(code.x, code.y + 40, code.w, bone(0.1))
	if fx.group({clip = fx.Rect{code.x + 1, code.y + 41, code.w - 2, code.h - 42}}) {
		LH :: 21
		f := mono(14)
		scroll := 22 + lt * 2.2 // lines
		first := int(scroll)
		frac := scroll - f32(first)
		run := first + 12 + int(math.mod(t * 8, 3))
		for row in 0 ..< 28 {
			li := first + row
			if li < 0 || li >= len(source_lines) do continue
			y := code.y + 50 + (f32(row) - frac) * LH
			if li == run do fx.rect({code.x + 1, y - 2, code.w - 2, LH}, fx.alpha(CLAY, 0.16))
			fx.label(fmt.tprintf("%d", li + 1), {code.x + 44, y}, f, bone(li == run ? 0.7 : 0.22), {1, 0})
			code_line(source_lines[li], code.x + 56, y, f, 1, 44)
		}
	}

	// ---- scenes
	list := fx.Rect{1464, 86, 432, 580}
	fx.rrect(list, 10, 0xff12100f)
	fx.border(list, bone(0.1), 1, 10)
	fx.label("SCENES", {list.x + 16, list.y + 13}, caps(13, 0.22), bone(0.5))
	fx.label(fmt.tprintf("t = %05.2f", t), {list.x + list.w - 16, list.y + 11}, fx.Font{family = "JBM", size = 15, tabular = true}, fx.alpha(CLAY, 0.95), {1, 0})
	fx.hline(list.x, list.y + 40, list.w, bone(0.1))
	for s, i in SCENES {
		y := list.y + 50 + f32(i) * 43
		on := t >= s.start && t < s.start + s.dur
		done := t >= s.start + s.dur
		row := fx.Rect{list.x + 10, y, list.w - 20, 37}
		if on {
			fx.rrect(row, 7, fx.alpha(CLAY, 0.16))
			fx.rrect({row.x, row.y + row.h - 3, row.w * (t - s.start) / s.dur, 3}, 1.5, CLAY)
		}
		fx.label(fmt.tprintf("%02d", i + 1), {row.x + 12, y + 18}, mono(15), bone(0.3), {0, 0.5})
		fx.label(s.name, {row.x + 50, y + 18}, mono(17, on ? 500 : 400), on ? BONE : bone(done ? 0.4 : 0.66), {0, 0.5})
		fx.label(fmt.tprintf("%05.2f", s.start), {row.x + row.w - 12, y + 18}, fx.Font{family = "JBM", size = 15, tabular = true}, bone(on ? 0.9 : 0.3), {1, 0.5})
	}

	// ---- timeline: scenes, the score's loudness, its notes
	tl := fx.Rect{24, 690, W - 48, 366}
	fx.rrect(tl, 10, 0xff12100f)
	fx.border(tl, bone(0.1), 1, 10)
	x_of :: proc(tl: fx.Rect, t: f32) -> f32 {return tl.x + 12 + (tl.w - 24) * t / LENGTH}
	for b in 0 ..= BARS {
		x := x_of(tl, f32(b) * BAR)
		fx.vline(x, tl.y + 8, b % 4 == 0 ? 16 : 8, bone(b % 4 == 0 ? 0.4 : 0.18))
		if b % 4 == 0 && b < BARS do fx.label(fmt.tprintf("%d", b + 1), {x + 6, tl.y + 6}, mono(13), bone(0.4))
	}
	TINTS := [?]fx.Color{CLAY, GOLD, VIOLET, TEAL, ROSE, EMBER}
	for s, i in SCENES {
		x0, x1 := x_of(tl, s.start), x_of(tl, s.start + s.dur)
		on := t >= s.start && t < s.start + s.dur
		c := TINTS[i % len(TINTS)]
		r := fx.Rect{x0 + 1, tl.y + 34, x1 - x0 - 2, 52}
		fx.rrect(r, 6, fx.alpha(c, on ? 0.6 : 0.2))
		fx.border(r, fx.alpha(c, on ? 1 : 0.5), 1.2, 6)
		if r.w > 90 do fx.label(s.name, {r.x + 10, r.y + 26}, mono(15, 500), fx.alpha(BONE, on ? 1 : 0.6), {0, 0.5})
	}
	// loudness, mirrored like a waveform
	sg := song()
	wy := tl.y + 164
	for px := 0; px < int(tl.w - 24); px += 3 {
		tt := f32(px) / (tl.w - 24) * LENGTH
		v := fx.level_at(sg.level, tt)
		h := 4 + 130 * v
		fx.rect({tl.x + 12 + f32(px), wy - h / 2, 2, h}, fx.alpha(tt <= t ? GOLD : BONE, tt <= t ? 0.85 : 0.25))
	}
	// the melody and the kicks as a piano roll
	ry := tl.y + 252
	for n in ev().lead {
		x := x_of(tl, n.t)
		y := ry + 76 - (n.midi - 60) * 3
		fx.rect({x, y, max((tl.w - 24) * n.dur / LENGTH, 2), 3}, fx.alpha(TEAL, n.t <= t ? 1 : 0.4))
	}
	for kt in ev().kicks do fx.rect({x_of(tl, kt), ry + 88, 2, 9}, fx.alpha(CLAY, kt <= t ? 1 : 0.4))
	// the playhead
	px := x_of(tl, t)
	fx.vline(px, tl.y + 4, tl.h - 8, CLAY, 2)
	fx.rrect({px - 7, tl.y + 2, 16, 10}, 3, CLAY)

	// ---- the preview: this, again
	p := PREVIEW
	fx.shadow(p, 6, 0, 40, 0, 0x80000000)
	if fx.group({clip = p, radius = 6}) {
		if fx.group({x = p.x, y = p.y, s = p.w / W, origin = {0, 0}}) {
			if depth < DEPTH do function_frame(t, depth + 1)
			else do fx.rect(fx.stage(), 0xff0c0b0a)
		}
	}
	fx.border({p.x - 1, p.y - 1, p.w + 2, p.h + 2}, bone(0.25), 1.5, 7)
	fx.label("PREVIEW", {p.x, p.y - 24}, caps(13, 0.22), bone(0.5), {0, 0})
	fx.label(fmt.tprintf("depth %d", depth), {p.x + p.w, p.y - 24}, mono(14), bone(0.4), {1, 0})
}

// What the film shows during this scene, at any depth of the recursion.
function_frame :: proc(t: f32, depth: int) {
	sc := SCENES[len(SCENES) - 2]
	s := fx.Shot{t = t, lt = t - sc.start, p = (t - sc.start) / sc.dur, start = sc.start, dur = sc.dur}
	// the first moment still shows what came before
	arrive := fx.ep(s.lt, 0.45, 1.0, fx.ease_in_out)
	editor(t, depth)
	if arrive < 1 && depth >= 1 {
		if fx.group({o = 1 - arrive}) do this_frame(t, t - bar(24), 1)
	}
	say(s, {{"No camera. No footage. No samples.", BEAT * 3}, {"Every pixel and every sound is a function of time.", BAR + BEAT * 2}, {"I wrote the function.", BAR * 2 + BEAT * 3}}, out = 0.7, scrim = 0.96)
}

function :: proc(s: fx.Shot) {
	lt := s.lt
	// out of the preview at first: what looked like the film was the pane
	out := 1 - fx.ep(lt, 0.05, 1.05, fx.ease_out5)
	// then slowly back toward it, and at the end all the way down
	dive := fx.ep(lt, s.dur - 1.1, s.dur, fx.ease_in)
	zoom := math.pow(f32(2), out) * (1 + 0.02 * fx.prog(lt, 1, s.dur)) * math.pow(f32(2), dive * 3.4)
	if fx.group({s = zoom, origin = FIXED}) {
		function_frame(s.t, 0)
	}
	fx.flash(fx.ep(lt, s.dur - 0.3, s.dur, fx.ease_in), BONE)
}
