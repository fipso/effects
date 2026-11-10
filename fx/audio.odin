// Sound: audio files (anything ffmpeg reads, a video's soundtrack too) and
// samples made by code, placed on the video's timeline and transformed; the
// renderers mix them into one stereo track.
//
//   SOUNDS := [?]fx.Sound {
//       {name = "music", file = "assets/track.wav", from = 33.5, fade_out = 2, volume = 0.8},
//       {name = "boom", gen = fx.boom, at = 5.5, dur = 1.6},
//       {name = "swell", file = "assets/crash.wav", at = 3.6, reverse = true, lowpass = 3000},
//       {name = "stop", file = "assets/track.wav", at = 20, rate = tape_stop},
//   }
//
// Also here: hits, drops and a spectrum read from audio files, so cuts and
// visuals can follow the music.
package fx

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

RATE :: 48000 // the mix: stereo f32 at 48 kHz

Sample :: [2]f32

// Fills out with sound (stereo at RATE); its length is the sound's.
Generator :: #type proc(out: []Sample)

Sound :: struct {
	name:     string, // shown in the editor; the key in timing.json when moved there
	file:     string, // relative to the project
	gen:      Generator, // or samples made by code (fx.whoosh, fx.boom …), dur long
	at:       f32, // video time where it starts
	from:     f32, // seconds into the file where playing starts
	dur:      f32, // how long it plays, in video time; 0 = until the file ends
	loop:     bool, // start over at the end of the file (and play to the video's end when dur is 0)
	volume:   Maybe(f32), // gain, 1 = unchanged
	pan:      f32, // -1 left … 1 right
	fade_in:  f32, // seconds
	fade_out: f32,
	speed:    f32, // playback rate, 0 = 1; changes the pitch like tape unless stretch
	stretch:  bool, // keep the pitch when speed ≠ 1
	reverse:  bool, // play the file backwards (from then counts from the file's end)
	lowpass:  f32, // Hz, 0 = off
	highpass: f32, // Hz, 0 = off
	// Automation, read every few milliseconds at video time t; nil = none.
	gain:     proc(t: f32) -> f32, // volume multiplier: ducking, swells, gaps
	rate:     proc(t: f32) -> f32, // speed multiplier: tape stops, slow-downs
	cutoff:   proc(t: f32) -> f32, // low-pass cutoff in Hz, 0 = open: muffled until the drop
}

// ---------------------------------------------------------------- decoding

@(private = "file")
pcm_cache: struct {
	lock: sync.Mutex,
	m:    map[string][]Sample,
}

// A file's audio as stereo samples at RATE, decoded by ffmpeg once per
// process (tempo ≠ 1: time-stretched keeping the pitch; reverse: backwards).
pcm :: proc(path: string, tempo: f32 = 1, reverse := false) -> []Sample {
	full := resolve(path)
	info, err := os.stat(full, context.temp_allocator)
	if err != nil {
		fmt.eprintln("fx: no audio file", full)
		return nil
	}
	key := fmt.tprintf("%s|%d|%d|%.4f|%v", full, info.size, time.to_unix_nanoseconds(info.modification_time), tempo, reverse)
	sync.guard(&pcm_cache.lock)
	if s, ok := pcm_cache.m[key]; ok do return s
	cmd: [dynamic]string
	cmd.allocator = context.temp_allocator
	append(&cmd, "ffmpeg", "-v", "error", "-nostdin", "-i", full, "-vn")
	filters: [dynamic]string
	filters.allocator = context.temp_allocator
	if tempo != 1 {
		// atempo takes 0.5..100 per instance
		x := tempo
		for x < 0.5 {
			append(&filters, "atempo=0.5")
			x /= 0.5
		}
		append(&filters, fmt.tprintf("atempo=%.6f", x))
	}
	if len(filters) > 0 do append(&cmd, "-af", strings.join(filters[:], ",", context.temp_allocator))
	append(&cmd, "-f", "f32le", "-ac", "2", "-ar", "48000", "-")
	state, out, stderr, perr := exec(cmd[:], context.allocator)
	if perr != nil || !state.success || state.exit_code != 0 {
		fmt.eprintln("fx: cannot decode", full, string(stderr))
		delete(out)
		pcm_cache.m[strings.clone(key)] = nil
		return nil
	}
	s := slice.reinterpret([]Sample, out)
	if reverse do slice.reverse(s)
	pcm_cache.m[strings.clone(key)] = s
	return s
}

