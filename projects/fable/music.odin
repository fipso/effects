// The score: 32 bars at 128 bpm in D minor, exactly one minute, written as
// lists of notes and hits and rendered by fx's synth. No samples. The
// pictures read the same lists (ev()), so they hit what the music hits.
package fable

@(require) import "core:fmt" // only the STEMS meters print
import "core:math"
import "core:sync"
import fx "effects:fx"

BPM :: 128.0
BEAT :: f32(60.0 / BPM) // 0.46875 s
BAR :: BEAT * 4 // 1.875 s
STEP :: BEAT / 4 // a sixteenth
BARS :: 32
LENGTH :: BAR * BARS // 60 s

// Start of a bar (1-based) plus sixteenths.
bar :: proc(b: int, step: f32 = 0) -> f32 {return f32(b - 1) * BAR + step * STEP}

Note :: struct {
	t, dur, midi, vel: f32,
}

Events :: struct {
	kicks:  [dynamic]f32, // the four-on-the-floor ones (what the pads duck to)
	hearts: [dynamic]f32, // the soft double beat of the second section
	claps:  [dynamic]f32,
	snares: [dynamic]Note,
	hats:   [dynamic]Note, // dur > 0.1 = open
	bass:   [dynamic]Note,
	pads:   [dynamic]Note,
	stabs:  [dynamic]Note,
	arp:    [dynamic]Note,
	lead:   [dynamic]Note,
	pings:  [dynamic]Note,
	ticks:  [dynamic]Note, // typing: midi is the key's pitch
	chords: [dynamic]f32, // when the harmony changes
}

Chord :: struct {
	bass: f32,
	pad:  [5]f32,
	arp:  [5]f32,
}

// Dm9 · B♭maj7 · Fmaj7 · Cadd9
CHORDS := [4]Chord {
	{38, {50, 53, 57, 60, 64}, {62, 65, 69, 72, 76}},
	{34, {46, 53, 57, 62, 65}, {58, 62, 65, 69, 74}},
	{41, {41, 48, 57, 60, 64}, {60, 65, 69, 72, 76}},
	{36, {36, 48, 55, 62, 64}, {60, 64, 67, 72, 74}},
}

ARP_PATTERN := [16]int{0, 2, 4, 2, 3, 2, 4, 1, 0, 2, 4, 2, 3, 4, 2, 1}

// The melody of the drop, four bars: {step, length, note}.
LEAD_A := [4][]Note {
	{{0, 3, 69, 1}, {3, 3, 74, 0.9}, {6, 2, 72, 0.8}, {8, 4, 69, 0.9}, {12, 2, 65, 0.8}, {14, 2, 67, 0.8}},
	{{0, 6, 69, 1}, {6, 2, 67, 0.8}, {8, 4, 65, 0.9}, {12, 4, 62, 0.8}},
	{{0, 3, 72, 1}, {3, 3, 77, 0.9}, {6, 2, 76, 0.8}, {8, 4, 72, 0.9}, {12, 2, 69, 0.8}, {14, 2, 72, 0.8}},
	{{0, 6, 74, 1}, {6, 2, 76, 0.85}, {8, 4, 79, 0.95}, {12, 4, 76, 0.85}},
}
// Its last bar the second time: climbing into what follows.
LEAD_LIFT := []Note{{0, 4, 74, 1}, {4, 4, 76, 0.9}, {8, 4, 79, 0.95}, {12, 4, 81, 1}}

STAB_STEPS := [6]f32{0, 3, 6, 8, 11, 14}

// When the keys are pressed in the first scene and the last (see scenes).
PROMPT :: "who are you?"
PROMPT_T0 :: BEAT * 2 // the first key
REPLY :: "what shall we make?"
REPLY_T0 :: BAR * 29 + STEP * 10

@(private = "file")
events: Events
@(private = "file")
events_once: sync.Once

