// effects-edit: preview and timeline for a video project.
//
//   effects-edit <project>
//
// Recompiles the project whenever a source file changes and swaps the new
// code in without losing the playhead. Scenes, cues and sounds can be dragged
// on the timeline; what moved is written to the project's timing.json, which
// the renderer applies on top of the times in code. Plays the video's sounds
// mixed, and shows its marks (beats) on the ruler.
//
//   Space play/pause · ←/→ frame (Shift: second) · ↑/↓ previous/next scene
//   Home/End · L loop the scene under the playhead · R rebuild
//   Delete reset the selected scene/cue/sound to its time in code · 0 zoom to fit
//   S save a still of the current frame · wheel zoom · Shift+wheel scroll
//
//   effects-edit <project> --shot out.png [--at t] [--wait s]
// opens the editor, waits for the first build (or s seconds), saves a
// screenshot of the window and exits (for checking the editor itself).
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import fx "effects:fx"
import "effects:host"
import sk "effects:sk"
import sdl "vendor:sdl3"

// Editor colors: the night palette.
BG :: 0xff0d0d0c
PANEL :: 0xff151513
LINE :: 0x1ff2f0e6
TEXT :: 0xfff2f0e6
MUTED :: 0x99f2f0e6
SUBTLE :: 0x5cf2f0e6
ACCENT :: 0xffdd5b3e
SCENE_COLORS := [?]fx.Color{0xff3b5b4a, 0xff4a4a6b, 0xff6b4a3b, 0xff3b546b, 0xff5e5a3a, 0xff5b3b5e}

TOP :: 40
GUTTER :: 92
RULER_H :: 26
LANE_H :: 30
CUE_H :: 26
SOUND_H :: 24
VO_H :: 26
WAVE_H :: 46
SNAP_PX :: 7

Drag_Kind :: enum {
	None,
	Scrub,
	Scene_Move,
	Scene_Start,
	Scene_End,
	Cue,
	Sound,
}

Drag :: struct {
	kind:        Drag_Kind,
	index:       int,
	grab_t:      f32, // time under the mouse when the drag started
	orig:        [2]f32, // the item's start/dur (or cue t) when it started
	moved:       bool,
	snap_t:      f32,
	snapped:     bool,
}

Selection :: struct {
	kind:  enum {
		None,
		Scene,
		Cue,
		Sound,
	},
	index: int,
}

Build :: struct {
	thread:  ^thread.Thread,
	done:    bool,
	ok:      bool,
	lib:     string,
	log:     string,
	secs:    f64,
	pending: bool,
}

Audio :: struct {
	lock:    sync.Mutex, // held by the audio thread while it reads samples
	samples: []fx.Sample, // the video's sounds mixed, RATE Hz
	peaks:   []f32, // max |sample| per PEAK_STEP frames
	stream:  ^sdl.AudioStream,
	cursor:  int, // next frame to play
	playing: bool,
}

RATE :: fx.RATE
PEAK_STEP :: 480 // 10 ms

Editor :: struct {
	win:        ^sdl.Window,
	gpu:        ^sk.Gpu,
	surf:       ^sk.Surface,
	pw, ph:     i32, // window in pixels
	ww, wh:     f32, // window in points
	dpr:        f32,
	frame:      ^sk.Surface, // the video, drawn on the GPU
	fw, fh:     i32,
	p:          host.Project,
	t:          f32,
	playing:    bool,
	play_t0:    f32,
	play_clock: time.Tick,
	loop:       bool,
	loop_a:     f32,
	loop_b:     f32,
	zoom:       f32, // px per second
	scroll:     f32, // seconds at the timeline's left edge
	fitted:     bool,
	mouse:      fx.Vec2,
	drag:       Drag,
	sel:        Selection,
	render_ms:  f64,
	build:      Build,
	error:      string, // last failed build's output
	stamp:      i64, // newest source mtime seen
	last_scan:  time.Tick,
	audio:      Audio,
	note:       string,
	note_until: time.Tick,
	cursors:    [Cursor_Kind]^sdl.Cursor,
	shot:       string,
	shot_wait:  int,
	shot_after: f64,
	started:    time.Tick,
}

Cursor_Kind :: enum {
	Default,
	Resize,
	Move,
}

