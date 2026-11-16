# effects

Videos as code: every frame is a pure function of time, drawn with Skia from
Odin. A CLI renders projects to MP4; a desktop editor previews them on the
GPU, hot-reloads the code on save and lets you move scenes and cues on a
timeline.

```bash
./build.sh                                  # shim + CLI + editor → build/
build/effects-edit projects/demo            # preview, timeline, hot reload
build/effects render projects/demo          # → projects/demo/.effects/demo.mp4
build/effects render projects/demo --crf 16 --tune grain  # dark, grainy films: keep the grain
build/effects still projects/demo 2.5 7.6   # PNGs → .effects/stills/ (--release 1: from the optimized build)
build/effects mix projects/demo             # the sounds alone → .effects/demo.wav
build/effects bench projects/demo           # ms per frame, one thread
build/effects beats song.wav                # hits, tempo and drops, to cut to
./remote.sh root@192.168.67.107 projects/demo  # render on the render box, fetch the MP4
```

Projects here: `demo` (a product spot), `showreel` (a tour of the features,
cut to music), `palantir` (a fan edit), `palantir2` (a faster one, mostly
defense footage), `palantir3` (faster again, on two tracks, with halftone,
dither and Octra's mark), `palantir4` (the third, shorter, with calmer cuts
on the first track and a hard switch between the tracks) and `aufruestung`
(German rearmament on Rammstein's "Sonne", its chorus counting in a company a
line, with its own look and transitions: gradient maps, bloom, terminal glyphs,
edge scans, burns, melts, datamoshing, shots opening inside numbers). The edits are
internal testing only: run their
`fetch.sh` first; the showreel borrows the first one's track and footage.

`fable` is the one project in this repository: a one-minute self-portrait of
the model that wrote it, with no footage, no images and no samples. Its
score (32 bars at 128 bpm) is rendered by `fx`'s synth from lists of notes,
and the pictures read the same lists, so they hit what the music hits. One
scene shows the editor with its own source (`#load`ed into the video) next
to a preview of itself. `build/effects render projects/fable` takes about
13 minutes on 8 cores (3,600 frames, most of them with full-screen shaders).

## Layout

- `shim/` — a C ABI over Skia (`sk.h`): surfaces, paths, gradients, layers
  (opacity, blur, grayscale, backdrop blur), images, paragraph text with a
  per-thread layout cache, SkSL shaders, PNG export, a GL context for the
  editor. Built into `build/libskshim.so` with Skia linked in statically.
