// Music made by code: a small offline studio. Notes of a subtractive synth
// and drum hits are added into stereo buffers ("buses"), buses get effects
// (side-chain ducking, filter sweeps, reverb, delay), and the buses are
// summed and limited into what a Sound's generator hands to the mix:
//
//   song :: proc(out: []fx.Sample) {
//       pads := make([]fx.Sample, len(out)); defer delete(pads)
//       fx.play(pads, PAD, at = 0, dur = 4, midi = 50)
//       fx.kick(out, 0); fx.kick(out, 0.5)
//       fx.duck(pads, {0, 0.5}, 0.7, 0.3)
//       fx.send(out, pads, 1)
//       fx.limit(out)
//   }
//   SOUNDS := [?]fx.Sound{{name = "music", gen = song, dur = 60}}
//
// Everything is deterministic: the same code renders the same samples.
package fx

import "core:math"

// Frequency of a MIDI note (69 = A4 = 440 Hz); fractions are fine.
note_hz :: proc(midi: f32) -> f32 {return 440 * math.pow(2, (midi - 69) / 12)}

Wave :: enum {
	Saw,
	Square,
	Sine,
	Triangle,
}

// A synth sound: oscillators → low-pass filter with its own envelope →
// drive → amplifier envelope.
Patch :: struct {
	wave:      Wave,
	voices:    int, // unison voices, 0 = 1
	detune:    f32, // cents between the outermost unison voices
	width:     f32, // 0..1 how far the unison voices are spread left and right
	sub:       f32, // level of a sine one octave below
	noise:     f32, // level of white noise
	attack:    f32, // seconds
	decay:     f32,
	sustain:   f32, // 0..1
	release:   f32,
	cutoff:    f32, // low-pass in Hz, 0 = open
	env:       f32, // Hz the filter envelope adds at its peak
	env_decay: f32, // seconds until the filter envelope has fallen
	track:     f32, // 0..1 how much the cutoff follows the note's pitch
	q:         f32, // resonance: 0 = 0.7 (none), 4 = whistling
	drive:     f32, // saturation, 0 = clean
	vibrato:   f32, // cents
	vib_hz:    f32, // 0 = 5.5
	vib_delay: f32, // seconds before the vibrato has come in
	bend:      f32, // starts this many semitones off and glides to the note
	bend_time: f32,
	pan:       f32, // -1..1
	gain:      f32, // 0 = 1
}

@(private = "file")
polyblep :: #force_inline proc(t, dt: f32) -> f32 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	}
	if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

// One sample of a band-limited wave at phase (0..1) advancing dt per sample.
osc :: #force_inline proc(w: Wave, phase, dt: f32) -> f32 {
	switch w {
	case .Saw:
		return 2 * phase - 1 - polyblep(phase, dt)
	case .Square:
		h := phase + 0.5
		if h >= 1 do h -= 1
		return (phase < 0.5 ? 1 : -1) + polyblep(phase, dt) - polyblep(h, dt)
	case .Sine:
		return math.sin(phase * math.TAU)
	case .Triangle:
		return 4 * abs(phase - 0.5) - 1
	}
	return 0
}

// State-variable filter (Cytomic's trapezoidal one), stereo. Stable under
// fast sweeps, which a biquad is not.
Svf :: struct {
	ic1, ic2:   Sample,
	a1, a2, a3: f32,
	k:          f32,
}

svf_set :: proc(f: ^Svf, hz: f32, q: f32 = 0.7071) {
	g := math.tan(math.PI * clamp(hz, 16, RATE * 0.45) / RATE)
	f.k = 1 / max(q, 0.3)
	f.a1 = 1 / (1 + g * (g + f.k))
	f.a2 = g * f.a1
	f.a3 = g * f.a2
}

svf_low :: #force_inline proc(f: ^Svf, x: Sample) -> Sample {
	v3 := x - f.ic2
	v1 := f.a1 * f.ic1 + f.a2 * v3
	v2 := f.ic2 + f.a2 * f.ic1 + f.a3 * v3
	f.ic1 = 2 * v1 - f.ic1
	f.ic2 = 2 * v2 - f.ic2
	return v2
}