e: Editor

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: effects-edit <project>")
		os.exit(2)
	}
	p, ok := host.open(os.args[1])
	if !ok do os.exit(1)
	e.p = p
	e.zoom = 60
	for i := 2; i + 1 < len(os.args); i += 2 {
		switch os.args[i] {
		case "--shot":
			e.shot = os.args[i + 1]
		case "--at":
			e.t, _ = strconv.parse_f32(os.args[i + 1])
		case "--wait":
			e.shot_after, _ = strconv.parse_f64(os.args[i + 1])
		}
	}

	if !sdl.Init({.VIDEO, .AUDIO}) {
		fmt.eprintln("SDL:", sdl.GetError())
		os.exit(1)
	}
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))
	sdl.GL_SetAttribute(.STENCIL_SIZE, 8)
	title := fmt.ctprintf("effects · %s", e.p.name)
	e.win = sdl.CreateWindow(title, 1600, 1000, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	if e.win == nil {
		fmt.eprintln("SDL:", sdl.GetError())
		os.exit(1)
	}
	gl := sdl.GL_CreateContext(e.win)
	sdl.GL_MakeCurrent(e.win, gl)
	sdl.GL_SetSwapInterval(1)
	e.gpu = sk.gpu_new_gl(proc "c" (_: rawptr, name: cstring) -> rawptr {return rawptr(sdl.GL_GetProcAddress(name))}, nil)
	if e.gpu == nil {
		fmt.eprintln("cannot create a Skia GL context")
		os.exit(1)
	}
	e.cursors = {
		.Default = sdl.CreateSystemCursor(.DEFAULT),
		.Resize  = sdl.CreateSystemCursor(.EW_RESIZE),
		.Move    = sdl.CreateSystemCursor(.POINTER),
	}
	fx.default_fonts()
	open_audio()

	e.started = time.tick_now()
	e.stamp = source_stamp()
	start_build()

	for {
		if !pump_events() do break
		poll_build()
		if e.playing {
			e.t = e.play_t0 + f32(time.duration_seconds(time.tick_since(e.play_clock)))
			end := e.loop ? e.loop_b : video_duration()
			if e.t >= end {
				if e.loop do seek(e.loop_a, true)
				else {
					e.t = end
					pause()
				}
			}
		}
		draw()
		free_all(context.temp_allocator)
		ready := e.shot_after > 0 ? time.duration_seconds(time.tick_since(e.started)) >= e.shot_after : video() != nil || e.error != ""
		if e.shot != "" && ready {
			e.shot_wait += 1
			if e.shot_wait > 5 {
				sk.surface_write_png(e.surf, strings.clone_to_cstring(e.shot, context.temp_allocator))
				fmt.println(e.shot)
				break
			}
		}
	}
}

video :: proc() -> ^fx.Video {return e.p.video}
video_duration :: proc() -> f32 {
	v := video()
	return v == nil ? 10 : max(v.duration, 0.1)
}
fps :: proc() -> int {
	v := video()
	return v == nil || v.fps == 0 ? 60 : v.fps
}

notify :: proc(msg: string) {
	delete(e.note)
	e.note = strings.clone(msg)
	e.note_until = time.tick_add(time.tick_now(), 2500 * time.Millisecond)
}

// ---------------------------------------------------------------- builds

source_stamp :: proc() -> i64 {
	newest: i64
	walk :: proc(dir: string, newest: ^i64, depth: int) {
		if depth > 4 do return
		files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		for f in files {
			if strings.has_prefix(f.name, ".") do continue
			if f.type == .Directory {
				walk(f.fullpath, newest, depth + 1)
				continue
			}
			if strings.has_suffix(f.name, ".odin") || f.name == "timeline.json" {
				newest^ = max(newest^, time.to_unix_nanoseconds(f.modification_time))
			}
		}
	}
	walk(e.p.dir, &newest, 0)
	return newest
}

start_build :: proc() {
	if e.build.thread != nil {
		e.build.pending = true
		return
	}
	e.build.done = false
	e.build.thread = thread.create_and_start_with_poly_data(&e.build, proc(b: ^Build) {
		start := time.tick_now()
		lib, ok, log := host.build(&e.p, false)
		b.lib = lib
		b.ok = ok
		b.log = strings.clone(log, runtime.default_allocator())
		b.secs = time.duration_seconds(time.tick_since(start))
		sync.atomic_store(&b.done, true)
	})
}

poll_build :: proc() {
	if time.duration_milliseconds(time.tick_since(e.last_scan)) > 300 {
		e.last_scan = time.tick_now()
		if s := source_stamp(); s != e.stamp {
			e.stamp = s
			start_build()
		}
	}
	b := &e.build
	if b.thread == nil || !sync.atomic_load(&b.done) do return
	thread.join(b.thread)
	thread.destroy(b.thread)
	b.thread = nil
	if b.ok {
		if host.load(&e.p, b.lib) {
			delete(e.error)
			e.error = ""
			if !e.fitted do zoom_to_fit()
			remix()
			notify(fmt.tprintf("compiled in %.2fs", b.secs))
		} else {
			e.error = strings.clone("the project built but could not be loaded (see terminal)")
		}
	} else {
		delete(e.error)
		e.error = b.log
		b.log = ""
		notify("build failed")
	}
	if b.pending {
		b.pending = false
		start_build()
	}
}

// ---------------------------------------------------------------- audio

open_audio :: proc() {
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = RATE}
	e.audio.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_feed, &e.audio)
	if e.audio.stream == nil {
		fmt.eprintln("no audio device:", sdl.GetError())
		return
	}
	sdl.ResumeAudioStreamDevice(e.audio.stream)
}

