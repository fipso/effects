// 04 — Reasoning. A tree of attempts grows; most branches fail and are
// crossed out; one path holds.
package fable

import "core:math"
import "core:sync"
import fx "effects:fx"
import sk "effects:sk"

Node :: struct {
	p:      fx.Vec2,
	parent: int,
	chosen: bool,
	show:   f32, // seconds into the scene
	fail:   f32, // when a dead end is given up (0 = never)
	label:  string,
}

LEVELS :: 7
@(private = "file")
tree: [dynamic]Node
@(private = "file")
tree_once: sync.Once

STEPS_LABELS := [LEVELS]string{"", "restate", "decompose", "try", "check", "refine", "holds."}
FAILS := [?]string{"too slow", "off by one", "assumes too much", "contradiction", "not what was asked", "too clever", "circular", "untested", "vague", "wrong units", "unfalsifiable", "breaks at zero"}

level_time :: proc(d: int) -> f32 {return 0.2 + f32(d) * BEAT * 2}

reasoning_tree :: proc() -> []Node {
	sync.once_do(&tree_once, proc() {
		ys := [LEVELS]f32{470, 360, 440, 560, 470, 370, 450}
		prev := -1
		fails := 0
		for d in 0 ..< LEVELS {
			x := 250 + f32(d) * 232
			append(&tree, Node{p = {x, ys[d]}, parent = prev, chosen = true, show = level_time(d), label = STEPS_LABELS[d]})
			me := len(tree) - 1
			// the attempts made from the node before, tried first and given up
			if d > 0 && d < LEVELS - 1 || d == LEVELS - 1 {
				for sgn, k in ([2]f32{-1, 1}) {
					if d == LEVELS - 1 && k == 1 do continue
					off := sgn * (125 + 60 * fx.hash01(3, d * 2 + k))
					y := ys[d] + off
					if y < 190 || y > 760 do y = ys[d] - off * 0.9
					show := level_time(d) - 0.42 + f32(k) * 0.18
					fail := show + 0.75 + 0.3 * fx.hash01(5, d * 2 + k)
					append(&tree, Node{p = {x - 12 + 24 * fx.hash01(9, d * 2 + k), y}, parent = prev, show = show, fail = fail})
					sib := len(tree) - 1
					// some go one step deeper before failing
					if d < LEVELS - 1 && fx.hash01(7, d * 2 + k) < 0.7 {
						kids := 1 + int(fx.hash01(8, d * 2 + k) * 2)
						for c in 0 ..< kids {
							yy := y + (f32(c) - f32(kids - 1) / 2) * 76 + sgn * 34
							append(&tree, Node{p = {x + 150 + 40 * fx.hash01(10, d * 4 + k * 2 + c), yy}, parent = sib, show = show + 0.3 + 0.1 * f32(c), fail = fail + 0.25, label = FAILS[fails % len(FAILS)]})
							fails += 1
						}
					} else {
						tree[sib].label = FAILS[fails % len(FAILS)]
						fails += 1
					}
				}
			}
			prev = me
		}
	})
	return tree[:]
}

@(private = "file")
edge :: proc(a, b: fx.Vec2) -> ^sk.Path {
	path := sk.path_new()
	dx := (b.x - a.x) * 0.5
	sk.path_move_to(path, a.x, a.y)
	sk.path_cubic_to(path, a.x + dx, a.y, b.x - dx, b.y, b.x, b.y)
	return path
}
@(private = "file")
edge_at :: proc(a, b: fx.Vec2, p: f32) -> fx.Vec2 {
	dx := (b.x - a.x) * 0.5
	return {fx.bez(p, a.x, a.x + dx, b.x - dx, b.x), fx.bez(p, a.y, a.y, b.y, b.y)}
}