// Low, band and high outputs at once.
svf_run :: #force_inline proc(f: ^Svf, x: Sample) -> (low, band, high: Sample) {
	v3 := x - f.ic2
	v1 := f.a1 * f.ic1 + f.a2 * v3
	v2 := f.ic2 + f.a2 * f.ic1 + f.a3 * v3
	f.ic1 = 2 * v1 - f.ic1
	f.ic2 = 2 * v2 - f.ic2
	return v2, v1, x - f.k * v1 - v2
}

// Adds one note to out: it starts at second `at`, is held for dur and rings
// out over the patch's release.
play :: proc(out: []Sample, p: Patch, at, dur, midi: f32, vel: f32 = 1) {
	MAXV :: 9
	nv := clamp(p.voices, 1, MAXV)
	rel := max(p.release, 0.005)
	i0 := int(at * RATE)
	n := int((dur + rel) * RATE)
	if i0 >= len(out) || i0 + n <= 0 do return
	phase: [MAXV]f32
	ratio: [MAXV]f32
	gl, gr: [MAXV]f32
	r := rng(u32(midi * 131) + u32(i0) * 7 + 3)
	for v in 0 ..< nv {
		phase[v] = rand(&r)
		x: f32 = nv > 1 ? f32(v) / f32(nv - 1) * 2 - 1 : 0 // -1..1 across the voices
		ratio[v] = math.pow(2, x * p.detune / 2 / 1200)
		// neighbours go to opposite sides
		pan := clamp((v % 2 == 0 ? x : -x) * p.width + p.pan, -1, 1)
		gl[v], gr[v] = math.sqrt(0.5 * (1 - pan)), math.sqrt(0.5 * (1 + pan))
	}
	norm := 1 / math.sqrt(f32(nv))
	sub_phase := rand(&r)
	vib_phase: f32
	hz0 := note_hz(midi)
	filt: Svf
	filtered := p.cutoff > 0
	q := p.q > 0 ? p.q : 0.7071
	gain := (p.gain > 0 ? p.gain : 1) * vel
	attack := max(p.attack, 0.0005)
	decay := max(p.decay, 0.001)
	env_decay := max(p.env_decay, 0.001)
	vib_hz := p.vib_hz > 0 ? p.vib_hz : 5.5
	level_at_release: f32 = 1
	nr := rng(u32(i0) * 2654435761 + 17)
	track := math.pow(hz0 / 261.63, p.track)
	hz := hz0
	for j in 0 ..< n {
		t := f32(j) / RATE
		if j % 16 == 0 {
			// pitch: bend and vibrato
			semis: f32
			if p.bend != 0 && p.bend_time > 0 do semis += p.bend * (1 - ease_out(prog(t, 0, p.bend_time)))
			if p.vibrato > 0 {
				depth := p.vibrato * (p.vib_delay > 0 ? clamp01((t - p.vib_delay * 0.5) / p.vib_delay) : 1)
				semis += math.sin(vib_phase * math.TAU) * depth / 100
				vib_phase += vib_hz * 16 / RATE
			}
			hz = semis != 0 ? hz0 * math.pow(2, semis / 12) : hz0
			if filtered {
				fe := math.exp(-t / env_decay * 4)
				if t < attack do fe *= t / attack
				svf_set(&filt, (p.cutoff + p.env * fe * (0.4 + 0.6 * vel)) * track, q)
			}
		}
		// amplifier envelope
		a: f32
		switch {
		case t < attack:
			a = t / attack
		case t < dur:
			a = p.sustain + (1 - p.sustain) * math.exp(-(t - attack) / decay * 4)
		case:
			a = level_at_release * math.exp(-(t - dur) / rel * 5) * clamp01((dur + rel - t) / (rel * 0.2))
		}
		if t < dur do level_at_release = a
		x: Sample
		for v in 0 ..< nv {
			dt := hz * ratio[v] / RATE
			s := osc(p.wave, phase[v], dt)
			phase[v] += dt
			if phase[v] >= 1 do phase[v] -= 1
			x += {s * gl[v], s * gr[v]}
		}
		x *= norm
		if p.sub > 0 {
			s := math.sin(sub_phase * math.TAU) * p.sub
			sub_phase += hz * 0.5 / RATE
			if sub_phase >= 1 do sub_phase -= 1
			x += {s, s} * 0.7071
		}
		if p.noise > 0 do x += {rand(&nr) * 2 - 1, rand(&nr) * 2 - 1} * p.noise
		if filtered do x = svf_low(&filt, x)
		if p.drive > 0 {
			d := 1 + p.drive * 4
			x = {math.tanh(x[0] * d), math.tanh(x[1] * d)} / math.tanh(d) * (1 / (1 + p.drive))
		}
		i := i0 + j
		if i < 0 do continue
		if i >= len(out) do break
		out[i] += x * (a * gain)
	}
}