audio_feed :: proc "c" (userdata: rawptr, stream: ^sdl.AudioStream, additional, total: c.int) {
	a := (^Audio)(userdata)
	@(static) silence: [2048]f32
	frames := int(additional) / 8
	sync.mutex_lock(&a.lock)
	defer sync.mutex_unlock(&a.lock)
	have := 0
	cur := sync.atomic_load(&a.cursor)
	if sync.atomic_load(&a.playing) && len(a.samples) > 0 {
		have = clamp(len(a.samples) - cur, 0, frames)
		if cur >= 0 && have > 0 do sdl.PutAudioStreamData(stream, &a.samples[cur], c.int(have * 8))
		sync.atomic_store(&a.cursor, cur + frames)
	}
	for left := frames - have; left > 0; left -= len(silence) / 2 {
		n := min(left, len(silence) / 2)
		sdl.PutAudioStreamData(stream, &silence[0], c.int(n * 8))
	}
}

// Mixes the video's sounds again (after a load or a moved sound).
remix :: proc() {
	v := video()
	if v == nil do return
	samples := fx.mixdown(v, 0, video_duration())
	peaks := make([]f32, len(samples) / PEAK_STEP + 1)
	for x, i in samples {
		k := i / PEAK_STEP
		peaks[k] = max(peaks[k], abs(x[0]), abs(x[1]))
	}
	if len(v.sounds) == 0 {
		delete(peaks)
		peaks = nil
	}
	sync.mutex_lock(&e.audio.lock)
	old_s, old_p := e.audio.samples, e.audio.peaks
	e.audio.samples, e.audio.peaks = samples, peaks
	sync.mutex_unlock(&e.audio.lock)
	delete(old_s)
	delete(old_p)
}

// ---------------------------------------------------------------- transport

play :: proc() {
	if e.t >= video_duration() - 0.01 do e.t = 0
	e.playing = true
	e.play_t0 = e.t
	e.play_clock = time.tick_now()
	if e.audio.stream != nil {
		sdl.ClearAudioStream(e.audio.stream)
		sync.atomic_store(&e.audio.cursor, int(e.t * RATE))
		sync.atomic_store(&e.audio.playing, true)
	}
}

pause :: proc() {
	e.playing = false
	sync.atomic_store(&e.audio.playing, false)
	if e.audio.stream != nil do sdl.ClearAudioStream(e.audio.stream)
}

seek :: proc(t: f32, keep_playing := false) {
	was := e.playing
	if was do pause()
	e.t = clamp(t, 0, video_duration())
	if was && keep_playing do play()
}

frame_step :: proc(n: int) {
	f := math.round(e.t * f32(fps()))
	seek((f + f32(n)) / f32(fps()))
}

zoom_to_fit :: proc() {
	w := e.ww - GUTTER - 24
	if w <= 0 do return
	e.zoom = w / video_duration()
	e.scroll = 0
	e.fitted = true
}

// ---------------------------------------------------------------- events

pump_events :: proc() -> bool {
	ev: sdl.Event
	idle := !e.playing && e.drag.kind == .None && e.build.thread == nil && e.shot == ""
	got := idle ? sdl.WaitEventTimeout(&ev, 150) : sdl.PollEvent(&ev)
	for got {
		#partial switch ev.type {
		case .QUIT:
			return false
		case .KEY_DOWN:
			key(ev.key)
		case .MOUSE_MOTION:
			e.mouse = {ev.motion.x, ev.motion.y}
			mouse_move()
		case .MOUSE_BUTTON_DOWN:
			e.mouse = {ev.button.x, ev.button.y}
			if ev.button.button == sdl.BUTTON_LEFT do mouse_down(ev.button.clicks)
		case .MOUSE_BUTTON_UP:
			if ev.button.button == sdl.BUTTON_LEFT do mouse_up()
		case .MOUSE_WHEEL:
			wheel(ev.wheel)
		}
		got = sdl.PollEvent(&ev)
	}
	return true
}

key :: proc(k: sdl.KeyboardEvent) {
	shift := k.mod & sdl.KMOD_SHIFT != {}
	switch k.key {
	case sdl.K_SPACE:
		if e.playing do pause()
		else do play()
	case sdl.K_LEFT:
		if shift do seek(e.t - 1)
		else do frame_step(-1)
	case sdl.K_RIGHT:
		if shift do seek(e.t + 1)
		else do frame_step(1)
	case sdl.K_HOME:
		seek(0)
	case sdl.K_END:
		seek(video_duration())
	case sdl.K_UP, sdl.K_DOWN:
		jump_scene(k.key == sdl.K_DOWN)
	case sdl.K_L:
		toggle_loop()
	case sdl.K_R:
		start_build()
	case sdl.K_0:
		zoom_to_fit()
	case sdl.K_S:
		save_still()
	case sdl.K_DELETE, sdl.K_BACKSPACE:
		reset_selected()
	case sdl.K_ESCAPE:
		e.sel = {}
	}
}

jump_scene :: proc(forward: bool) {
	v := video()
	if v == nil do return
	best: f32 = forward ? max(f32) : -1
	for s in v.scenes {
		if forward && s.start > e.t + 0.001 && s.start < best do best = s.start
		if !forward && s.start < e.t - 0.001 && s.start > best do best = s.start
	}
	if best >= 0 && best < max(f32) do seek(best, true)
}

