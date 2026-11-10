// Sounds made by code, for Sound.gen. Each fills the whole buffer it is
// given, so its shape follows the sound's dur:
//
//   {name = "whoosh", gen = fx.whoosh, at = 4.8, dur = 0.7}
package fx

import "core:math"

@(private = "file")
white :: proc(r: ^Rng) -> f32 {return rand(r) * 2 - 1}

// Filtered noise swelling and falling while its band sweeps up and it pans
// across: something passing by, for whip pans and fast moves.
whoosh :: proc(out: []Sample) {
	n := len(out)
	r := rng(11)
	q: Biquad
	for i in 0 ..< n {
		p := f32(i) / f32(n)
		env := p < 0.62 ? ease_in(p / 0.62) : math.pow(1 - (p - 0.62) / 0.38, 2)
		if i % 32 == 0 do biquad_set(&q, .Band, 250 + 3800 * env, 0.9)
		y := biquad_run(&q, {white(&r), white(&r)})
		pan := lerp(-0.7, 0.7, p)
		out[i] = {y[0] * (1 - pan), y[1] * (1 + pan)} * env * 0.9
	}
}

// A low thud with a noisy crack on top: a hit for cuts and titles.
boom :: proc(out: []Sample) {
	n := len(out)
	r := rng(23)
	lp: Biquad
	biquad_set(&lp, .Low, 2400)
	phase: f32
	for i in 0 ..< n {
		t := f32(i) / RATE
		hz := 38 + 90 * math.exp(-t * 18)
		phase += hz / RATE
		body := math.sin(phase * math.TAU) * math.exp(-t * 3.2)
		crack := biquad_run(&lp, {white(&r), white(&r)}) * math.exp(-t * 28) * 0.8
		tail := clamp01(f32(n - i) / (RATE * 0.05)) // no click at the end
		x := Sample{body, body} + crack
		out[i] = {math.tanh(x[0] * 1.6), math.tanh(x[1] * 1.6)} * 0.85 * tail
	}
}

// Noise and a tone climbing for the whole sound, ending at full height: a
// build-up into a drop placed right at its end.
riser :: proc(out: []Sample) {
	n := len(out)
	r := rng(37)
	q: Biquad
	phase: f32
	for i in 0 ..< n {
		p := f32(i) / f32(n)
		env := ease_in2(p)
		if i % 32 == 0 do biquad_set(&q, .Band, 200 + 7000 * env, 1.4)
		noise := biquad_run(&q, {white(&r), white(&r)})
		phase += (180 + 900 * env) / RATE
		tone := math.sin(phase * math.TAU) * 0.25
		out[i] = (noise + Sample{tone, tone}) * env * 0.8
	}
}

// A short tick, for cursor clicks and UI taps.
click :: proc(out: []Sample) {
	n := len(out)
	r := rng(41)
	hp: Biquad
	biquad_set(&hp, .High, 2500)
	for i in 0 ..< n {
		t := f32(i) / RATE
		tick := biquad_run(&hp, {white(&r), white(&r)}) * math.exp(-t * 400)
		tone := math.sin(t * 1800 * math.TAU) * math.exp(-t * 120) * 0.4
		out[i] = (tick + Sample{tone, tone}) * 0.7
	}
}

// An 808-style sub falling an octave and a half.
sub_drop :: proc(out: []Sample) {
	n := len(out)
	phase: f32
	for i in 0 ..< n {
		p := f32(i) / f32(n)
		hz := 30 + 70 * math.exp(-p * 3)
		phase += hz / RATE
		x := math.tanh(math.sin(phase * math.TAU) * 1.8) * (1 - p) * 0.8
		out[i] = {x, x}
	}
}
