// 01 — Prompt. Text arrives, is cut into tokens, and the tokens become
// numbers.
package fable

import "core:fmt"
import "core:math"
import fx "effects:fx"

TOKENS := [?]string{"who", " are", " you", "?"}
TOKEN_IDS := [?]string{"14965", "389", "481", "30"}
DIMS :: 44 // cells drawn per embedding row

prompt :: proc(s: fx.Shot) {
	t := s.t
	// the field wakes up
	field(t, 0.1 + 0.5 * fx.ep(t, 2.6, 7.5, fx.ease_in_out) + 0.6 * fx.ep(t, 6.6, 7.5, fx.ease_in), seed = 1)
	chapter(s, "01", "PROMPT", 1.2)

	f := mono(76, 500)
	adv := fx.measure("0", f).x
	full := fmt.tprintf("> %s", PROMPT)
	x0 := MID.x - adv * f32(len(full)) / 2
	y0: f32 = 440

	t_enter := bar(2, 8) // return is pressed
	t_split := t_enter + 0.12
	t_embed := bar(3)
	t_fly := bar(4)

	// ---- the prompt being typed
	typed := int(math.floor((t - PROMPT_T0) / STEP)) + 1
	typed = clamp(typed, 0, len(PROMPT))
	if t < t_embed + 0.5 {
		gone := fx.ep(t, t_split, t_split + 0.3)
		fx.text(">", x0, y0, f, fx.alpha(CLAY, fx.ep(t, 0.3, 0.9) * (1 - gone)))
		// the cursor: blinking while idle, solid while typing
		if t < t_enter {
			blink := typed > 0 && typed < len(PROMPT) ? true : math.mod(t, BEAT * 2) < BEAT
			cx := x0 + adv * f32(2 + typed)
			if blink && t > 0.3 do fx.rect({cx + 4, y0 + 10, adv * 0.62, 82}, CLAY)
		}
	}

	// ---- tokens: where each sits typed, spread apart, and as a row label
	col := 2
	n := len(TOKENS)
	ROW_H :: 62
	grid_x: f32 = 560
	grid_y := MID.y - ROW_H * f32(n) / 2 - 20
	cell: f32 = (W - grid_x - 300) / DIMS
	fly := fx.ep(t, t_fly, t_fly + 1.7, fx.ease_in)
	for tok, i in TOKENS {
		chars := len(tok)
		shown := clamp(typed - (col - 2), 0, chars)
		typed_x := x0 + adv * f32(col)
		col += chars
		if shown == 0 do continue
		split := fx.spring(fx.prog(t, t_split + f32(i) * 0.05, t_split + f32(i) * 0.05 + 0.9), 1.6, 0.6)
		spread_x := typed_x + (f32(i) - 1.5) * 76 * split
		emb := fx.ep(t, t_embed + f32(i) * 0.09, t_embed + f32(i) * 0.09 + 0.7, fx.ease_in_out)
		row_y := grid_y + f32(i) * ROW_H
		trimmed := tok[0] == ' ' ? tok[1:] : tok
		lead: f32 = tok[0] == ' ' ? adv : 0
		w := adv * f32(len(trimmed))
		// position: typed → spread → row label (right-aligned before the grid)
		px := fx.lerp(spread_x + lead, grid_x - 40 - w, emb)
		py := fx.lerp(y0, row_y - 24, emb)
		sc := fx.lerp(1, 0.5, emb)
		a := 1 - fly
		if fx.group({s = sc, origin = {px + w, py + 50}, o = a}) {
			fx.text(trimmed[:min(shown - (len(tok) - len(trimmed)), len(trimmed))] if shown > len(tok) - len(trimmed) else "", px, py, f, BONE)
			// the token's box and id
			b := fx.ep(t, t_split + f32(i) * 0.05, t_split + f32(i) * 0.05 + 0.35)
			if b > 0 {
				r := fx.Rect{px - 16, py - 4, w + 32, 110}
				fx.border(r, fx.alpha(CLAY, 0.9 * b * (1 - 0.6 * emb)), 2, 10)
				fx.rrect(r, 10, fx.alpha(CLAY, 0.07 * b))
				id := fx.scramble(TOKEN_IDS[i], fx.prog(t, t_split + 0.1 + f32(i) * 0.08, t_split + 0.6 + f32(i) * 0.08), u32(i) + 3, set = "0123456789")
				fx.label(id, {px + w / 2, py + 124}, mono(22, 400, 0.06), fx.alpha(CLAY, b * (1 - emb)), {0.5, 0})
			}
		}

		// ---- the row of numbers this token becomes
		if emb <= 0 do continue
		for d in 0 ..< DIMS {
			k := fx.ep(t, t_embed + f32(i) * 0.09 + f32(d) * 0.016, t_embed + f32(i) * 0.09 + f32(d) * 0.016 + 0.3)
			if k <= 0 do continue
			v := fx.hash01(u32(i) * 17 + 5, d)
			// values flicker as they settle
			if k < 1 do v = fx.hash01(u32(i) * 17 + 5 + u32(t * 30), d)
			c := v < 0.5 ? fx.mix(0xff2a1712, CLAY, v * 2) : fx.mix(CLAY, BONE, (v - 0.5) * 2)
			home := fx.Vec2{grid_x + f32(d) * cell, row_y}
			idx := i * DIMS + d
			// then each number leaves for the center on its own spiral
			q := fx.ep(t, t_fly + fx.hash01(11, idx) * 0.7, t_fly + 0.75 + fx.hash01(11, idx) * 0.7, fx.ease_in_out)
			p := home
			size := (cell - 5) * k
			if q > 0 {
				rel := home - MID
				ang := q * (2.2 + 2.5 * fx.hash01(13, idx)) * (idx % 2 == 0 ? 1 : -1)
				sn, cs := math.sincos(ang)
				rel = fx.Vec2{rel.x * cs - rel.y * sn, rel.x * sn + rel.y * cs} * (1 - q)
				p = MID + rel
				size *= 1 - 0.75 * q
			}
			fx.rrect({p.x + (cell - 5 - size) / 2, p.y + (cell - 5 - size) / 2 + 12, size, size}, 3, fx.alpha(c, k * (0.35 + 0.65 * v)))
		}
	}
	// brackets around the matrix, and what it is
	m := fx.ep(t, t_embed + 0.5, t_embed + 1.1) * (1 - fx.ep(t, t_fly, t_fly + 0.4))
	if m > 0 {
		gx0, gx1 := grid_x - 16, grid_x + DIMS * cell + 8
		gy0, gy1 := grid_y - 2, grid_y + ROW_H * f32(n) - 6
		c := bone(0.5 * m)
		fx.vline(gx0, gy0, gy1 - gy0, c, 2); fx.hline(gx0, gy0, 14, c, 2); fx.hline(gx0, gy1 - 2, 14, c, 2)
		fx.vline(gx1, gy0, gy1 - gy0, c, 2); fx.hline(gx1 - 12, gy0, 14, c, 2); fx.hline(gx1 - 12, gy1 - 2, 14, c, 2)
		fx.label("4 tokens × many dimensions", {gx1, gy1 + 22}, mono(19, 400, 0.04), bone(0.5 * m), {1, 0})
	}

	// ---- everything arrives at one point
	core := fx.ep(t, t_fly + 0.5, bar(5), fx.ease_in)
	if core > 0 {
		fx.spark(MID, 40 + 420 * core * core, EMBER, 0.9 * core)
		fx.spark(MID, 14 + 60 * core, BONE, core)
	}

	say(s, {{"I begin as text.", bar(2, 10)}, {"Then the text becomes numbers.", bar(3, 2)}})
	// out: a flash into the next scene
	fx.flash(fx.ep(t, bar(5) - 0.12, bar(5), fx.ease_in) * 0.9, BONE)
}
