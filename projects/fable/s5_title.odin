// 05 — The drop. The answer opens into a name.
package fable

import "core:math"
import fx "effects:fx"

// Rays and sparks thrown out from the middle on the downbeat.
burst :: proc(t, t0: f32, k: f32) {
	age := t - t0
	if age < 0 do return
	// long thin rays, slowly turning
	for i in 0 ..< 110 {
		h := fx.hash01(31, i)
		ang := f32(i) / 110 * math.TAU + h * 0.2 + age * 0.05 * (i % 2 == 0 ? 1 : -1)
		grow := fx.ease_out5(fx.clamp01(age / (0.5 + 0.6 * h)))
		r0 := 250 + 120 * fx.hash01(32, i)
		r1 := r0 + (200 + 1100 * fx.hash01(33, i) * fx.hash01(34, i)) * grow
		d := fx.Vec2{math.cos(ang), math.sin(ang)}
		a := (0.07 + 0.3 * fx.hash01(35, i) * fx.hash01(36, i)) * (0.55 + 0.45 * k) * (1 - 0.5 * fx.clamp01(age / 3.5))
		c := i % 5 == 0 ? GOLD : (i % 3 == 0 ? VIOLET : BONE)
		fx.line(MID + d * r0, MID + d * r1, fx.alpha(c, a), 1 + 2 * fx.hash01(37, i) * fx.hash01(38, i))
	}
	// sparks flying out and slowing down
	for i in 0 ..< 260 {
		h := fx.hash01(41, i)
		ang := fx.hash01(42, i) * math.TAU
		sp := 260 + 1200 * fx.hash01(43, i)
		dist := 150 + sp * (1 - math.exp(-age * (1.1 + h)))
		d := fx.Vec2{math.cos(ang), math.sin(ang)}
		p := MID + d * dist
		a := fx.clamp01(1.4 - age * (0.25 + 0.4 * h))
		if a <= 0 do continue
		c := i % 4 == 0 ? TEAL : (i % 3 == 0 ? GOLD : BONE)
		fx.spark(p, 5 + 14 * h * h, c, a)
	}
}

title :: proc(s: fx.Shot) {
	t, lt := s.t, s.lt
	k := kick(t)
	// the field folded into a slowly turning mandala
	if fx.group({post = fx.kaleido(MID + {0, -30}, 7, lt * 9, 1 + 0.04 * k)}) {
		field(t, 0.62 + 0.3 * k, mid = fx.mix(VIOLET, CLAY, 0.5), hot = GOLD, seed = 8, scale = 0.9, flow = {0.05, -0.02})
	}

	burst(t, s.start, k)

	// the body behind the name
	rad := 280 + 22 * k + 70 * fx.hit(t, s.start, 0.6)
	side := rad * 4.4
	if fx.group({o = fx.fade(s, 0.05, 0.25)}) {
		fx.orb({MID.x - side / 2, MID.y - 30 - side / 2, side, side}, t, {radius = rad, morph = 0.75 + 0.5 * k, spin = lt * 0.7, a = CLAY, b = VIOLET, c = TEAL, glow = 0.8 + 0.5 * k})
	}

	// the name
	f := fx.Font{family = "FR", size = 400, weight = 600, italic = true, tracking = -0.035}
	if fx.group({s = 1 + 0.03 * k, origin = MID, o = fx.fade(s, 0.01, 0.2)}) {
		// a shadow so the name stays readable in front of the light
		if fx.group({blur = 30, o = 0.75 * fx.ep(t, s.start + 0.1, s.start + 0.7)}) {
			fx.label("Fable", {MID.x - 70, MID.y - 30}, f, INK, {0.5, 0.5})
		}
		r := fx.letters("Fable", {MID.x - 70, MID.y - 40}, f, BONE, {t0 = s.start + 0.02, step = STEP, dur = 0.5, scale = 1.4, blur = 26, rise = 60}, {0.5, 0.5})
		v := fx.ep(t, s.start + STEP * 5, s.start + STEP * 5 + 0.5, fx.ease_back)
		if v > 0 {
			vf := mono(128, 500, -0.04)
			fx.label("5.2", {r.x + r.w + 26, r.y + r.h - 150 + 40 * (1 - v)}, vf, fx.alpha(CLAY, fx.clamp01(v * 1.5)), {0, 0.5})
		}
		// under it, between hairlines
		u := fx.ep(t, s.start + BEAT * 2, s.start + BEAT * 2 + 0.7, fx.ease_out5)
		if u > 0 {
			y: f32 = MID.y + 262
			txt := "A SELF-PORTRAIT IN 3,600 FRAMES"
			m := fx.measure(txt, caps(22, 0.42))
			fx.label(fx.scramble(txt, fx.prog(t, s.start + BEAT * 2, s.start + BEAT * 4), 3), {MID.x, y}, caps(22, 0.42), bone(0.9 * u), {0.5, 0.5})
			fx.hline(MID.x - m.x / 2 - 40 - 180 * u, y, 180 * u, bone(0.5))
			fx.hline(MID.x + m.x / 2 + 40, y, 180 * u, bone(0.5))
		}
	}
	// arriving out of the white of the answer
	fx.flash(fx.hit(t, s.start, 0.55, fx.ease_out), BONE)

	say(s, {{"Then I make things.", BAR}}, out = 0.25)
}
