// Fable 5.2 — a self-portrait. One minute, eight scenes, cut to a score that
// is rendered by the same code (music.odin). No footage, no images, no
// samples: every pixel and every sound is computed from t.
package fable

import "core:fmt"
import "core:math"
import fx "effects:fx"

@(export)
effects_video :: proc() -> ^fx.Video {
	v := fx.video(
		{
			name = "Fable 5.2",
			fps = 60,
			duration = LENGTH,
			background = INK,
			sounds = SOUNDS[:],
			scenes = SCENES[:],
			marks = ev().kicks[:],
			master = master,
			overlay = overlay,
		},
	)
	// Fraunces (SIL Open Font License), the storyteller's voice next to the machine's mono
	for f in ([?]string{"Light", "LightItalic", "Regular", "Italic", "SemiBoldItalic"}) {
		fx.font("FR", fmt.tprintf("assets/fonts/Fraunces144pt-%s.ttf", f))
	}
	return v
}

SOUNDS := [?]fx.Sound{{name = "score", gen = music, dur = LENGTH}}

SCENES := [?]fx.Scene {
	{name = "prompt", start = 0, dur = BAR * 4, draw = prompt},
	{name = "attention", start = BAR * 4, dur = BAR * 4, draw = attention},
	{name = "latent", start = BAR * 8, dur = BAR * 4, draw = latent},
	{name = "reasoning", start = BAR * 12, dur = BAR * 4, draw = reasoning},
	{name = "title", start = BAR * 16, dur = BAR * 2, draw = title},
	{name = "code", start = BAR * 18, dur = BAR, draw = make_code},
	{name = "proof", start = BAR * 19, dur = BAR, draw = make_proof},
	{name = "poem", start = BAR * 20, dur = BAR * 2, draw = make_poem},
	{name = "sound", start = BAR * 22, dur = BAR, draw = make_sound},
	{name = "this", start = BAR * 23, dur = BAR, draw = make_this},
	{name = "function", start = BAR * 24, dur = BAR * 4, draw = function},
	{name = "outro", start = BAR * 28, dur = BAR * 4, draw = outro},
}

// ---------------------------------------------------------------- look

INK : fx.Color : 0xff0a0908
BONE : fx.Color : 0xfff3eee3
CLAY : fx.Color : 0xffd97757
EMBER : fx.Color : 0xffff9f6e
GOLD : fx.Color : 0xffffcf86
VIOLET : fx.Color : 0xff9a86ff
TEAL : fx.Color : 0xff62e6d2
ROSE : fx.Color : 0xffff6f91

W :: 1920
H :: 1080
MARGIN :: 96
MID :: fx.Vec2{W / 2, H / 2}

mono :: proc(size: f32, weight: f32 = 400, tracking: f32 = 0) -> fx.Font {return fx.mono(size, weight, tracking)}
caps :: proc(size: f32, tracking: f32 = 0.2) -> fx.Font {return fx.caps(size, tracking, 500)}
serif :: proc(size: f32, italic := true, weight: f32 = 300) -> fx.Font {
	return {family = "FR", size = size, weight = weight, italic = italic, tracking = -0.012, lh = 1.08}
}
grotesk :: proc(size: f32, weight: f32 = 600, tracking: f32 = -0.03) -> fx.Font {return fx.sans(size, weight, tracking)}

bone :: proc(a: f32) -> fx.Color {return fx.alpha(BONE, a)}

// 1 on every kick of the score, falling to 0.
kick :: proc(t: f32, dur: f32 = 0.32) -> f32 {return fx.pulse(ev().kicks[:], t, dur)}
// The soft double beat of the second section.
heart :: proc(t: f32, dur: f32 = 0.4) -> f32 {return fx.pulse(ev().hearts[:], t, dur)}
// Sixteenths since the start of the piece.
steps :: proc(t: f32) -> f32 {return t / STEP}
// How far through the current beat, 0..1.
beat_phase :: proc(t: f32) -> f32 {return math.mod(t, BEAT) / BEAT}

// The film's lens: bloom and streaks on everything bright, a little barrel
// distortion with color fringes that the kick widens, and the punch-ins of
// the drop.
master :: proc(t: f32) -> fx.Xf {
	k := kick(t)
	drop := t >= bar(17) && t < bar(29) ? f32(1) : 0
	hit := fx.hit(t, bar(17), 1.1) // the drop itself
	xf := fx.Xf {
		origin = MID,
		s      = 1 + 0.014 * k * drop + 0.05 * fx.hit(t, bar(17), 0.5),
		glow   = {radius = 20, amount = 0.45 + 0.2 * k * drop + 0.5 * hit, threshold = 0.58, streak = 110, streak_amount = 0.4},
		post   = fx.lens(0.016, 1.5 + 5 * k * drop + 16 * hit, 0),
	}
	// the last bar of the build shakes itself apart
	b := fx.ep(t, bar(15), bar(17), fx.ease_in)
	if t < bar(17) && b > 0 {
		sh := fx.shake(t, 9 * b * b, 22)
		xf.x, xf.y = sh.x, sh.y
	}
	// the wave of the drop
	if t >= bar(17) && t < bar(17) + 1.2 {
		p := fx.prog(t, bar(17), bar(17) + 1.2)
		xf.post = fx.shockwave(MID, fx.ease_out(p) * 1500, 130, 70 * (1 - p))
	}
	return xf
}