// ---------------------------------------------------------------- drums

@(private = "file")
noise2 :: #force_inline proc(r: ^Rng) -> Sample {return {rand(r) * 2 - 1, rand(r) * 2 - 1}}

// A kick drum: a sine falling from punch Hz above hz, with a click.
// length is how long its body rings.
kick :: proc(out: []Sample, at: f32, vel: f32 = 1, hz: f32 = 47, punch: f32 = 150, length: f32 = 0.26, click: f32 = 0.5) {
	i0 := int(at * RATE)
	n := int((length * 2.2 + 0.05) * RATE)
	r := rng(101)
	hp: Biquad
	biquad_set(&hp, .High, 3000)
	phase: f32 = 0
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		t := f32(j) / RATE
		f := hz + punch * math.exp(-t / 0.028) + punch * 2 * math.exp(-t / 0.004)
		phase += f / RATE
		body := math.sin(phase * math.TAU) * math.exp(-t / length * 2.2) * min(t / 0.0008, 1)
		ck := biquad_run(&hp, noise2(&r)) * math.exp(-t / 0.0025) * click
		tail := clamp01(f32(n - j) / (RATE * 0.02))
		x := Sample{body, body} + ck * 0.6
		x = {math.tanh(x[0] * 1.7), math.tanh(x[1] * 1.7)}
		if i >= 0 do out[i] += x * (vel * tail * 0.95)
	}
}

// A clap: three quick bursts of band-passed noise and a short tail.
clap :: proc(out: []Sample, at: f32, vel: f32 = 1, length: f32 = 0.16) {
	i0 := int(at * RATE)
	n := int((length * 2 + 0.05) * RATE)
	r := rng(u32(i0) + 211)
	bp, hp: Biquad
	biquad_set(&bp, .Band, 1350, 0.9)
	biquad_set(&hp, .High, 700)
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		t := f32(j) / RATE
		env: f32
		for b in 0 ..< 3 {
			tb := t - f32(b) * 0.011
			if tb >= 0 do env = max(env, math.exp(-tb / 0.0045))
		}
		tt := t - 0.03
		if tt >= 0 do env = max(env, 0.85 * math.exp(-tt / length * 2.4))
		x := biquad_run(&hp, biquad_run(&bp, noise2(&r))) * env * 2.4
		if i >= 0 do out[i] += {math.tanh(x[0]), math.tanh(x[1])} * (vel * 0.8)
	}
}

// A snare: a short tone under a burst of bright noise.
snare :: proc(out: []Sample, at: f32, vel: f32 = 1, hz: f32 = 196, length: f32 = 0.13) {
	i0 := int(at * RATE)
	n := int((length * 2.5 + 0.02) * RATE)
	r := rng(u32(i0) + 307)
	bp, hp: Biquad
	biquad_set(&bp, .Band, 3200, 0.6)
	biquad_set(&hp, .High, 1100)
	phase: f32
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		t := f32(j) / RATE
		phase += (hz + 120 * math.exp(-t / 0.012)) / RATE
		tone := math.sin(phase * math.TAU) * math.exp(-t / 0.055)
		nz := biquad_run(&hp, biquad_run(&bp, noise2(&r))) * math.exp(-t / length * 2.2) * 2.2
		x := Sample{tone, tone} * 0.7 + nz
		if i >= 0 do out[i] += {math.tanh(x[0] * 1.3), math.tanh(x[1] * 1.3)} * (vel * 0.7)
	}
}

