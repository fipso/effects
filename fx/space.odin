// A little 3D: points, lines and glowing dots seen through an orbiting
// camera, projected onto the stage and drawn with the 2D tools. For point
// clouds, constellations, depth of field.
//
//   cam := fx.Cam{yaw = 20 * s.t, pitch = 12, dist = 9}
//   if q, ok := fx.project(cam, {1, 0, 0}); ok do fx.circle(q.p, 0.05 * q.s, c)
package fx

import "core:math"
import sk "../sk"

Vec3 :: [3]f32

// A camera orbiting target: yaw around the vertical axis, pitch above the
// horizon (degrees), dist away. World y points up.
Cam :: struct {
	yaw, pitch: f32,
	dist:       f32,
	target:     Vec3,
	fov:        f32, // vertical field of view in degrees, 0 = 50
	center:     Vec2, // where target lands on the stage, {0, 0} = its middle
	roll:       f32, // degrees
}

Projected :: struct {
	p: Vec2, // stage position
	z: f32, // distance from the camera along its view
	s: f32, // stage px per world unit at that distance
}

// p in the camera's space: x right, y up, z away from the camera.
view :: proc(c: Cam, p: Vec3) -> Vec3 {
	q := p - c.target
	sy, cy := math.sincos(c.yaw * math.RAD_PER_DEG)
	x := q.x * cy - q.z * sy
	z := q.x * sy + q.z * cy
	sp, cp := math.sincos(c.pitch * math.RAD_PER_DEG)
	y := q.y * cp - z * sp
	z = q.y * sp + z * cp
	if c.roll != 0 {
		sr, cr := math.sincos(c.roll * math.RAD_PER_DEG)
		x, y = x * cr - y * sr, x * sr + y * cr
	}
	return {x, y, z + c.dist}
}

// Stage px per world unit one unit in front of the camera.
focal :: proc(c: Cam) -> f32 {
	fov := c.fov > 0 ? c.fov : 50
	return S.h / 2 / math.tan(fov * math.RAD_PER_DEG / 2)
}

// Where a world point lands on the stage; false when it is behind the camera.
project :: proc(c: Cam, p: Vec3, near: f32 = 0.05) -> (Projected, bool) {
	v := view(c, p)
	if v.z < near do return {}, false
	f := focal(c) / v.z
	o := c.center == {} ? center(stage()) : c.center
	return {{o.x + v.x * f, o.y - v.y * f}, v.z, f}, true
}

// A line between two world points, clipped at the camera.
line3 :: proc(c: Cam, a, b: Vec3, p: sk.Paint, near: f32 = 0.05) {
	va, vb := view(c, a), view(c, b)
	if va.z < near && vb.z < near do return
	if va.z < near do va = vb + (va - vb) * ((vb.z - near) / (vb.z - va.z))
	if vb.z < near do vb = va + (vb - va) * ((va.z - near) / (va.z - vb.z))
	f := focal(c)
	o := c.center == {} ? center(stage()) : c.center
	p := p
	sk.canvas_draw_line(S.cv, o.x + va.x * f / va.z, o.y - va.y * f / va.z, o.x + vb.x * f / vb.z, o.y - vb.y * f / vb.z, &p)
}

// A dot of world radius r seen through a lens focused at distance focus:
// sharp there, a bigger and fainter disc (bokeh) the further it is from it.
// aperture is how fast it blurs (0 = everything sharp). Its light is added.
bokeh :: proc(c: Cam, p: Vec3, r: f32, color: Color, focus: f32, aperture: f32 = 0.6, min_px: f32 = 0.6) {
	q, ok := project(c, p)
	if !ok do return
	px := max(r * q.s, min_px)
	coc := abs(q.z - focus) / q.z * aperture * focal(c) * 0.02 // circle of confusion, px
	rr := px + coc
	if q.p.x < -rr || q.p.y < -rr || q.p.x > S.w + rr || q.p.y > S.h + rr do return
	// the same light over a bigger disc
	a := px * px / (rr * rr)
	if coc < 1.5 {
		pt := additive(fill(alpha(color, a)))
		sk.canvas_draw_circle(S.cv, q.p.x, q.p.y, rr, &pt)
		return
	}
	a = min(a * 1.6, 1)
	// out of focus: a disc with a slightly brighter rim, like a real lens
	pt := additive(with_stops(radial(q.p, rr), Stop{alpha(color, a * 0.75), 0}, Stop{alpha(color, a * 0.8), 0.72}, Stop{alpha(color, a), 0.9}, Stop{alpha(color, 0), 1}))
	sk.canvas_draw_circle(S.cv, q.p.x, q.p.y, rr, &pt)
}

// A soft point of light at a stage position: bright core, falling off to r.
spark :: proc(p: Vec2, r: f32, color: Color, a: f32 = 1) {
	if a <= 0.003 || r <= 0.1 do return
	pt := additive(with_stops(radial(p, r), Stop{alpha(color, a), 0}, Stop{alpha(color, a * 0.35), 0.25}, Stop{alpha(color, a * 0.08), 0.6}, Stop{alpha(color, 0), 1}))
	sk.canvas_draw_circle(S.cv, p.x, p.y, r, &pt)
}

// ---------------------------------------------------------------- point sets

// The i-th of n points spread evenly over the unit sphere.
fib_sphere :: proc(i, n: int) -> Vec3 {
	GOLDEN :: 2.39996323 // the golden angle
	y := 1 - 2 * (f32(i) + 0.5) / f32(n)
	r := math.sqrt(max(1 - y * y, 0))
	a := GOLDEN * f32(i)
	return {math.cos(a) * r, y, math.sin(a) * r}
}

// A stable random point from a 3D gaussian (σ = 1) for (seed, i).
gauss3 :: proc(seed: u32, i: int) -> Vec3 {
	g :: proc(seed: u32, i: int) -> (f32, f32) {
		u := max(hash01(seed, i), 1e-6)
		v := hash01(seed + 7919, i)
		r := math.sqrt(-2 * math.ln(u))
		return r * math.cos(math.TAU * v), r * math.sin(math.TAU * v)
	}
	x, y := g(seed, i)
	z, _ := g(seed + 104729, i)
	return {x, y, z}
}

lerp3 :: proc(a, b: Vec3, p: f32) -> Vec3 {return a + (b - a) * p}
length3 :: proc(v: Vec3) -> f32 {return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)}
// Catmull-Rom through points for p in 0..1 across all of them.
spline3 :: proc(pts: []Vec3, p: f32) -> Vec3 {
	n := len(pts)
	if n == 0 do return {}
	if n == 1 do return pts[0]
	x := clamp01(p) * f32(n - 1)
	i := min(int(x), n - 2)
	f := x - f32(i)
	p0, p1, p2, p3 := pts[max(i - 1, 0)], pts[i], pts[i + 1], pts[min(i + 2, n - 1)]
	return 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
}