// Above the lens: the frame of the film. Vignette, grain, and a hairline
// timeline at the bottom, because time is the only input.
overlay :: proc(t: f32) {
	fx.vignette(0.5)
	a := fx.win(t, 0.6, LENGTH - 1.2, 1.2, 1)
	if a > 0.003 {
		y: f32 = H - 54
		fx.hline(MARGIN, y, W - 2 * MARGIN, bone(0.1 * a))
		fx.hline(MARGIN, y, (W - 2 * MARGIN) * t / LENGTH, bone(0.55 * a))
		for s in SCENES {
			x := MARGIN + (W - 2 * MARGIN) * s.start / LENGTH
			fx.vline(x, y - 4, 9, bone((t >= s.start ? 0.6 : 0.2) * a))
		}
		fx.label(fmt.tprintf("t = %05.2f s", t), {W - MARGIN, y - 14}, fx.Font{family = "JBM", size = 15, tabular = true, tracking = 0.04}, bone(0.42 * a), {1, 1})
		fx.label("FABLE 5.2", {MARGIN, y - 14}, caps(14, 0.24), bone(0.42 * a), {0, 1})
	}
	fx.grain(0.032)
}

// ---------------------------------------------------------------- shared pieces

// The chapter mark in the top-left corner: number, hairline, name.
chapter :: proc(s: fx.Shot, num, name: string, fi: f32 = 0.5) {
	a := fx.win(s.t, s.start + 0.25, s.start + s.dur - 0.1, fi, 0.35)
	if a <= 0.003 do return
	x, y: f32 = MARGIN, 74
	k := fx.ep(s.t, s.start + 0.25, s.start + 1.1, fx.ease_out5)
	r := fx.label(num, {x, y}, caps(15, 0.24), fx.alpha(CLAY, a))
	fx.hline(x + r.w + 14, y + 9, 46 * k, bone(0.35 * a))
	fx.label(fx.scramble(name, fx.prog(s.t, s.start + 0.3, s.start + 0.9), 7), {x + r.w + 74, y}, caps(15, 0.24), bone(0.7 * a))
}

Line :: struct {
	text: string,
	t:    f32, // seconds into the scene
}

// The film's voice: serif lines in the lower left, each rising in on its cue.
say :: proc(s: fx.Shot, lines: []Line, size: f32 = 58, y: f32 = H - 150, out: f32 = 0.45, scrim: f32 = 0.74) {
	f := serif(size)
	lh := size * 1.2
	y0 := y - lh * f32(len(lines))
	leave := fx.ep(s.t, s.start + s.dur - out, s.start + s.dur, fx.ease_in2)
	// a shadow to read on, as wide as what has been said so far
	if len(lines) > 0 && s.t > s.start + lines[0].t {
		shade := fx.ep(s.t, s.start + lines[0].t, s.start + lines[0].t + 0.8) * (1 - leave)
		wide: f32
		for l in lines do if s.t >= s.start + l.t do wide = max(wide, fx.measure(l.text, f).x)
		fx.ellipse_gradient({0, y0 - 160, wide + 560, H - y0 + 160}, {MARGIN + wide * 0.45, y0 + lh * f32(len(lines)) / 2}, wide * 0.5 + 280, lh * f32(len(lines)) / 2 + 150, {{fx.alpha(0xff050404, scrim * shade), 0}, {fx.alpha(0xff050404, scrim * (scrim > 0.9 ? 0.95 : 0.68) * shade), 0.5}, {0x00050404, 1}})
	}
	for l, i in lines {
		t0 := s.start + l.t
		if s.t < t0 do continue
		a := (1 - leave)
		fx.letters(l.text, {MARGIN, y0 + f32(i) * lh - 14 * leave}, f, bone(0.96 * a), {t0 = t0, step = 0.014, dur = 0.7, rise = 22, blur = 10}, {0, 0})
	}
}

// A slow field of filaments behind a scene.
field :: proc(t: f32, level: f32, mid: fx.Color = CLAY, hot: fx.Color = BONE, scale: f32 = 1, seed: f32 = 0, flow := fx.Vec2{0.012, -0.006}) {
	fx.nebula(fx.stage(), t, {deep = INK, mid = fx.mix(0xff000000, mid, 0.55), hot = hot, level = level, scale = scale, seed = seed, flow = flow, detail = 0.55})
}
