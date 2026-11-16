// 03 — Latent space. What was read became a place: clusters of meaning in
// the dark, and thinking is a path between them.
package fable

import "core:math"
import fx "effects:fx"

Cluster :: struct {
	name: string,
	c:    fx.Color,
}

CLUSTERS := [?]Cluster {
	{"love letters", ROSE},
	{"segfaults", TEAL},
	{"sonnets", GOLD},
	{"tax law", BONE},
	{"birdsong", TEAL},
	{"prime numbers", VIOLET},
	{"regret", CLAY},
	{"recipes", EMBER},
	{"git rebase", VIOLET},
	{"the color blue", 0xff7fb4ff},
	{"puns", GOLD},
	{"proofs", BONE},
}
PER :: 170
DUST :: 700

cluster_center :: proc(i: int) -> fx.Vec3 {
	p := fx.fib_sphere(i, len(CLUSTERS)) * (2.5 + 1.2 * fx.hash01(41, i))
	p.y *= 0.62
	return p
}

// The route a thought takes: from cluster to cluster.
ROUTE := [?]int{6, 2, 0, 9, 4, 11}

latent :: proc(s: fx.Shot) {
	t, lt := s.t, s.lt
	field(t, 0.2, mid = fx.mix(CLAY, VIOLET, 0.35), seed = 3, scale = 1.6)
	fx.flash(fx.hit(t, s.start, 0.4) * 0.5, BONE)
	chapter(s, "03", "LATENT SPACE")

	k := kick(t)
	born := fx.ep(t, s.start, s.start + 1.6, fx.ease_out5) // everything flies out of one point
	cam := fx.Cam {
		yaw    = 18 + 11 * lt,
		pitch  = 14 + 5 * math.sin(lt * 0.5),
		dist   = fx.lerp(10.5, 7.4, fx.ep(lt, 0, s.dur, fx.ease_in_out)) - 3 * fx.ep(lt, s.dur - 0.5, s.dur, fx.ease_in),
		fov    = 46,
		center = {MID.x + 60, MID.y - 30},
	}
	focus := cam.dist - 0.6

	// where the thought is
	route: [len(ROUTE)]fx.Vec3
	for r, i in ROUTE do route[i] = cluster_center(r)
	travel := fx.ep(lt, 1.3, s.dur - 0.5, fx.ease_in_out)
	head := fx.spline3(route[:], travel)

	// ---- dust between the clusters
	for i in 0 ..< DUST {
		p := fx.gauss3(77, i) * 3.4
		tw := 0.6 + 0.4 * math.sin(t * (1 + 2 * fx.hash01(5, i)) + f32(i))
		fx.bokeh(cam, p * born, 0.012, fx.alpha(BONE, 0.5 * tw), focus, 0.9)
	}
	// ---- the clusters
	for cl, ci in CLUSTERS {
		c0 := cluster_center(ci)
		near := 1 - fx.clamp01(fx.length3(head - c0) / 1.7) // the thought passing lights it up
		for i in 0 ..< PER {
			g := fx.gauss3(u32(ci) * 13 + 5, i)
			p := (c0 + g * (0.36 + 0.05 * k)) * born
			h := fx.hash01(u32(ci) + 91, i)
			col := h < 0.35 ? cl.c : fx.mix(BONE, cl.c, 0.35)
			a := (0.5 + 0.5 * h) * (0.55 + 0.3 * near + 0.25 * k)
			fx.bokeh(cam, p, 0.016 + 0.02 * h * h + 0.004 * near, fx.alpha(col, a), focus, 0.9)
		}
	}
	// ---- the path so far: a fading tail and a bright head
	if travel > 0 {
		SEG :: 90
		tail: f32 = 0.5
		prev := fx.spline3(route[:], max(travel - tail, 0))
		for i in 1 ..= SEG {
			u := f32(i) / SEG
			q := fx.spline3(route[:], max(travel - tail, 0) + (travel - max(travel - tail, 0)) * u)
			fx.line3(cam, prev * born, q * born, fx.additive(fx.soft(fx.stroke(fx.alpha(GOLD, u * u * 0.5), 3 + 9 * u), 5)))
			fx.line3(cam, prev * born, q * born, fx.additive(fx.stroke(fx.alpha(fx.mix(GOLD, BONE, u), u), 1.5 + 3 * u)))
			prev = q
		}
		if hp, ok := fx.project(cam, head * born); ok {
			fx.spark(hp.p, 70 + 30 * k, GOLD, 0.8)
			fx.spark(hp.p, 16, BONE, 1)
		}
	}
	// ---- names for the nearest clusters
	for cl, ci in CLUSTERS {
		c0 := cluster_center(ci) * born
		q, ok := fx.project(cam, c0)
		if !ok do continue
		depth := fx.clamp01(1 - (q.z - (cam.dist - 3.2)) / 4.5) // near = 1
		a := fx.ep(t, s.start + 0.9 + f32(ci) * 0.11, s.start + 1.5 + f32(ci) * 0.11) * fx.clamp01(depth * 2.2 - 0.5) * fx.fade(s, 0.1, 0.5)
		if a < 0.03 do continue
		near := 1 - fx.clamp01(fx.length3(head - cluster_center(ci)) / 1.7)
		side: f32 = q.p.x > cam.center.x ? 1 : -1
		elbow := q.p + {side * 46, -40}
		fx.line(q.p + {side * 8, -7}, elbow, bone(0.7 * a), 1.5)
		fx.hline(side > 0 ? elbow.x : elbow.x - 26, elbow.y, 26, bone(0.7 * a), 1.5)
		fx.ring(q.p, 7, bone(0.9 * a), 1.5)
		lr := fx.measure(cl.name, mono(25, 500, 0.02))
		lp := elbow + {side * 36, -1}
		fx.rrect({(side > 0 ? lp.x : lp.x - lr.x) - 10, lp.y - lr.y / 2 - 4, lr.x + 20, lr.y + 8}, 6, fx.alpha(INK, 0.6 * a))
		fx.label(cl.name, lp, mono(25, 500, 0.02), fx.alpha(fx.mix(BONE, GOLD, near), (0.8 + 0.2 * near) * a), {side > 0 ? 0 : 1, 0.5})
	}

	// falling out of the space at the end
	fx.flash(fx.ep(lt, s.dur - 0.22, s.dur, fx.ease_in), INK)
	say(s, {{"What I read became a place.", BEAT * 3}, {"Near things mean nearly the same.", BAR + BEAT * 2}, {"To think is to travel.", BAR * 2 + BEAT * 2}})
}