@(private = "file")
generated :: proc(g: Generator, n: int, reverse: bool) -> []Sample {
	key := fmt.tprintf("gen|%p|%d|%v", rawptr(g), n, reverse)
	sync.guard(&pcm_cache.lock)
	if s, ok := pcm_cache.m[key]; ok do return s
	s := make([]Sample, n)
	g(s)
	if reverse do slice.reverse(s)
	pcm_cache.m[strings.clone(key)] = s
	return s
}

// The samples a sound plays from and where in them it starts.
@(private = "file")
source :: proc(s: ^Sound) -> (src: []Sample, start: f64, step: f64) {
	speed := s.speed > 0 ? s.speed : 1
	step = f64(s.stretch ? 1 : speed)
	if s.gen != nil {
		dur := s.dur > 0 ? s.dur : 1
		src = generated(s.gen, int(f64(dur) * step * RATE), s.reverse)
		return src, f64(s.from) * RATE, step
	}
	tempo: f32 = s.stretch ? speed : 1
	src = pcm(s.file, tempo, s.reverse)
	return src, f64(s.from) * RATE / f64(tempo), step
}

// When a sound plays, in video time (without its rate automation).
sound_span :: proc(v: ^Video, s: ^Sound) -> (start, dur: f32) {
	if s.dur > 0 do return s.at, s.dur
	if s.loop do return s.at, max(v.duration - s.at, 0)
	src, from, step := source(s)
	return s.at, max(f32((f64(len(src)) - from) / step / RATE), 0)
}

// ---------------------------------------------------------------- mixing

// The video's sounds mixed over [t0, t1) of video time.
mixdown :: proc(v: ^Video, t0, t1: f32, allocator := context.allocator) -> []Sample {
	n := max(int(math.round(f64(t1 - t0) * RATE)), 0)
	out := make([]Sample, n, allocator)
	for &s in v.sounds do mix_sound(v, &s, out, t0)
	for &x in out do x = {soft_clip(x[0]), soft_clip(x[1])}
	return out
}

@(private = "file")
BLOCK :: 64 // automation is read once per block and interpolated within

@(private = "file")
mix_sound :: proc(v: ^Video, s: ^Sound, out: []Sample, t0: f32) {
	src, start, step := source(s)
	if len(src) == 0 do return
	_, span := sound_span(v, s)
	total := int(f64(span) * RATE)
	offset := int(math.round(f64(s.at - t0) * RATE)) // out index of the sound's first sample
	if offset >= len(out) || total <= 0 do return
	vol := s.volume.? or_else 1
	gl, gr := min(1, 1 - s.pan), min(1, 1 + s.pan)
	hp, lp, auto: Biquad
	if s.highpass > 0 do biquad_set(&hp, .High, s.highpass)
	if s.lowpass > 0 do biquad_set(&lp, .Low, s.lowpass)
	fi := s.fade_in * RATE
	fo := s.fade_out * RATE
	pos := start
	g0 := s.gain != nil ? s.gain(s.at) : 1
	block: for k := 0; k < total; k += BLOCK {
		if offset + k >= len(out) do break
		end := min(k + BLOCK, total)
		t := s.at + f32(k) / RATE
		r := f64(s.rate != nil ? max(s.rate(t), 0) : 1)
		g1 := s.gain != nil ? s.gain(s.at + f32(end) / RATE) : 1
		if offset + end <= 0 {
			// before the part being mixed: only keep the position (and filters) moving
			pos += step * r * f64(end - k)
			g0 = g1
			continue
		}
		if s.cutoff != nil do biquad_set(&auto, .Low, s.cutoff(t))
		for j in k ..< end {
			x, ok := read(src, pos, s.loop)
			if !ok do break block
			pos += step * r
			if hp.on do x = biquad_run(&hp, x)
			if lp.on do x = biquad_run(&lp, x)
			if auto.on do x = biquad_run(&auto, x)
			i := offset + j
			if i < 0 do continue
			if i >= len(out) do break block // the sound runs past the end
			a := vol * lerp(g0, g1, f32(j - k) / BLOCK)
			if fi > 0 do a *= min(f32(j) / fi, 1)
			if fo > 0 do a *= min(f32(total - j) / fo, 1)
			out[i] += {x[0] * a * gl, x[1] * a * gr}
		}
		g0 = g1
	}
}