// Every note and hit of the piece.
ev :: proc() -> ^Events {
	sync.once_do(&events_once, proc() {
		e := &events
		for b in 1 ..= BARS {
			ch := CHORDS[(b - 1) % 4]
			t0 := bar(b)
			append(&e.chords, t0)
			intro := b <= 4
			wake := b >= 5 && b <= 8
			rise := b >= 9 && b <= 12
			build := b >= 13 && b <= 16
			drop := b >= 17 && b <= 28
			outro := b >= 29

			// ---- drums
			if wake {
				append(&e.hearts, bar(b, 0), bar(b, 3), bar(b, 8), bar(b, 11))
			}
			if rise || b == 13 || b == 14 || drop {
				for s in 0 ..< 4 do append(&e.kicks, bar(b, f32(s * 4)))
			}
			if (b >= 11 && b <= 14) || drop {
				append(&e.claps, bar(b, 4), bar(b, 12))
			}
			if rise || b == 13 || b == 14 || drop {
				for s in 0 ..< 16 {
					off := s % 4 == 2
					switch {
					case off && (b >= 13 || b >= 11):
						append(&e.hats, Note{bar(b, f32(s)), b >= 13 ? 0.16 : 0.05, 0, 0.8})
					case off:
						append(&e.hats, Note{bar(b, f32(s)), 0.04, 0, 0.7})
					case b >= 11 && s % 2 == 1:
						append(&e.hats, Note{bar(b, f32(s)), 0.025, 0, s % 4 == 3 ? 0.42 : 0.28})
					case drop && s % 4 == 0:
						append(&e.hats, Note{bar(b, f32(s)), 0.02, 0, 0.2})
					}
				}
			}
			// fills: the last beat of every fourth bar of the drop
			if drop && b % 4 == 0 {
				for s in 12 ..< 16 do append(&e.snares, Note{bar(b, f32(s)), 0, 0, 0.5 + 0.12 * f32(s - 12)})
				if b == 28 do for s in 8 ..< 12 do append(&e.snares, Note{bar(b, f32(s)), 0, 0, 0.35 + 0.04 * f32(s - 8)})
			}
			// the build: eighths, then sixteenths, then thirty-seconds
			if b == 15 {
				for s := 0; s < 16; s += 2 do append(&e.snares, Note{bar(b, f32(s)), 0, 0, 0.3 + 0.25 * f32(s) / 16})
			}
			if b == 16 {
				for s in 0 ..< 12 do append(&e.snares, Note{bar(b, f32(s)), 0, 0, 0.5 + 0.3 * f32(s) / 12})
				for s in 24 ..< 30 do append(&e.snares, Note{bar(b, f32(s) / 2), 0, 0, 0.8 + 0.2 * f32(s - 24) / 6})
			}

			// ---- bass
			switch {
			case rise:
				for s := 0; s < 16; s += 2 do if s % 4 != 0 || b >= 11 {
					append(&e.bass, Note{bar(b, f32(s)), STEP * 1.6, ch.bass, s % 4 == 2 ? 0.9 : 0.6})
				}
			case b == 13 || b == 14:
				for s := 2; s < 16; s += 4 do append(&e.bass, Note{bar(b, f32(s)), STEP * 1.7, ch.bass, 0.9})
			case drop:
				for s in 0 ..< 16 {
					switch s % 4 {
					case 2:
						append(&e.bass, Note{bar(b, f32(s)), STEP * 0.95, ch.bass, 1})
					case 3:
						append(&e.bass, Note{bar(b, f32(s)), STEP * 0.8, ch.bass + (s == 15 ? 12 : 0), 0.7})
					case 1:
						if s == 9 do append(&e.bass, Note{bar(b, f32(s)), STEP * 0.7, ch.bass + 12, 0.5})
					}
				}
			}

			// ---- harmony
			switch {
			case intro:
				// one long D minor, thinning in
				if b == 1 do for n, i in ([?]f32{38, 50, 57, 62, 64}) do append(&e.pads, Note{t0 + f32(i) * 0.7, 4 * BAR - f32(i) * 0.7, n, 0.65})
			case wake || rise || build:
				for n in ch.pad do append(&e.pads, Note{t0, BAR * 0.98, n, wake ? 0.55 : (rise ? 0.7 : 0.85)})
			case drop:
				for s in STAB_STEPS do for n in ch.pad[1:] {
					append(&e.stabs, Note{bar(b, s), STEP * 1.5, n + 12, s == 0 ? 1 : 0.8})
				}
				for n in ch.pad do append(&e.pads, Note{t0, BAR * 0.98, n, 0.5})
			case outro:
				if b <= 30 do for n in ch.pad do append(&e.pads, Note{t0, BAR * 0.98, n, 0.8})
				// the last chord: D minor again, held to the end
				if b == 31 do for n in CHORDS[0].pad do append(&e.pads, Note{t0, 2 * BAR - 0.6, n, 0.8})
			}

			// ---- arpeggio
			if wake || rise || build || drop || b == 29 || b == 30 {
				for s in 0 ..< 16 {
					if b >= 29 && s % 2 == 1 do continue // thinning out
					if b == 30 && s % 4 != 0 do continue
					n := ch.arp[ARP_PATTERN[s]]
					if b >= 25 && b <= 28 && s % 4 == 3 do n += 12
					vel: f32 = s % 4 == 0 ? 1 : (s % 2 == 0 ? 0.8 : 0.62)
					if wake do vel *= 0.55 + 0.45 * f32(b - 5) / 3
					append(&e.arp, Note{bar(b, f32(s)), STEP * 0.85, n, vel})
				}
			}

			// ---- melody
			if drop {
				phrase := LEAD_A[(b - 1) % 4]
				if b == 24 do phrase = LEAD_LIFT
				up: f32 = b >= 25 ? 12 : 0
				for n in phrase do append(&e.lead, Note{bar(b, n.t), n.dur * STEP * 0.92, n.midi + up, n.vel})
			}
		}

		// ---- lone notes over the opening and the ending
		append(&e.pings, Note{bar(1), 2, 81, 0.8}, Note{bar(2, 8), 2, 77, 0.6}, Note{bar(3), 2, 86, 0.7}, Note{bar(4), 2, 84, 0.6}, Note{bar(4, 8), 2, 81, 0.5})
		append(&e.pings, Note{bar(29), 2, 81, 0.8}, Note{bar(30), 2, 77, 0.7}, Note{bar(31), 3, 86, 0.8}, Note{bar(31, 8), 3, 81, 0.6}, Note{bar(32), 3, 74, 0.6})

		// ---- the keyboard
		i := 0
		for r in PROMPT {
			if r != ' ' do append(&e.ticks, Note{PROMPT_T0 + f32(i) * STEP, 0, 60 + 12 * fx.hash01(5, i), 0.8})
			i += 1
		}
		append(&e.ticks, Note{bar(2, 8), 0, 48, 1.2}) // return
		i = 0
		for r in REPLY {
			if r != ' ' do append(&e.ticks, Note{REPLY_T0 + f32(i) * STEP, 0, 60 + 12 * fx.hash01(9, i), 0.8})
			i += 1
		}
	})
	return &events
}