- `sk/` — Odin bindings for the shim.
- `fx/` — the library scenes are written with:
  - `anim` — `prog`, `ep`, `win`, eases, `spring`, `stagger`, `typed`, keyframes
  - `draw` — shapes, text, icons, images, `group` (move/scale/tilt/fade/blur,
    grade, blend, filter or make glow what's inside its scope), `frosted`,
    `bake` (render a static layer once); paints: `linear`, `radial`, `sweep`,
    and `additive`, `trimmed` (lines that draw themselves), `soft` on any of
    them
    (gradients and shaders are dithered, so slow dark ones don't band;
    drawn through `bake` at less than full size they lose that)
  - `post` — grading (`contrast`, `sat`, `tint`, `invert`, … on any group)
    and pixel filters: `rgb_split`, `glitch`, `zoom_blur`, `pixelate`,
    `duotone`, `scanlines`, `halftone`, `dither`, `lens` (barrel distortion
    with color fringes), `shockwave`, `kaleido`, `warp`, `stretch`, or any
    SkSL via `post`. A group's post runs before its grade; to filter graded
    footage (dither after a gray grade), put the post on a group around it.
    `Xf.glow` is bloom (and anamorphic streaks) made of Skia's own blur
  - `shade` — pictures made by shaders: `shader_scaled` (SkSL drawn small
    and scaled up: smooth fields at a fraction of the cost), `nebula`,
    `orb` (a raymarched iridescent body), `tunnel`
  - `space` — a little 3D: `Cam`, `project`, `line3`, `bokeh` (dots with
    depth of field), `spark`, `fib_sphere`, `gauss3`, `spline3`
  - `type` — text letter by letter: `letters` (staggered rises, blurs,
    spins), `scramble` (text being decoded), `glyphs`
  - `edit` — for cutting to music: `beat`, `pulse`, `hit`, `shake`,
    `camera`, `flash`, `letterbox`, `transition` (whips, zoom, spin, glitch,
    blur, fade between overlapping scenes), `ramp` (speed ramps), `slam`,
    `outline`
  - `media` — footage: `footage(file, t, r)` draws a video file's frame
  - `audio` — `Sound`s on the timeline and their mix, plus analysis of audio
    files: `onsets` (hits per band), `drops`, `spectrum`
  - `synth` — sounds made by code: `whoosh`, `boom`, `riser`, `click`,
    `sub_drop`
  - `music` — a small offline studio for scores made by code: `play` (a
    subtractive synth: unison oscillators, filter and amp envelopes, drive,
    vibrato), drums (`kick`, `clap`, `snare`, `hat`, `crash`, `impact`,
    `sweep_noise`), buses with `duck` (side-chain pumping), `sweep_filter`,
    `reverb`, `echo`, `limit`, and `levels` for pictures that follow them
  - `layout` — a small flexbox for mockups: `layout`, `box`, `item`, `txt`,
    `glyph`, `picture`, `spacer`; every element can be animated and found
    again with `rect_of(id)`
  - `ui` — the product's look: `backdrop`, `window`, `phone`, `sidebar`,
    `topbar`, `pill`, `button`, `kpi`, `table_head`/`table_row`, `bars`,
    `meter`, `avatar`, `bubble`, `cursor`, `highlight`, `kinetic`, `vo_text`,
    `caption`, `eyebrow`, `mark`, `vignette`, `grain`
  - `theme` — colors and fonts (`LIERMANN` by default)
  - `vo` — voice-over word timings from a v3 `timeline.json`: `W`, `WE`, `SC`
  - `video` — `Video`, `Scene`, `Cue`, `Shot`, `fade`, `cue`; `Video.master`
    wraps all scenes in one group (the film's lens, glow, grade and camera)
  - `icons` — the app's icon set (generated from v3/src/icons.js)
- `host/` — shared by CLI and editor: compiles a project into a shared
  library, loads it, applies `timing.json`.
- `cli/`, `editor/` — the two programs.
- `nix/skia.nix` — Skia from nixpkgs, rebuilt with clang (its raster
  pipeline only fully vectorizes under clang: a full-screen gradient took
  ~20 ms with the gcc build, ~5 ms with clang) and as static libraries
  (the shared `libskparagraph.so` exports none of its classes).

## A project

A project is a directory of Odin files (package name = anything) that
exports one procedure:

```odin
package spot

import fx "effects:fx"

@(export)
effects_video :: proc() -> ^fx.Video {
	return fx.video({
		name = "Spot",
		audio = "audio/mix.wav",     // muxed into renders, played in the editor
		vo = "timeline.json",        // optional voice-over word timings
		scenes = SCENES[:],
		cues = CUES[:],
		overlay = proc(t: f32) {fx.vignette(0.35); fx.grain(0.035)},
	})
}

SCENES := [?]fx.Scene {
	{name = "intro", start = 0, dur = 3.4, draw = intro},
	{name = "dash", vo = "dash", draw = dash}, // start/length from the voice-over scene
}
CUES := [?]fx.Cue{{"click", 6.2}}

intro :: proc(s: fx.Shot) {
	fx.backdrop(.Night)
	if fx.group({o = fx.fade(s), y = 30 * (1 - fx.ep(s.t, s.start, s.start + 0.6))}) {
		fx.caption("Alle Kontakte.", {160, 440}, 112, fx.theme.nt)
	}
}
```

`s.t` is video time, `s.lt` time since the scene started, `s.p` progress
through the scene. Scenes may overlap; they're drawn in list order.
`fx.cue("click")` returns a cue's time. Scenes and cues dragged in the
editor are saved to the project's `timing.json` (only what differs from the
code); Delete on a selected scene or cue resets it.

Scenes can also be built in code (the Palantir edit makes one per bass hit):
`fx.video` copies whatever list it gets, and `Scene.data` is handed to the
scene's draw as `Shot.data`.

Scene and cue tables must be globals (the slices are copied, but the
literal must live long enough to be copied). Paths are relative to the
project directory. Build output goes to `<project>/.effects/`.

## Sound

```odin
SOUNDS := [?]fx.Sound {
	{name = "music", file = "assets/song.wav", from = 33.5, dur = 30, fade_out = 1, cutoff = muffled},
	{name = "boom", gen = fx.boom, at = 5.56, dur = 2, volume = 0.5},
	{name = "swell", file = "assets/crash.wav", at = 3, reverse = true, speed = 0.8},
	{name = "talk", file = "assets/interview.mp4", from = 61, at = 9, dur = 3, stretch = true, speed = 1.2},
}
muffled :: proc(t: f32) -> f32 {return t < 5.56 ? 700 : 0} // low-pass until the drop
```

A sound plays a file (anything ffmpeg decodes, video soundtracks too) or a
generator from `at`, `from` seconds into it, for `dur`, optionally `loop`ed.
It can be changed with `volume`, `pan`, `fade_in`/`fade_out`, `speed` (tape-style, or
pitch-preserving with `stretch`), `reverse`, `lowpass`/`highpass`, and
automated over time with `gain`, `rate` (tape stops) and `cutoff` (filter
sweeps), each a `proc(t: f32) -> f32` of video time. The renderers mix
everything to 48 kHz stereo with a soft limiter at -1 dBFS.

A score can be code too. A generator fills its buffer with whatever it
mixes from notes and drum hits:

```odin
PAD :: fx.Patch{wave = .Saw, voices = 7, detune = 30, width = 0.9, attack = 0.3, sustain = 0.8, release = 0.9, cutoff = 3000, gain = 0.2}
song :: proc(out: []fx.Sample) {
	pads := make([]fx.Sample, len(out)); defer delete(pads)
	kicks := [?]f32{0, 0.5, 1, 1.5}
	for n in ([?]f32{50, 53, 57, 60}) do fx.play(pads, PAD, at = 0, dur = 2, midi = n)
	for t in kicks do fx.kick(out, t)
	fx.duck(pads, kicks[:], 0.6, 0.3) // the pump
	fx.send(out, pads)
	fx.limit(out)
}
SOUNDS := [?]fx.Sound{{name = "score", gen = song, dur = 2}}
```

Everything is deterministic, and a 60 s piece with a dozen buses renders in
about two seconds. `projects/fable/music.odin` is a whole arrangement.

To cut to music: `fx.onsets(file, .Bass)` finds the hits (kicks, 808s;
`.High` for snares and hats), `fx.times` moves them to video time, and
`fx.pulse(beats, t)` / `fx.beat(beats, t)` turn them into motion. Results
are cached under `.effects/analysis`. Put them in `Video.marks` to see them
in the editor and snap to them.

## Footage

`fx.footage("assets/clip.mp4", src_time, r, focus = {0.6, 0.4}, zoom = 1.2)`
draws a video's frame like an image. Each render thread reads frames from its
own ffmpeg pipe that keeps playing forward, so consecutive frames are cheap;
cuts restart it. Footage recut with a keyframe every 12 frames
(`ffmpeg -i in.mp4 -an -c:v libx264 -g 12 out.mp4`) restarts fastest.

## Editor

`Space` play/pause · `←`/`→` one frame (`Shift`: one second) · `↑`/`↓`
previous/next scene · `Home`/`End` · `L` loop the scene under the playhead
(double-click a scene does the same) · `R` rebuild · `0` zoom to fit · `S`
save a still · wheel zooms the timeline, `Shift`+wheel scrolls · drag scene
bodies/edges, cues and sounds; they snap to the playhead, scene edges,
cues, sound starts, marks and voice-over words (`Alt` disables snapping).
The audio lane shows the mix, which is what plays.

Saving any `.odin` file (or `timeline.json`) in the project recompiles it
(`-o:none`, ~0.4 s) and swaps the code in under the playhead. Build errors
are shown over the preview.

## Numbers (this laptop, 16 threads, 1080p)

- Compile a project: ~0.4 s unoptimized (editor), ~3 s `-o:speed` (render).
- Editor preview (GPU): ~1 ms per frame for the demo.
- CPU raster, one thread: UI elements (text, rects, layers) ~2 ms per frame;
  each full-screen pass (backdrop gradient, vignette, grain) ~5 ms. The demo
  averages ~32 ms with grain, vignette and backdrop on.
- Full render of the 12.4 s demo at 60 fps: ~20 s with 16 workers; x264
  encoding is the bottleneck, not drawing.
- SkSL on the CPU is the expensive thing: a full-screen field of warped
  noise or a raymarched body costs ~2 s per 1080p frame on one thread.
  `shader_scaled` draws such pictures at a third or half of the resolution
  (0.1–0.5 s); a post filter reading each pixel three times, ~0.05 s; glow,
  being Skia's blur, ~0.02 s.
- The showreel (30.6 s, 60 fps, shaders and footage): 50 s. The Palantir
  edit (48.6 s, 30 fps, footage on every frame): 62 s, peaking at ~15 GB:
  each worker has an encoder and up to two footage decoders (~1 GB in all),
  so the default worker count is capped by available memory.
- On the render box: showreel 22 s, Palantir 22–25 s with NVENC (35 s with
  x264 there). x264 costs ~50 ms of CPU per frame, NVENC ~15 ms (most of it
  the BGRA→BT.709 YUV conversion, kept on the CPU so both encoders tag and
  convert the same way).

## Render box

`remote.sh <host> <project> [render options]` renders on another Linux
machine: it copies the nix store paths `build/` links against plus the odin
toolchain into the machine's `/nix/store` (no nix needed there), syncs the
repo to the same path as here, renders and fetches the MP4. Later runs only
send what changed. The machine's own ffmpeg encodes; `render --encoder auto`
(the default) uses NVENC when a test encode works, else x264. Both use
quality 18 (x264 CRF, NVENC constant QP: the same quality within ~1 dB, the
NVENC files ~15% bigger); NVENC's VBR mode is not used because it caps the
bitrate and smears grain. On the box, Debian's ffmpeg 7.1 NVENC encoder now
and then dies mid-stream on long, grainy renders (a segfault copying a frame,
or a rejected frame); a chunk whose encoder fails is drawn again and encoded
with x264, so the render finishes. More sessions fail more often, so NVENC
renders use at most 12 workers (as fast as 22).

The box is CT 105 on the Proxmox host `bigone` (24 threads, 32 GB, Quadro
RTX 4000 on the host's NVIDIA 595.112.07 driver; the container has the same
version's libraries without the kernel module, so the two must be upgraded
together). It draws pixel-identical frames to this laptop.

## Not yet

- Rich text runs inside one paragraph (mixed weights/colors in one line) —
  for now, compose with layout rows or `kinetic`.
- Undo in the editor (`timing.json` is small enough to keep in git).
- Scrubbing footage in the editor restarts a decoder per jump (~0.1 s).