// 4-point Hermite interpolation at a fractional sample position.
@(private = "file")
read :: proc(src: []Sample, pos: f64, loop: bool) -> (Sample, bool) {
	n := len(src)
	i := int(math.floor(pos))
	if !loop && (i < 0 || i >= n) do return {}, false
	f := f32(pos - f64(i))
	at :: proc(src: []Sample, i: int, loop: bool) -> Sample {
		n := len(src)
		if loop do return src[((i % n) + n) % n]
		return i >= 0 && i < n ? src[i] : {}
	}
	xm, x0, x1, x2 := at(src, i - 1, loop), at(src, i, loop), at(src, i + 1, loop), at(src, i + 2, loop)
	c1 := 0.5 * (x1 - xm)
	c2 := xm - 2.5 * x0 + 2 * x1 - 0.5 * x2
	c3 := 0.5 * (x2 - xm) + 1.5 * (x0 - x1)
	return ((c3 * f + c2) * f + c1) * f + x0, true
}

// Leaves the signal alone below 0.8 and bends it smoothly under 0.89
// (-1 dBFS) above, leaving room for the AAC encoder's overshoot.
soft_clip :: proc(x: f32) -> f32 {
	KNEE :: 0.8
	ROOM :: 0.09
	a := abs(x)
	if a <= KNEE do return x
	y := KNEE + ROOM * math.tanh((a - KNEE) / ROOM)
	return x < 0 ? -y : y
}

// 32-bit float stereo WAV at RATE.
write_wav :: proc(path: string, s: []Sample) -> bool {
	data := slice.to_bytes(s)
	buf := make([]u8, 44 + len(data))
	defer delete(buf)
	put32 :: proc(b: []u8, at: int, v: u32) {b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	put16 :: proc(b: []u8, at: int, v: u16) {b[at], b[at + 1] = u8(v), u8(v >> 8)}
	copy(buf[0:], "RIFF")
	put32(buf, 4, u32(36 + len(data)))
	copy(buf[8:], "WAVEfmt ")
	put32(buf, 16, 16)
	put16(buf, 20, 3) // IEEE float
	put16(buf, 22, 2)
	put32(buf, 24, RATE)
	put32(buf, 28, RATE * 8)
	put16(buf, 32, 8)
	put16(buf, 34, 32)
	copy(buf[36:], "data")
	put32(buf, 40, u32(len(data)))
	copy(buf[44:], data)
	return os.write_entire_file(path, buf) == nil
}

// ---------------------------------------------------------------- filters

// RBJ biquad, transposed direct form II, stereo.
Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	z1, z2:             Sample,
	on:                 bool,
}

Filter :: enum {
	Low,
	High,
	Band, // constant 0 dB peak
}

// Sets the filter's response keeping its state (so it can sweep); hz <= 0
// or near Nyquist turns it off.
biquad_set :: proc(q: ^Biquad, kind: Filter, hz: f32, Q: f32 = 0.7071) {
	if hz <= 0 || hz >= RATE * 0.45 {
		q.on = false
		return
	}
	w := 2 * math.PI * hz / RATE
	cw, sw := math.cos(w), math.sin(w)
	alpha := sw / (2 * Q)
	a0 := 1 + alpha
	switch kind {
	case .Low:
		q.b0, q.b1, q.b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
	case .High:
		q.b0, q.b1, q.b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
	case .Band:
		q.b0, q.b1, q.b2 = alpha, 0, -alpha
	}
	q.b0 /= a0
	q.b1 /= a0
	q.b2 /= a0
	q.a1 = -2 * cw / a0
	q.a2 = (1 - alpha) / a0
	q.on = true
}

biquad_run :: proc(q: ^Biquad, x: Sample) -> Sample {
	y := q.b0 * x + q.z1
	q.z1 = q.b1 * x - q.a1 * y + q.z2
	q.z2 = q.b2 * x - q.a2 * y
	return y
}