reasoning :: proc(s: fx.Shot) {
	t, lt := s.t, s.lt
	nodes := reasoning_tree()
	field(t, 0.24, mid = fx.mix(CLAY, GOLD, 0.3), seed = 5, scale = 1.3)
	chapter(s, "04", "REASONING")

	final := nodes[0].p
	for n in nodes do if n.chosen do final = n.p
	t_done := level_time(LEVELS - 1) + 0.35
	// the camera drifts in, then falls into the answer
	dive := fx.ep(lt, s.dur - 1.35, s.dur, fx.ease_in)
	zoom := (1 + 0.05 * fx.prog(lt, 0, s.dur)) * math.pow(f32(42), dive)
	focus := fx.lerp2({MID.x, 470}, final, fx.ep(lt, t_done - 0.4, s.dur - 0.5, fx.ease_in_out))
	if fx.group({s = zoom, origin = focus, x = (MID.x - focus.x) * dive, y = (MID.y - focus.y) * dive}) {
		// ---- branches
		for n, i in nodes {
			if n.parent < 0 || lt < n.show do continue
			a := nodes[n.parent].p
			grow := fx.ep(lt, n.show, n.show + 0.32, fx.ease_out)
			path := edge(a, n.p)
			defer sk.path_free(path)
			if n.chosen {
				lit := 0.75 + 0.25 * math.sin(t * 5 - f32(i))
				fx.draw_path(path, fx.trimmed(fx.soft(fx.additive(fx.stroke(fx.alpha(GOLD, 0.5 * lit), 12)), 7), 0, grow))
				fx.draw_path(path, fx.trimmed(fx.additive(fx.stroke(fx.mix(GOLD, BONE, 0.4), 3.2)), 0, grow))
			} else {
				dead := fx.ep(lt, n.fail, n.fail + 0.3)
				gone := fx.ep(lt, t_done - 0.5 + 0.3 * fx.hash01(21, i), t_done + 0.2 + 0.3 * fx.hash01(21, i))
				c := fx.mix(BONE, ROSE, dead * 0.7)
				p := fx.stroke(fx.alpha(c, (0.55 - 0.38 * dead) * (1 - gone)), 1.8)
				if dead > 0.5 do p.dash = {5, 7}
				fx.draw_path(path, fx.trimmed(p, 0, grow * (1 - gone)))
			}
		}
		// ---- light running along the chosen path, one pulse a beat
		chain: [LEVELS]fx.Vec2
		for n in nodes do if n.chosen {
			d := int(math.round((n.p.x - 250) / 232))
			chain[d] = n.p
		}
		reached := fx.clamp01((lt - level_time(0)) / (level_time(LEVELS - 1) - level_time(0))) * f32(LEVELS - 1)
		for pulse in 0 ..< 3 {
			u := math.mod(lt / (BEAT * 2) + f32(pulse) / 3, 1) * reached
			seg := min(int(u), LEVELS - 2)
			if f32(seg) >= reached do continue
			q := edge_at(chain[seg], chain[seg + 1], u - f32(seg))
			fx.spark(q, 22, BONE, 0.9 * (1 - dive))
		}
		// ---- nodes and what they say
		for n, i in nodes {
			if lt < n.show + 0.25 do continue
			k := fx.ep(lt, n.show + 0.25, n.show + 0.55, fx.ease_back)
			if n.chosen {
				last := n.p == final
				r: f32 = (last ? 15 : 10) * k
				fx.spark(n.p, 60 * k + (last ? 60 * fx.ep(lt, t_done, s.dur) : 0), GOLD, 0.7)
				fx.circle(n.p, r, last ? BONE : GOLD)
				if n.parent < 0 {
					fx.ring(n.p, 30, fx.alpha(GOLD, 0.8), 2)
					fx.label("?", n.p + {-64, -2}, serif(64, true, 400), GOLD, {0.5, 0.5})
				}
				if n.label != "" {
					fx.label(fx.scramble(n.label, fx.prog(lt, n.show + 0.2, n.show + 0.6), u32(i)), n.p + {0, -46}, mono(24, 500, 0.02), fx.alpha(BONE, k * (1 - dive)), {0.5, 0.5})
				}
				continue
			}
			dead := fx.ep(lt, n.fail, n.fail + 0.25)
			gone := fx.ep(lt, t_done - 0.5 + 0.3 * fx.hash01(21, i), t_done + 0.2 + 0.3 * fx.hash01(21, i))
			a := (1 - gone)
			if a <= 0.01 do continue
			c := fx.mix(BONE, ROSE, dead)
			fx.ring(n.p, 7 * k, fx.alpha(c, (0.8 - 0.3 * dead) * a), 1.8)
			if dead > 0 {
				// crossed out
				d: f32 = 9 * dead
				fx.line(n.p - {d, d}, n.p + {d, d}, fx.alpha(ROSE, 0.9 * a), 2)
				fx.line(n.p + {-d, d}, n.p + {d, -d}, fx.alpha(ROSE, 0.9 * a), 2)
				if n.label != "" do fx.label(n.label, n.p + {20, 0}, mono(18, 400, 0.02), fx.alpha(ROSE, 0.75 * dead * a), {0, 0.5})
			}
		}
	}
	fx.flash(1 - fx.ep(lt, 0, 0.35), INK)
	// the answer swallows the frame; the drop takes over from white
	fx.flash(fx.ep(lt, s.dur - 0.5, s.dur, fx.ease_in), BONE)

	say(s, {{"Before I answer, I wander.", BEAT}, {"Most paths fail.", BAR}, {"I keep the one that holds.", BAR * 2}}, out = 1.3)
}