// A hi-hat: high noise; length 0.03 closed, 0.2 open.
hat :: proc(out: []Sample, at: f32, vel: f32 = 1, length: f32 = 0.035, pan: f32 = 0) {
	i0 := int(at * RATE)
	n := int((length * 3 + 0.01) * RATE)
	r := rng(u32(i0) * 3 + 401)
	h1, h2: Biquad
	biquad_set(&h1, .High, 7200)
	biquad_set(&h2, .High, 9000, 1.6)
	gl, gr := math.sqrt(0.5 * (1 - pan)) * 1.414, math.sqrt(0.5 * (1 + pan)) * 1.414
	// six detuned squares give the metal, noise the sizzle
	FREQS :: [6]f32{2043, 3067, 4111, 5237, 6779, 8123}
	ph: [6]f32
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		t := f32(j) / RATE
		m: f32
		for f, k in FREQS {
			ph[k] += f * 1.37 / RATE
			if ph[k] >= 1 do ph[k] -= 1
			m += ph[k] < 0.5 ? 1 : -1
		}
		x := noise2(&r) + Sample{m, m} * 0.22
		x = biquad_run(&h2, biquad_run(&h1, x)) * math.exp(-t / length * 2.6) * min(t / 0.0006, 1)
		if i >= 0 do out[i] += {x[0] * gl, x[1] * gr} * (vel * 0.42)
	}
}

// A crash cymbal: a long wash of bright noise.
crash :: proc(out: []Sample, at: f32, vel: f32 = 1, length: f32 = 1.6) {
	i0 := int(at * RATE)
	n := int(length * 2.5 * RATE)
	r := rng(u32(i0) + 503)
	h1, bp: Biquad
	biquad_set(&h1, .High, 4200)
	biquad_set(&bp, .Band, 8200, 0.5)
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		t := f32(j) / RATE
		nz := noise2(&r)
		x := (biquad_run(&h1, nz) * 0.6 + biquad_run(&bp, nz) * 0.9) * (math.exp(-t / length * 2.4) * 0.8 + 0.5 * math.exp(-t / 0.05)) * min(t / 0.002, 1)
		if i >= 0 do out[i] += x * (vel * 0.5)
	}
}

// Noise sweeping from lo to hi Hz over dur while it swells (up) or dies
// away (down): risers into a drop, down-lifters out of one.
sweep_noise :: proc(out: []Sample, at, dur: f32, lo: f32 = 300, hi: f32 = 9000, up := true, vel: f32 = 1, q: f32 = 2.2) {
	i0 := int(at * RATE)
	n := int(dur * RATE)
	r := rng(u32(i0) + 601)
	f: Svf
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		p := f32(j) / f32(n)
		x := up ? p : 1 - p
		if j % 16 == 0 do svf_set(&f, lo * math.pow(hi / lo, x), q)
		_, band, _ := svf_run(&f, noise2(&r))
		env := up ? x * x : x * x * min(p * 60, 1)
		edge := min(f32(n - j) / (RATE * 0.004), 1)
		if i >= 0 do out[i] += band * (env * vel * 0.6 * edge)
	}
}

// A deep hit with a long tail, for drops and title cards.
impact :: proc(out: []Sample, at: f32, vel: f32 = 1, length: f32 = 1.4) {
	i0 := int(at * RATE)
	n := int(length * 2 * RATE)
	r := rng(u32(i0) + 701)
	lp: Biquad
	biquad_set(&lp, .Low, 900)
	phase: f32
	for j in 0 ..< n {
		i := i0 + j
		if i >= len(out) do break
		t := f32(j) / RATE
		phase += (34 + 70 * math.exp(-t / 0.05)) / RATE
		body := math.tanh(math.sin(phase * math.TAU) * 2.2) * math.exp(-t / length * 2.6)
		nz := biquad_run(&lp, noise2(&r)) * math.exp(-t / 0.12) * 1.4
		tail := clamp01(f32(n - j) / (RATE * 0.05))
		x := Sample{body, body} + nz
		if i >= 0 do out[i] += {math.tanh(x[0]), math.tanh(x[1])} * (vel * 0.9 * tail)
	}
}