// ---------------------------------------------------------------- sounds

PAD :: fx.Patch {
	wave = .Saw, voices = 7, detune = 30, width = 0.9, attack = 0.35, decay = 1.2, sustain = 0.8, release = 0.9,
	cutoff = 5200, q = 0.7, gain = 0.2,
}
STAB :: fx.Patch {
	wave = .Saw, voices = 7, detune = 34, width = 1, attack = 0.004, decay = 0.2, sustain = 0.45, release = 0.2,
	cutoff = 1400, env = 5200, env_decay = 0.22, track = 0.3, q = 0.9, gain = 0.15,
}
PLUCK :: fx.Patch {
	wave = .Saw, voices = 2, detune = 12, width = 0.5, attack = 0.002, decay = 0.13, sustain = 0, release = 0.12,
	cutoff = 420, env = 5200, env_decay = 0.12, track = 0.5, q = 1.9, gain = 0.3,
}
BASS :: fx.Patch {
	wave = .Saw, sub = 1.1, attack = 0.004, decay = 0.1, sustain = 0.6, release = 0.05,
	cutoff = 190, env = 1100, env_decay = 0.11, q = 1.3, drive = 0.35, gain = 0.62,
}
LEAD :: fx.Patch {
	wave = .Saw, voices = 3, detune = 16, width = 0.6, sub = 0.25, attack = 0.012, decay = 0.35, sustain = 0.72, release = 0.28,
	cutoff = 2400, env = 3600, env_decay = 0.3, track = 0.5, q = 1.1, vibrato = 14, vib_delay = 0.22, bend = -0.5, bend_time = 0.05, gain = 0.3,
}
LEAD_AIR :: fx.Patch {
	wave = .Square, voices = 2, detune = 9, width = 0.8, attack = 0.02, decay = 0.3, sustain = 0.6, release = 0.3,
	cutoff = 3800, q = 0.8, vibrato = 10, vib_delay = 0.25, gain = 0.09,
}
PING :: fx.Patch {
	wave = .Sine, attack = 0.003, decay = 0.9, sustain = 0, release = 1.2, gain = 0.22,
}
PING_AIR :: fx.Patch {
	wave = .Triangle, attack = 0.002, decay = 0.25, sustain = 0, release = 0.3, gain = 0.07,
}
RISE :: fx.Patch {
	wave = .Saw, voices = 5, detune = 40, width = 1, attack = 2.8, decay = 1, sustain = 1, release = 0.03,
	cutoff = 6000, q = 0.8, bend = -12, bend_time = 3.7, gain = 0.2,
}