// ---------------------------------------------------------------- analysis

HOP :: 480 // analysis frames are 10 ms

Band :: enum {
	Bass, // kicks and 808s (below ~120 Hz)
	Full,
	High, // snares, claps, hats (above ~5 kHz)
}

Onset :: struct {
	t:        f32, // seconds into the file
	strength: f32, // how sharp the attack is (jump in log energy; drops: energy ratio)
	level:    f32, // loudness right after it, 0..1 of the file's loudest
}

// Hits in an audio file: kicks and 808s with .Bass, snares and hats with
// .High, any attack with .Full. threshold is the smallest jump in log energy
// that counts (0.35 finds most hits, 1 only hard ones).
onsets :: proc(file: string, band := Band.Bass, threshold: f32 = 0.35) -> []Onset {
	data := analysis(file, fmt.tprintf("onsets/%v/%.3f", band, threshold), proc(file: string, band: Band, threshold: f32) -> []f32 {
		e := envelope(file, band)
		defer delete(e)
		n := len(e)
		emax := slice.max(e) if n > 0 else 0
		le := make([]f32, n, context.temp_allocator)
		for x, i in e do le[i] = math.ln(x + 1e-6)
		on := make([]f32, n, context.temp_allocator)
		for i in 3 ..< n do on[i] = max(0, le[i] - max(le[i - 3], le[i - 2], le[i - 1]))
		out: [dynamic]f32
		last := -1000
		for i in 5 ..< n - 5 {
			if on[i] < threshold || e[min(i + 2, n - 1)] < 0.12 * emax do continue
			if on[i] < slice.max(on[i - 5:i + 6]) do continue
			level := e[min(i + 3, n - 1)] / emax
			if i - last < 12 {
				// two peaks closer than 120 ms: keep the sharper one
				k := len(out) - 3
				if on[i] > out[k + 1] do out[k], out[k + 1], out[k + 2], last = f32(i * HOP) / RATE, on[i], level, i
				continue
			}
			append(&out, f32(i * HOP) / RATE, on[i], level)
			last = i
		}
		return out[:]
	}, band, threshold)
	return slice.reinterpret([]Onset, data)
}

// Drops: where the band's energy jumps and stays up for a while (the beat
// coming back in), each placed on the hit that starts it.
drops :: proc(file: string, band := Band.Bass) -> []Onset {
	data := analysis(file, fmt.tprintf("drops/%v", band), proc(file: string, band: Band, _: f32) -> []f32 {
		e := envelope(file, band)
		defer delete(e)
		n := len(e)
		W :: 150 // 1.5 s on each side
		if n < 2 * W do return nil
		sum := make([]f64, n + 1, context.temp_allocator)
		for x, i in e do sum[i + 1] = sum[i] + f64(x)
		mean :: proc(sum: []f64, a, b: int) -> f32 {return f32((sum[b] - sum[a]) / f64(b - a))}
		emax := slice.max(e)
		score := make([]f32, n, context.temp_allocator)
		after := make([]f32, n, context.temp_allocator)
		top: f32
		for i in W ..< n - W {
			before := mean(sum, i - W, i)
			after[i] = mean(sum, i, i + W)
			score[i] = after[i] / (before + 0.03 * emax)
			top = max(top, after[i])
		}
		hits := onsets(file, band)
		out: [dynamic]f32
		for i in W ..< n - W {
			if score[i] < 2.5 || after[i] < 0.4 * top do continue
			if score[i] < slice.max(score[max(i - 400, W):min(i + 401, n - W)]) do continue
			t := f32(i * HOP) / RATE
			// the strongest hit near the jump
			best: f32 = -1
			for h in hits do if abs(h.t - t) < 0.4 && h.strength > best {
				best = h.strength
				t = h.t
			}
			append(&out, t, score[i], after[i] / top)
		}
		return out[:]
	}, band, 0)
	return slice.reinterpret([]Onset, data)
}

SPECTRUM_BANDS :: 16