// ---------------------------------------------------------------- buses

// Adds src to dst at gain.
send :: proc(dst, src: []Sample, gain: f32 = 1) {
	for i in 0 ..< min(len(dst), len(src)) do dst[i] += src[i] * gain
}

// Multiplies the bus by gain(t), read every few milliseconds.
automate :: proc(buf: []Sample, gain: proc(t: f32) -> f32) {
	B :: 128
	g0 := gain(0)
	for k := 0; k < len(buf); k += B {
		end := min(k + B, len(buf))
		g1 := gain(f32(end) / RATE)
		for j in k ..< end do buf[j] *= lerp(g0, g1, f32(j - k) / B)
		g0 = g1
	}
}

// Side-chain pumping: the bus dips by depth (0..1) at every hit and comes
// back over release seconds, as if a compressor listened to the kick.
duck :: proc(buf: []Sample, hits: []f32, depth: f32 = 0.7, release: f32 = 0.3, attack: f32 = 0.006) {
	h := 0
	for &x, i in buf {
		t := f32(i) / RATE
		for h < len(hits) && hits[h] <= t + attack do h += 1
		g: f32 = 1
		if h > 0 {
			since := t - hits[h - 1]
			if since < 0 do g = 1 - depth * (1 + since / attack) // the dip's own short fade
			else {
				p := clamp01(since / release)
				g = 1 - depth * (1 - p * p * (3 - 2 * p))
			}
		}
		// the next hit's fade-in
		if h < len(hits) {
			until := hits[h] - t
			if until < attack do g = min(g, 1 - depth * (1 - until / attack))
		}
		x *= g
	}
}

// A low-pass (or, with high, a high-pass) over the bus whose cutoff follows
// cutoff(t) in Hz: the muffled intro opening up, a build closing down.
sweep_filter :: proc(buf: []Sample, cutoff: proc(t: f32) -> f32, q: f32 = 0.8, high := false) {
	f: Svf
	for &x, i in buf {
		if i % 32 == 0 do svf_set(&f, cutoff(f32(i) / RATE), q)
		lo, _, hi := svf_run(&f, x)
		x = high ? hi : lo
	}
}

// Replaces the bus by its reverberation (Freeverb: eight combs and four
// all-passes a side). room 0..1 is the decay, damp 0..1 how dull the tail
// gets, pre a delay in seconds before it starts.
reverb :: proc(buf: []Sample, room: f32 = 0.82, damp: f32 = 0.35, width: f32 = 1, pre: f32 = 0.012) {
	COMBS :: [8]int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}
	ALLS :: [4]int{556, 441, 341, 225}
	SPREAD :: 23
	K :: f32(RATE) / 44100
	Comb :: struct {
		buf:   []f32,
		i:     int,
		store: f32,
	}
	combs: [2][8]Comb
	alls: [2][4]Comb
	for ch in 0 ..< 2 {
		for l, k in COMBS do combs[ch][k].buf = make([]f32, int(f32(l + ch * SPREAD) * K))
		for l, k in ALLS do alls[ch][k].buf = make([]f32, int(f32(l + ch * SPREAD) * K))
	}
	defer for ch in 0 ..< 2 {
		for &c in combs[ch] do delete(c.buf)
		for &c in alls[ch] do delete(c.buf)
	}
	feedback := clamp01(room) * 0.28 + 0.7
	d1 := clamp01(damp) * 0.4
	d2 := 1 - d1
	pre_n := max(int(pre * RATE), 1)
	pre_buf := make([]f32, pre_n)
	defer delete(pre_buf)
	pi := 0
	w1, w2 := width / 2 + 0.5, (1 - width) / 2
	for &x in buf {
		input := (x[0] + x[1]) * 0.015
		delayed := pre_buf[pi]
		pre_buf[pi] = input
		pi = (pi + 1) % pre_n
		o: [2]f32
		for ch in 0 ..< 2 {
			for &c in combs[ch] {
				y := c.buf[c.i]
				c.store = y * d2 + c.store * d1
				c.buf[c.i] = delayed + c.store * feedback
				c.i += 1
				if c.i >= len(c.buf) do c.i = 0
				o[ch] += y
			}
			for &c in alls[ch] {
				b := c.buf[c.i]
				y := -o[ch] + b
				c.buf[c.i] = o[ch] + b * 0.5
				c.i += 1
				if c.i >= len(c.buf) do c.i = 0
				o[ch] = y
			}
		}
		x = {o[0] * w1 + o[1] * w2, o[1] * w1 + o[0] * w2}
	}
}