// A key going down: a tiny click with a pitch.
tick :: proc(out: []fx.Sample, at, midi, vel: f32) {
	i0 := int(at * fx.RATE)
	n := int(0.05 * fx.RATE)
	r := fx.rng(u32(i0) + 31)
	hp: fx.Biquad
	fx.biquad_set(&hp, .High, 2200)
	hz := fx.note_hz(midi + 36)
	for j in 0 ..< n {
		i := i0 + j
		if i < 0 || i >= len(out) do continue
		t := f32(j) / fx.RATE
		nz := fx.biquad_run(&hp, {fx.rand(&r) * 2 - 1, fx.rand(&r) * 2 - 1}) * math.exp(-t * 520)
		tone := math.sin(t * hz * math.TAU) * math.exp(-t * 160) * 0.35
		thud := math.sin(t * 180 * math.TAU) * math.exp(-t * 90) * 0.5
		out[i] += (nz + fx.Sample{tone + thud, tone + thud}) * (0.2 * vel)
	}
}

// ---------------------------------------------------------------- the mix

Song :: struct {
	mix:    []fx.Sample,
	level:  []f32, // loudness of the whole mix every 10 ms
	low:    []f32, // of kick and bass
	melody: []f32, // of the lead
}

@(private = "file")
rendered: Song
@(private = "file")
rendered_once: sync.Once

// The piece as samples, rendered once per process (a few seconds).
song :: proc() -> ^Song {
	sync.once_do(&rendered_once, proc() {rendered = render_song()})
	return &rendered
}

// The Sound's generator: hands the mix to the renderer.
music :: proc(out: []fx.Sample) {
	copy(out, song().mix)
}