toggle_loop :: proc() {
	if e.loop {
		e.loop = false
		return
	}
	v := video()
	if v == nil do return
	for s in v.scenes {
		if e.t >= s.start && e.t < s.start + s.dur {
			e.loop, e.loop_a, e.loop_b = true, s.start, s.start + s.dur
			notify(fmt.tprintf("looping %s", s.name))
			return
		}
	}
}

reset_selected :: proc() {
	v := video()
	if v == nil do return
	switch e.sel.kind {
	case .None:
		return
	case .Scene:
		s := &v.scenes[e.sel.index]
		if d, ok := e.p.defaults.scenes[s.name]; ok do s.start, s.dur = d.start, d.dur
	case .Cue:
		cu := &v.cues[e.sel.index]
		if d, ok := e.p.defaults.cues[cu.name]; ok do cu.t = d
	case .Sound:
		so := &v.sounds[e.sel.index]
		if d, ok := e.p.defaults.sounds[so.name]; ok do so.at = d
		remix()
	}
	host.save_timing(&e.p)
	notify("reset to the time in code")
}

save_still :: proc() {
	v := video()
	if v == nil do return
	s := sk.surface_raster(i32(v.width), i32(v.height))
	defer sk.surface_free(s)
	f := fx.Frame{cv = sk.surface_canvas(s), t = e.t, scale = 1}
	v.render(&f)
	dir := fx.join({e.p.out, "stills"})
	os.make_directory_all(dir)
	path := fx.join({dir, fmt.tprintf("%07.2f.png", e.t)})
	sk.surface_write_png(s, strings.clone_to_cstring(path, context.temp_allocator))
	notify(fmt.tprintf("saved %s", path))
}

// ---------------------------------------------------------------- timeline geometry

Tracks :: struct {
	r:                                    fx.Rect, // whole panel
	ruler, scenes, cues, sounds, vo, wave: fx.Rect, // lanes, without the gutter
	lanes, sound_lanes:                   int,
}

scene_lanes :: proc(v: ^fx.Video, out: []int) -> int {
	spans := make([][2]f32, len(v.scenes), context.temp_allocator)
	for s, i in v.scenes do spans[i] = {s.start, s.dur}
	return pack_lanes(spans, out)
}

sound_lanes :: proc(v: ^fx.Video, out: []int) -> int {
	spans := make([][2]f32, len(v.sounds), context.temp_allocator)
	for &s, i in v.sounds {
		a, d := fx.sound_span(v, &s)
		spans[i] = {a, d}
	}
	return pack_lanes(spans, out)
}

// Gives each [start, dur] the first lane free at its start.
pack_lanes :: proc(spans: [][2]f32, out: []int) -> int {
	ends: [16]f32
	n := 0
	for sp, i in spans {
		lane := 0
		for lane < n && ends[lane] > sp[0] + 0.001 do lane += 1
		if lane >= len(ends) do lane = len(ends) - 1
		ends[lane] = sp[0] + sp[1]
		n = max(n, lane + 1)
		out[i] = lane
	}
	return max(n, 1)
}

tracks :: proc() -> Tracks {
	v := video()
	lanes, slanes := 1, 0
	if v != nil {
		tmp := make([]int, len(v.scenes), context.temp_allocator)
		lanes = scene_lanes(v, tmp)
		if len(v.sounds) > 0 {
			tmp = make([]int, len(v.sounds), context.temp_allocator)
			slanes = sound_lanes(v, tmp)
		}
	}
	has_vo := v != nil && v.vo_data != nil
	has_wave := len(e.audio.peaks) > 0
	h := f32(RULER_H + lanes * LANE_H + CUE_H + slanes * SOUND_H + 16)
	if has_vo do h += VO_H
	if has_wave do h += WAVE_H
	tr: Tracks
	tr.lanes, tr.sound_lanes = lanes, slanes
	tr.r = {0, e.wh - h, e.ww, h}
	x := f32(GUTTER)
	w := e.ww - GUTTER
	y := tr.r.y + 6
	tr.ruler = {x, y, w, RULER_H}
	y += RULER_H
	tr.scenes = {x, y, w, f32(lanes * LANE_H)}
	y += f32(lanes * LANE_H)
	tr.cues = {x, y, w, CUE_H}
	y += CUE_H
	if slanes > 0 {
		tr.sounds = {x, y, w, f32(slanes * SOUND_H)}
		y += f32(slanes * SOUND_H)
	}
	if has_vo {
		tr.vo = {x, y, w, VO_H}
		y += VO_H
	}
	if has_wave do tr.wave = {x, y, w, WAVE_H}
	return tr
}

x_of :: proc(t: f32) -> f32 {return GUTTER + 12 + (t - e.scroll) * e.zoom}
t_of :: proc(x: f32) -> f32 {return e.scroll + (x - GUTTER - 12) / e.zoom}