// Replaces the bus by its echoes: time seconds apart, each feedback as loud
// as the one before and duller (lowpass Hz); ping_pong throws them from side
// to side.
echo :: proc(buf: []Sample, time: f32, feedback: f32 = 0.45, ping_pong := true, lowpass: f32 = 4500) {
	n := max(int(time * RATE), 1)
	line := make([]Sample, n)
	defer delete(line)
	lp: Biquad
	biquad_set(&lp, .Low, lowpass)
	i := 0
	for &x in buf {
		y := line[i]
		fb := biquad_run(&lp, y) * feedback
		if ping_pong {
			// the input enters on the left; echoes cross over each round
			line[i] = {(x[0] + x[1]) * 0.7 + fb[1], fb[0]}
		} else {
			line[i] = x + fb
		}
		i += 1
		if i >= n do i = 0
		x = y
	}
}

// A look-ahead limiter: holds the peaks under ceiling without clipping, so
// the mix can be loud. gain is applied first.
limit :: proc(buf: []Sample, ceiling: f32 = 0.79, gain: f32 = 1, release: f32 = 0.12) {
	LOOK :: 240 // 5 ms
	n := len(buf)
	if n == 0 do return
	want := make([]f32, n)
	defer delete(want)
	for &x, i in buf {
		x *= gain
		peak := max(abs(x[0]), abs(x[1]))
		want[i] = peak > ceiling ? ceiling / peak : 1
	}
	// the lowest gain needed within the next LOOK samples (sliding minimum)
	q := make([]int, n)
	defer delete(q)
	head, tail := 0, 0
	ahead := make([]f32, n)
	defer delete(ahead)
	j := 0
	for i in 0 ..< n {
		for j < n && j <= i + LOOK {
			for tail > head && want[q[tail - 1]] >= want[j] do tail -= 1
			q[tail] = j
			tail += 1
			j += 1
		}
		for q[head] < i do head += 1
		ahead[i] = want[q[head]]
	}
	// fall fast (over the look-ahead), recover slowly
	g: f32 = 1
	att := 1 - math.exp(f32(-1.0) / (LOOK * 0.25))
	rel := 1 - math.exp(-1 / (release * RATE))
	for &x, i in buf {
		target := ahead[i]
		g += (target - g) * (target < g ? att : rel)
		x *= min(g, want[i])
	}
}

// How loud a bus is every 10 ms (RMS), for pictures that follow the sound.
levels :: proc(buf: []Sample, allocator := context.allocator) -> []f32 {
	frames := len(buf) / HOP
	out := make([]f32, frames, allocator)
	for f in 0 ..< frames {
		acc: f32
		for x in buf[f * HOP:(f + 1) * HOP] do acc += x[0] * x[0] + x[1] * x[1]
		out[f] = math.sqrt(acc / (2 * HOP))
	}
	return out
}

// The value of a levels curve at t seconds, interpolated.
level_at :: proc(lv: []f32, t: f32) -> f32 {
	if len(lv) == 0 do return 0
	x := clamp(t * RATE / HOP, 0, f32(len(lv) - 1))
	i := min(int(x), len(lv) - 2)
	if i < 0 do return lv[0]
	return lerp(lv[i], lv[i + 1], x - f32(i))
}