@(private = "file")
render_song :: proc() -> Song {
	e := ev()
	n := int(LENGTH * fx.RATE)
	bus :: proc(n: int) -> []fx.Sample {return make([]fx.Sample, n)}
	out := bus(n)
	drums, low, pads, stabs, arp, lead, air, wet, echoes := bus(n), bus(n), bus(n), bus(n), bus(n), bus(n), bus(n), bus(n), bus(n)
	defer {
		delete(drums); delete(low); delete(pads); delete(stabs); delete(arp); delete(lead); delete(air); delete(wet); delete(echoes)
	}

	// ---- drums
	kicks := bus(n)
	defer delete(kicks)
	for t in e.kicks do fx.kick(kicks, t, t < bar(15) ? 0.8 : 1)
	for t, i in e.hearts do fx.kick(kicks, t, i % 2 == 0 ? 0.62 : 0.4, hz = 44, punch = 60, length = 0.2, click = 0)
	snares := bus(n)
	defer delete(snares)
	for t in e.claps do fx.clap(snares, t, 0.8)
	for s in e.snares do fx.snare(snares, s.t, s.vel)
	for h, i in e.hats do fx.hat(drums, h.t + (i % 2 == 1 ? 0.004 : 0), h.vel, h.dur, pan = i % 2 == 0 ? -0.25 : 0.3)
	for b in ([?]int{17, 21, 25, 29}) do fx.crash(drums, bar(b), b == 29 ? 0.8 : 1)
	fx.crash(drums, bar(9), 0.5)

	// ---- instruments
	for x in e.bass do fx.play(low, BASS, x.t, x.dur, x.midi, x.vel)
	for x in e.pads {
		p := PAD
		if x.t < bar(5) do p.attack = 2.4
		if x.t >= bar(29) do p.release = 2.5
		fx.play(pads, p, x.t, x.dur, x.midi, x.vel)
	}
	for x in e.stabs do fx.play(stabs, STAB, x.t, x.dur, x.midi, x.vel)
	for x in e.arp do fx.play(arp, PLUCK, x.t, x.dur, x.midi, x.vel)
	for x in e.lead {
		fx.play(lead, LEAD, x.t, x.dur, x.midi, x.vel)
		fx.play(lead, LEAD_AIR, x.t, x.dur, x.midi + 12, x.vel)
	}
	for x in e.pings {
		fx.play(air, PING, x.t, 0.05, x.midi, x.vel)
		fx.play(air, PING_AIR, x.t, 0.03, x.midi + 12, x.vel)
	}
	for x in e.ticks do tick(air, x.t, x.midi, x.vel)

	// ---- risers, impacts, air
	fx.sweep_noise(air, bar(4, 4), BAR * 0.75, 400, 7000, vel = 0.5) // into the pulse
	fx.sweep_noise(air, bar(8, 6), BAR * 0.62, 500, 9000, vel = 0.6) // into the beat
	fx.sweep_noise(air, bar(15), BAR * 2 - STEP, 250, 11000, vel = 1.1) // the build
	fx.play(air, RISE, bar(15), BAR * 2 - STEP * 1.2, 74, 0.8)
	fx.sweep_noise(air, bar(24, 8), BAR * 0.5, 600, 10000, vel = 0.7)
	fx.sweep_noise(air, bar(28, 4), BAR * 0.75, 500, 10000, vel = 0.8)
	for b in ([?]int{17, 25, 29}) {
		fx.impact(drums, bar(b), b == 17 ? 0.6 : 0.45)
		fx.sweep_noise(air, bar(b), BAR, 300, 8000, up = false, vel = 0.6)
	}
	fx.impact(drums, bar(9), 0.35)
	fx.impact(drums, bar(5), 0.3)

	// ---- movement: filters opening, the pump
	fx.sweep_filter(pads, proc(t: f32) -> f32 {
		switch {
		case t < bar(5):
			return 180 * math.pow(5, t / bar(5)) // 180 → 900
		case t < bar(13):
			return 900 * math.pow(3.2, (t - bar(5)) / (bar(13) - bar(5))) // → 2900
		case t < bar(17):
			return 2900 * math.pow(4, (t - bar(13)) / (bar(17) - bar(13))) // → 11600
		case t < bar(29):
			return 9000
		}
		return 7000 * math.pow(0.07, (t - bar(29)) / (LENGTH - bar(29))) // closing: → 500
	}, 0.9)
	fx.sweep_filter(arp, proc(t: f32) -> f32 {
		switch {
		case t < bar(9):
			return 500 * math.pow(9, fx.clamp01((t - bar(5)) / (bar(9) - bar(5)))) // 500 → 4500
		case t < bar(13):
			return 5000
		case t < bar(17):
			return 5000 * math.pow(2.4, (t - bar(13)) / (bar(17) - bar(13)))
		case t < bar(29):
			return 12000
		}
		return 9000 * math.pow(0.1, (t - bar(29)) / (bar(31) - bar(29)))
	}, 1.1)
	fx.duck(low, e.kicks[:], 0.85, 0.2)
	fx.duck(pads, e.kicks[:], 0.6, 0.34)
	fx.duck(stabs, e.kicks[:], 0.5, 0.3)
	fx.duck(arp, e.kicks[:], 0.35, 0.28)
	fx.duck(lead, e.kicks[:], 0.2, 0.25)
	fx.automate(arp, proc(t: f32) -> f32 {
		if t >= bar(17) && t < bar(29) do return 0.8 // under the melody
		return 1
	})

	// ---- space: reverb and echoes
	fx.send(wet, pads, 0.5)
	fx.send(wet, stabs, 0.45)
	fx.send(wet, arp, 0.5)
	fx.send(wet, lead, 0.45)
	fx.send(wet, snares, 0.4)
	fx.send(wet, air, 1.2)
	fx.send(echoes, arp, 0.5)
	fx.send(echoes, lead, 0.42)
	fx.send(echoes, air, 0.7)
	fx.echo(echoes, STEP * 3, 0.5, true, 3800) // dotted eighths
	fx.send(wet, echoes, 0.5)
	fx.reverb(wet, 0.86, 0.42, 1, 0.02)
	fx.sweep_filter(wet, proc(t: f32) -> f32 {return 180}, 0.7, high = true)
	fx.duck(wet, e.kicks[:], 0.4, 0.3)

	// -define:STEMS=true prints how loud each bus is in each section: the mixing desk's meters
	when #config(STEMS, false) {
		stat :: proc(name: string, b: []fx.Sample) {
			fmt.eprintf("%8s", name)
			for sec in ([?][2]int{{1, 5}, {5, 9}, {9, 13}, {13, 17}, {17, 25}, {25, 29}, {29, 33}}) {
				acc, peak: f32
				a, z := int(bar(sec[0]) * fx.RATE), min(int(bar(sec[1]) * fx.RATE), len(b))
				for x in b[a:z] {
					acc += x[0] * x[0] + x[1] * x[1]
					peak = max(peak, abs(x[0]), abs(x[1]))
				}
				fmt.eprintf("  %6.1f/%5.1f", 10 * math.log10(acc / f32(2 * (z - a)) + 1e-12), 20 * math.log10(peak + 1e-9))
			}
			fmt.eprintln()
		}
		fmt.eprintln("  rms/peak dB:   intro         wake          rise          build         drop          drop2         outro")
		stat("kicks", kicks); stat("snares", snares); stat("drums", drums); stat("low", low); stat("pads", pads); stat("stabs", stabs)
		stat("arp", arp); stat("lead", lead); stat("air", air); stat("echoes", echoes); stat("wet", wet)
	}

	// ---- sum
	fx.send(out, kicks, 0.85)
	fx.send(out, snares, 0.6)
	fx.send(out, drums, 0.72)
	fx.send(out, low, 1)
	fx.send(out, pads, 0.75)
	fx.send(out, stabs, 1.3)
	fx.send(out, arp, 1.6)
	fx.send(out, lead, 1.65)
	fx.send(out, air, 0.8)
	fx.send(out, echoes, 0.7)
	fx.send(out, wet, 0.55)

	// no rumble below the kick, then loud and safe
	fx.sweep_filter(out, proc(t: f32) -> f32 {return 26}, 0.7, high = true)
	fx.automate(out, proc(t: f32) -> f32 {
		// in from silence, out to silence
		return min(fx.clamp01(t / 0.3), fx.clamp01((LENGTH - 0.05 - t) / 2.2))
	})
	when #config(STEMS, false) do stat("sum", out)
	fx.limit(out, 0.78, 0.72)

	s := Song{mix = out}
	s.level = fx.levels(out)
	both := bus(n)
	defer delete(both)
	fx.send(both, kicks)
	fx.send(both, low)
	s.low = fx.levels(both)
	s.melody = fx.levels(lead)
	return s
}