// What is under the mouse on the timeline.
hit :: proc() -> (kind: Drag_Kind, index: int) {
	v := video()
	tr := tracks()
	m := e.mouse
	if v == nil || !fx.contains(tr.r, m) do return .None, -1
	if fx.contains(tr.cues, m) {
		for c, i in v.cues do if abs(x_of(c.t) - m.x) <= 6 do return .Cue, i
	}
	if tr.sounds != {} && fx.contains(tr.sounds, m) {
		lanes := make([]int, len(v.sounds), context.temp_allocator)
		sound_lanes(v, lanes)
		lane := int((m.y - tr.sounds.y) / SOUND_H)
		for &s, i in v.sounds {
			a, d := fx.sound_span(v, &s)
			if lanes[i] == lane && m.x >= x_of(a) - 2 && m.x <= x_of(a + d) + 2 do return .Sound, i
		}
	}
	if fx.contains(tr.scenes, m) {
		lanes := make([]int, len(v.scenes), context.temp_allocator)
		scene_lanes(v, lanes)
		lane := int((m.y - tr.scenes.y) / LANE_H)
		for s, i in v.scenes {
			if lanes[i] != lane do continue
			x0, x1 := x_of(s.start), x_of(s.start + s.dur)
			if m.x < x0 - 4 || m.x > x1 + 4 do continue
			if abs(m.x - x0) <= 6 do return .Scene_Start, i
			if abs(m.x - x1) <= 6 do return .Scene_End, i
			return .Scene_Move, i
		}
	}
	if m.x > GUTTER do return .Scrub, -1
	return .None, -1
}

mouse_down :: proc(clicks: u8) {
	kind, i := hit()
	v := video()
	e.drag = {kind = kind, index = i, grab_t = t_of(e.mouse.x)}
	switch kind {
	case .None:
	case .Scrub:
		e.sel = {}
		seek(t_of(e.mouse.x))
	case .Scene_Move, .Scene_Start, .Scene_End:
		s := v.scenes[i]
		e.drag.orig = {s.start, s.dur}
		e.sel = {.Scene, i}
		if clicks >= 2 {
			e.loop, e.loop_a, e.loop_b = true, s.start, s.start + s.dur
			seek(s.start, true)
			notify(fmt.tprintf("looping %s", s.name))
		}
	case .Cue:
		e.drag.orig = {v.cues[i].t, 0}
		e.sel = {.Cue, i}
	case .Sound:
		a, d := fx.sound_span(v, &v.sounds[i])
		e.drag.orig = {a, d}
		e.sel = {.Sound, i}
	}
}

mouse_move :: proc() {
	if e.drag.kind == .None {
		kind, _ := hit()
		#partial switch kind {
		case .Scene_Start, .Scene_End, .Cue:
			_ = sdl.SetCursor(e.cursors[.Resize])
		case .Scene_Move, .Sound:
			_ = sdl.SetCursor(e.cursors[.Move])
		case:
			_ = sdl.SetCursor(e.cursors[.Default])
		}
		return
	}
	v := video()
	d := &e.drag
	t := t_of(e.mouse.x)
	dt := t - d.grab_t
	d.moved = true
	switch d.kind {
	case .None:
	case .Scrub:
		seek(t)
	case .Scene_Move:
		// Snap whichever edge is closer to something.
		s := &v.scenes[d.index]
		raw := d.orig[0] + dt
		a := snap(raw, d.index, -1)
		a_ok, a_t := d.snapped, d.snap_t
		b := snap(raw + s.dur, d.index, -1)
		b_ok, b_t := d.snapped, d.snap_t
		start := raw
		d.snapped = false
		if a_ok && (!b_ok || abs(a - raw) <= abs(b - raw - s.dur)) {
			start, d.snapped, d.snap_t = a, true, a_t
		} else if b_ok {
			start, d.snapped, d.snap_t = b - s.dur, true, b_t
		}
		s.start = max(0, start)
	case .Scene_Start:
		s := &v.scenes[d.index]
		end := d.orig[0] + d.orig[1]
		start := clamp(snap(d.orig[0] + dt, d.index, -1), 0, end - 0.05)
		s.start, s.dur = start, end - start
	case .Scene_End:
		s := &v.scenes[d.index]
		end := max(snap(d.orig[0] + d.orig[1] + dt, d.index, -1), s.start + 0.05)
		s.dur = end - s.start
	case .Cue:
		v.cues[d.index].t = max(0, snap(d.orig[0] + dt, -1, d.index))
	case .Sound:
		raw := d.orig[0] + dt
		a := snap(raw, -1, -1, d.index)
		a_ok, a_t := d.snapped, d.snap_t
		b := snap(raw + d.orig[1], -1, -1, d.index)
		b_ok, b_t := d.snapped, d.snap_t
		start := raw
		d.snapped = false
		if a_ok && (!b_ok || abs(a - raw) <= abs(b - raw - d.orig[1])) {
			start, d.snapped, d.snap_t = a, true, a_t
		} else if b_ok {
			start, d.snapped, d.snap_t = b - d.orig[1], true, b_t
		}
		v.sounds[d.index].at = start
	}
}

mouse_up :: proc() {
	d := e.drag
	e.drag = {}
	if !d.moved do return
	#partial switch d.kind {
	case .Scene_Move, .Scene_Start, .Scene_End, .Cue:
		v := video()
		v.duration = max(fx.scenes_end(v), v.duration)
		host.save_timing(&e.p)
	case .Sound:
		host.save_timing(&e.p)
		remix()
	}
}