// Loudness of 16 bands from 40 Hz to 12 kHz (log-spaced), 0..1, every 10 ms
// of the file, with a short release so bars fall smoothly.
spectrum :: proc(file: string) -> [][SPECTRUM_BANDS]f32 {
	data := analysis(file, "spectrum", proc(file: string, _: Band, _: f32) -> []f32 {
		src := pcm(file)
		frames := len(src) / HOP
		out := make([]f32, frames * SPECTRUM_BANDS)
		for b in 0 ..< SPECTRUM_BANDS {
			hz := 40 * math.pow(f32(12000.0 / 40.0), f32(b) / (SPECTRUM_BANDS - 1))
			q: Biquad
			biquad_set(&q, .Band, hz, 2)
			db := make([]f32, frames, context.temp_allocator)
			for f in 0 ..< frames {
				acc: f32
				for i in f * HOP ..< (f + 1) * HOP {
					x := src[i]
					y := biquad_run(&q, {(x[0] + x[1]) / 2, 0})[0]
					acc += y * y
				}
				db[f] = 10 * math.log10(acc / HOP + 1e-12)
			}
			// 0 = 42 dB below the band's loud end (its 99th percentile), 1 = at it
			sorted := slice.clone(db, context.temp_allocator)
			slice.sort(sorted)
			top := sorted[int(f32(len(sorted) - 1) * 0.99)] if len(sorted) > 0 else 0
			v: f32
			for f in 0 ..< frames {
				x := clamp01((db[f] - (top - 42)) / 42)
				v = max(x, v * 0.9)
				out[f * SPECTRUM_BANDS + b] = v
			}
		}
		return out
	}, .Full, 0)
	return slice.reinterpret([][SPECTRUM_BANDS]f32, data)
}

// The spectrum at t seconds into the file.
spectrum_at :: proc(file: string, t: f32) -> [SPECTRUM_BANDS]f32 {
	sp := spectrum(file)
	if len(sp) == 0 do return {}
	return sp[clamp(int(t * RATE / HOP), 0, len(sp) - 1)]
}

// RMS of one band of a file, every 10 ms.
@(private = "file")
envelope :: proc(file: string, band: Band) -> []f32 {
	src := pcm(file)
	frames := len(src) / HOP
	e := make([]f32, frames)
	q1, q2: Biquad
	switch band {
	case .Bass:
		biquad_set(&q1, .Low, 120)
		biquad_set(&q2, .Low, 120)
	case .High:
		biquad_set(&q1, .High, 5000)
		biquad_set(&q2, .High, 5000)
	case .Full:
	}
	for f in 0 ..< frames {
		acc: f32
		for i in f * HOP ..< (f + 1) * HOP {
			x := Sample{(src[i][0] + src[i][1]) / 2, 0}
			if q1.on do x = biquad_run(&q2, biquad_run(&q1, x))
			acc += x[0] * x[0]
		}
		e[f] = math.sqrt(acc / HOP)
	}
	return e
}

@(private = "file")
analyses: struct {
	lock: sync.Recursive_Mutex, // drops reads onsets while computing
	m:    map[string][]f32,
}

// An analysis result as floats, computed once per process and kept under
// the project's .effects/analysis (keyed by the file's size and mtime).
@(private = "file")
analysis :: proc(file, kind: string, compute: proc(file: string, band: Band, threshold: f32) -> []f32, band: Band, threshold: f32) -> []f32 {
	full := resolve(file)
	info, err := os.stat(full, context.temp_allocator)
	if err != nil {
		fmt.eprintln("fx: no audio file", full)
		return nil
	}
	key := fmt.tprintf("%s|%d|%d|%s|v1", full, info.size, time.to_unix_nanoseconds(info.modification_time), kind)
	sync.guard(&analyses.lock)
	if d, ok := analyses.m[key]; ok do return d
	cache := ""
	if PROJECT_DIR != "" {
		dir := join({PROJECT_DIR, ".effects", "analysis"})
		os.make_directory_all(dir)
		cache = join({dir, fmt.tprintf("%016x.f32", hash.fnv64a(transmute([]u8)key))})
		if bytes, rerr := os.read_entire_file(cache, context.allocator); rerr == nil {
			d := slice.reinterpret([]f32, bytes)
			analyses.m[strings.clone(key)] = d
			return d
		}
	}
	d := compute(file, band, threshold)
	if cache != "" do _ = os.write_entire_file(cache, slice.to_bytes(d))
	analyses.m[strings.clone(key)] = d
	return d
}