// Pulls t to the playhead, scene edges, cues, sound starts, marks and
// voice-over words nearby (Alt disables). skip_*: the item being dragged.
snap :: proc(t: f32, skip_scene, skip_cue: int, skip_sound := -1) -> f32 {
	e.drag.snapped = false
	if sdl.GetModState() & sdl.KMOD_ALT != {} do return t
	v := video()
	best, dist := t, f32(SNAP_PX) / e.zoom
	try :: proc(t, c: f32, best, dist: ^f32) {
		if d := abs(c - t); d < dist^ {
			best^, dist^ = c, d
		}
	}
	try(t, e.t, &best, &dist)
	for s, i in v.scenes do if i != skip_scene {
		try(t, s.start, &best, &dist)
		try(t, s.start + s.dur, &best, &dist)
	}
	for c, i in v.cues do if i != skip_cue do try(t, c.t, &best, &dist)
	for s, i in v.sounds do if i != skip_sound do try(t, s.at, &best, &dist)
	for m in v.marks do try(t, m, &best, &dist)
	if v.vo_data != nil {
		for l in v.vo_data.lines do for w in l.words do try(t, w.s, &best, &dist)
	}
	if best != t {
		e.drag.snapped = true
		e.drag.snap_t = best
	}
	return best
}

wheel :: proc(w: sdl.MouseWheelEvent) {
	shift := sdl.GetModState() & sdl.KMOD_SHIFT != {}
	if shift || abs(w.x) > abs(w.y) {
		dx := shift ? w.y : w.x
		e.scroll = max(0, e.scroll - dx * 60 / e.zoom)
		return
	}
	at := t_of(e.mouse.x)
	e.zoom = clamp(e.zoom * math.pow(1.15, w.y), 2, 4000)
	e.scroll = max(0, at - (e.mouse.x - GUTTER - 12) / e.zoom)
}

// ---------------------------------------------------------------- drawing

draw :: proc() {
	pw, ph: c.int
	ww, wh: c.int
	sdl.GetWindowSizeInPixels(e.win, &pw, &ph)
	sdl.GetWindowSize(e.win, &ww, &wh)
	if pw != e.pw || ph != e.ph || e.surf == nil {
		if e.surf != nil do sk.surface_free(e.surf)
		e.pw, e.ph = pw, ph
		e.surf = sk.gpu_window_surface(e.gpu, pw, ph, 0, 8)
	}
	e.ww, e.wh = f32(ww), f32(wh)
	e.dpr = f32(pw) / max(f32(ww), 1)
	if !e.fitted && video() != nil do zoom_to_fit()

	tr := tracks()
	preview := fx.Rect{16, TOP + 8, e.ww - 32, tr.r.y - TOP - 16}

	v := video()
	shown: fx.Rect
	if v != nil {
		shown = fx.contain(preview, f32(v.width), f32(v.height))
		render_video(shown)
	}

	cv := sk.surface_canvas(e.surf)
	fx.S.cv = cv
	fx.S.w, fx.S.h = e.ww, e.wh
	sk.canvas_clear(cv, BG)
	sk.canvas_save(cv)
	sk.canvas_scale(cv, e.dpr, e.dpr)

	if v != nil && e.frame != nil {
		img := sk.surface_snapshot(e.frame)
		sk.canvas_draw_image(cv, img, nil, shown.x, shown.y, shown.w, shown.h, 1)
		sk.image_free(img)
		fx.border(fx.inset(shown, -1), LINE)
	}
	if e.error != "" do draw_error(preview)
	else if v == nil do fx.label("building…", fx.center(preview), fx.mono(14), MUTED, {0.5, 0.5})

	draw_topbar()
	draw_timeline(tr)
	sk.canvas_restore(cv)
	sk.gpu_flush(e.gpu)
	if e.shot != "" && e.shot_wait == 5 do return // keep the back buffer for the screenshot
	sdl.GL_SwapWindow(e.win)
}

render_video :: proc(shown: fx.Rect) {
	v := video()
	// Draw at the displayed size (never above the design size): scrubbing a
	// small preview stays cheap.
	k := min(shown.w * e.dpr / f32(v.width), 1)
	fw, fh := i32(f32(v.width) * k), i32(f32(v.height) * k)
	if fw < 16 || fh < 16 do return
	if fw != e.fw || fh != e.fh || e.frame == nil {
		if e.frame != nil do sk.surface_free(e.frame)
		e.frame = sk.gpu_offscreen(e.gpu, fw, fh)
		e.fw, e.fh = fw, fh
	}
	cv := sk.surface_canvas(e.frame)
	start := time.tick_now()
	sk.canvas_save(cv)
	sk.canvas_scale(cv, k, k)
	f := fx.Frame{cv = cv, t = e.t, preview = true, scale = k}
	v.render(&f)
	sk.canvas_restore(cv)
	e.render_ms = time.duration_milliseconds(time.tick_since(start))
}

current_scene :: proc() -> string {
	v := video()
	if v == nil do return ""
	name := ""
	for s in v.scenes do if e.t >= s.start && e.t < s.start + s.dur do name = s.name
	return name
}

draw_topbar :: proc() {
	fx.rect({0, 0, e.ww, TOP}, PANEL)
	fx.hline(0, TOP - 1, e.ww, LINE)
	v := video()
	x := fx.label(e.p.name, {16, TOP / 2}, fx.sans(15, 600), TEXT, {0, 0.5}).w + 16
	frame := int(math.round(e.t * f32(fps())))
	info := fmt.tprintf("%s   %.2f / %.2f s   frame %d   %.1f ms", current_scene(), e.t, video_duration(), frame, e.render_ms)
	fx.label(info, {x + 24, TOP / 2}, fx.mono(12.5), MUTED, {0, 0.5})
	if e.loop do fx.label(fmt.tprintf("loop %.2f–%.2f", e.loop_a, e.loop_b), {e.ww / 2 + 120, TOP / 2}, fx.mono(12.5), ACCENT, {0, 0.5})
	status: string
	color: fx.Color = MUTED
	if e.build.thread != nil {
		status = "compiling…"
	} else if e.error != "" {
		status, color = "build failed", ACCENT
	} else if time.tick_diff(time.tick_now(), e.note_until) > 0 {
		status = e.note
	} else if v != nil {
		status = fmt.tprintf("%dx%d · %d fps", v.width, v.height, v.fps)
	}
	fx.label(status, {e.ww - 16, TOP / 2}, fx.mono(12.5), color, {1, 0.5})
}

draw_error :: proc(r: fx.Rect) {
	fx.rect(r, 0xf0120d0c)
	fx.border(r, ACCENT)
	fx.label("build failed", {r.x + 20, r.y + 18}, fx.caps(12, 0.12, 500), ACCENT)
	y := r.y + 46
	for l in strings.split_lines(e.error, context.temp_allocator) {
		if y > r.y + r.h - 20 do break
		if strings.trim_space(l) == "" do continue
		fx.text(l, r.x + 20, y, fx.mono(12.5), TEXT)
		y += 19
	}
}

draw_timeline :: proc(tr: Tracks) {
	v := video()
	fx.rect(tr.r, PANEL)
	fx.hline(0, tr.r.y, e.ww, LINE)
	if v == nil do return
	cv := fx.canvas()
	gutter_label :: proc(s: string, r: fx.Rect) {
		fx.label(s, {14, r.y + r.h / 2}, fx.caps(10.5, 0.12), SUBTLE, {0, 0.5})
	}
	gutter_label("time", tr.ruler)
	gutter_label("scenes", tr.scenes)
	gutter_label("cues", tr.cues)
	if tr.sounds != {} do gutter_label("sounds", tr.sounds)
	if tr.vo != {} do gutter_label("voice", tr.vo)
	if tr.wave != {} do gutter_label("audio", tr.wave)

	area := fx.Rect{GUTTER, tr.r.y, e.ww - GUTTER, tr.r.h}
	sk.canvas_save(cv)
	sk.canvas_clip_rect(cv, area.x, area.y, area.w, area.h)
	dur := video_duration()
	fx.rect({x_of(0), tr.ruler.y, (dur) * e.zoom, tr.r.y + tr.r.h - tr.ruler.y - 6}, 0x08f2f0e6)
	if e.loop do fx.rect({x_of(e.loop_a), tr.ruler.y, (e.loop_b - e.loop_a) * e.zoom, tr.r.h}, 0x14dd5b3e)

	// ruler: a tick spacing that keeps labels ~90px apart
	steps := [?]f32{0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60}
	step: f32 = 60
	for s in steps do if s * e.zoom >= 90 {
		step = s
		break
	}
	t0 := math.floor(e.scroll / step) * step
	for t := t0; x_of(t) < e.ww; t += step {
		x := x_of(t)
		fx.vline(x, tr.ruler.y + 14, 12, LINE)
		fx.label(fmt.tprintf(step < 1 ? "%.2f" : "%.0f", t), {x + 4, tr.ruler.y + 4}, fx.mono(11), SUBTLE)
		for k in 1 ..< 5 {
			fx.vline(x + f32(k) * step * e.zoom / 5, tr.ruler.y + 21, 5, LINE)
		}
	}
	// marks (beats): ticks under the ruler
	for m in v.marks {
		x := x_of(m)
		if x < GUTTER || x > e.ww do continue
		fx.vline(x - 0.5, tr.ruler.y + RULER_H - 7, 7, 0x99dd5b3e)
	}

	// scenes
	lanes := make([]int, len(v.scenes), context.temp_allocator)
	scene_lanes(v, lanes)
	for s, i in v.scenes {
		x0, x1 := x_of(s.start), x_of(s.start + s.dur)
		r := fx.Rect{x0, tr.scenes.y + f32(lanes[i]) * LANE_H + 3, max(x1 - x0, 2), LANE_H - 6}
		col := s.color != 0 ? s.color : SCENE_COLORS[i % len(SCENE_COLORS)]
		sel := e.sel.kind == .Scene && e.sel.index == i
		fx.rect(r, col)
		if _, moved := moved_scene(s); moved do fx.rect({r.x, r.y + r.h - 2, r.w, 2}, ACCENT)
		if sel do fx.border(r, TEXT, 1.5)
		sk.canvas_save(cv)
		sk.canvas_clip_rect(cv, r.x, r.y, r.w, r.h)
		fx.label(s.name, {r.x + 8, r.y + r.h / 2}, fx.sans(12.5, 500), TEXT, {0, 0.5})
		sk.canvas_restore(cv)
	}

	// cues
	for cu, i in v.cues {
		x := x_of(cu.t)
		sel := e.sel.kind == .Cue && e.sel.index == i
		col: fx.Color = sel ? TEXT : ACCENT
		cy := tr.cues.y + CUE_H / 2
		path := sk.path_new()
		sk.path_move_to(path, x, cy - 6)
		sk.path_line_to(path, x + 6, cy)
		sk.path_line_to(path, x, cy + 6)
		sk.path_line_to(path, x - 6, cy)
		sk.path_close(path)
		fx.draw_path(path, fx.fill(col))
		sk.path_free(path)
		fx.label(cu.name, {x + 10, cy}, fx.mono(11), sel ? TEXT : MUTED, {0, 0.5})
	}

	// sounds
	if tr.sounds != {} {
		lanes := make([]int, len(v.sounds), context.temp_allocator)
		sound_lanes(v, lanes)
		for &so, i in v.sounds {
			a, d := fx.sound_span(v, &so)
			x0, x1 := x_of(a), x_of(a + d)
			r := fx.Rect{x0, tr.sounds.y + f32(lanes[i]) * SOUND_H + 3, max(x1 - x0, 2), SOUND_H - 6}
			sel := e.sel.kind == .Sound && e.sel.index == i
			fx.rect(r, 0xff2f4f57)
			if d0, ok := e.p.defaults.sounds[so.name]; ok && abs(d0 - so.at) > 1e-4 do fx.rect({r.x, r.y + r.h - 2, r.w, 2}, ACCENT)
			if sel do fx.border(r, TEXT, 1.5)
			sk.canvas_save(cv)
			sk.canvas_clip_rect(cv, r.x, r.y, r.w, r.h)
			fx.label(so.name, {r.x + 6, r.y + r.h / 2}, fx.sans(11.5, 500), TEXT, {0, 0.5})
			sk.canvas_restore(cv)
		}
	}

	// voice-over words
	if tr.vo != {} {
		for l in v.vo_data.lines {
			if x_of(l.end) < GUTTER || x_of(l.start) > e.ww do continue
			for w in l.words {
				x0, x1 := x_of(w.s), x_of(w.e)
				r := fx.Rect{x0, tr.vo.y + 4, max(x1 - x0 - 1, 1), VO_H - 8}
				fx.rect(r, 0x2ef2f0e6)
				if r.w > 24 {
					sk.canvas_save(cv)
					sk.canvas_clip_rect(cv, r.x, r.y, r.w, r.h)
					fx.label(w.w, {r.x + 3, r.y + r.h / 2}, fx.sans(11), TEXT, {0, 0.5})
					sk.canvas_restore(cv)
				}
			}
		}
	}

	// waveform
	if tr.wave != {} {
		mid := tr.wave.y + tr.wave.h / 2
		px_step: f32 = 2
		for x := f32(GUTTER); x < e.ww; x += px_step {
			a, b := t_of(x), t_of(x + px_step)
			if b < 0 do continue
			i0 := max(int(a * RATE / PEAK_STEP), 0)
			i1 := min(int(b * RATE / PEAK_STEP) + 1, len(e.audio.peaks))
			peak: f32
			for i in i0 ..< i1 do peak = max(peak, e.audio.peaks[i])
			h := peak * (tr.wave.h - 8)
			if h > 0.5 do fx.rect({x, mid - h / 2, px_step - 0.5, h}, 0x66f2f0e6)
		}
	}

	// snap guide and playhead
	if e.drag.kind != .None && e.drag.kind != .Scrub && e.drag.snapped {
		fx.vline(x_of(e.drag.snap_t), tr.ruler.y, tr.r.h, 0xaaf2f0e6)
	}
	px := x_of(e.t)
	fx.vline(px - 0.75, tr.ruler.y, tr.r.y + tr.r.h - tr.ruler.y, ACCENT, 1.5)
	path := sk.path_new()
	sk.path_move_to(path, px - 6, tr.ruler.y)
	sk.path_line_to(path, px + 6, tr.ruler.y)
	sk.path_line_to(path, px, tr.ruler.y + 8)
	sk.path_close(path)
	fx.draw_path(path, fx.fill(ACCENT))
	sk.path_free(path)
	sk.canvas_restore(cv)
}

// Whether a scene was moved away from its time in code.
moved_scene :: proc(s: fx.Scene) -> (host.Scene_Time, bool) {
	d, ok := e.p.defaults.scenes[s.name]
	if !ok do return {}, false
	return d, abs(d.start - s.start) > 1e-4 || abs(d.dur - s.dur) > 1e-4
}
