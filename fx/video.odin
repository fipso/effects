// A video is a list of scenes on a timeline plus named cues; the renderers
// (effects CLI, effects-edit) load a project's video from its shared library:
//
//   @(export)
//   effects_video :: proc() -> ^fx.Video {
//       return fx.video({name = "Spot", scenes = SCENES[:], cues = CUES[:], sounds = SOUNDS[:]})
//   }
package fx

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import sk "../sk"

// Set by the renderer when it builds a project.
PROJECT_DIR :: #config(EFFECTS_PROJECT, "")
EFFECTS_ROOT :: #config(EFFECTS_ROOT, "")

Video :: struct {
	name:       string,
	width:      int, // design size, default 1920×1080
	height:     int,
	fps:        int, // default 60
	duration:   f32, // 0 = until the last scene (or the voice-over) ends
	audio:      string, // soundtrack from 0, relative to the project: short for one Sound
	sounds:     []Sound, // see audio.odin
	vo:         string, // timeline.json with voice-over word timings
	background: Color,
	scenes:     []Scene,
	cues:       []Cue,
	marks:      []f32, // times the editor shows on its ruler and snaps to (beats)
	overlay:    proc(t: f32), // drawn above all scenes
	master:     proc(t: f32) -> Xf, // a group around all scenes: the film's grade, glow, lens, camera

	// Filled in by fx.video for the renderer.
	render:     proc(f: ^Frame),
	release:    proc(), // frees what the calling thread decoded (footage)
	vo_data:    ^Vo,
	dir:        string,
}

Scene :: struct {
	name:  string,
	start: f32,
	dur:   f32,
	vo:    string, // take start and length from this voice-over scene
	draw:  proc(s: Shot),
	color: Color, // in the editor's timeline
	data:  rawptr, // handed to draw as Shot.data
}

// What a scene draws: t is video time, lt is time since the scene started,
// p is lt as a fraction of the scene.
Shot :: struct {
	t, lt, p:   f32,
	start, dur: f32,
	data:       rawptr,
}

Cue :: struct {
	name: string,
	t:    f32,
}

Frame :: struct {
	cv:      ^sk.Canvas,
	t:       f32,
	preview: bool,
	scale:   f32, // how much the renderer scaled the canvas, 0 = 1
}

@(private = "file")
loaded: Video

// Registers the video with the renderer. Copies everything it is given.
video :: proc(v: Video) -> ^Video {
	loaded = v
	loaded.scenes = slice.clone(v.scenes)
	loaded.cues = slice.clone(v.cues)
	loaded.marks = slice.clone(v.marks)
	sounds: [dynamic]Sound
	if v.audio != "" do append(&sounds, Sound{name = "audio", file = v.audio})
	append(&sounds, ..v.sounds)
	// the renderers mix from their own copy of fx, which has no project directory
	for &s in sounds do if s.file != "" do s.file = strings.clone(resolve(s.file))
	loaded.sounds = sounds[:]
	if loaded.width == 0 do loaded.width, loaded.height = 1920, 1080
	if loaded.fps == 0 do loaded.fps = 60
	if loaded.background == 0 do loaded.background = 0xff000000
	loaded.dir = PROJECT_DIR
	default_fonts()
	if v.vo != "" {
		if data, ok := load_vo(resolve(v.vo)); ok {
			vo = data
			loaded.vo_data = &vo
		}
	}
	for &s in loaded.scenes {
		if s.vo == "" || loaded.vo_data == nil do continue
		sc := SC(s.vo)
		s.start = sc.start
		if s.dur == 0 do s.dur = sc.end - sc.start
	}
	if loaded.duration == 0 do loaded.duration = video_end(&loaded)
	loaded.render = render_frame
	loaded.release = release_media
	return &loaded
}

// Where the last scene (or the voice-over) ends.
video_end :: proc(v: ^Video) -> f32 {
	end := scenes_end(v)
	if v.vo_data != nil do end = max(end, v.vo_data.duration)
	return end
}

scenes_end :: proc(v: ^Video) -> f32 {
	end: f32
	for s in v.scenes do end = max(end, s.start + s.dur)
	return end
}

// A cue's time; cues can be moved in the editor without touching code.
cue :: proc(name: string) -> f32 {
	for c in loaded.cues do if c.name == name do return c.t
	fmt.eprintln("fx: no cue", name)
	return 0
}

// Visibility of a scene: fades in over fi after it starts, out over fo before it ends.
fade :: proc(s: Shot, fi: f32 = 0.4, fo: f32 = 0.4) -> f32 {
	return win(s.t, s.start, s.start + s.dur, fi, fo)
}

// Per-frame scratch memory, so drawing never frees the caller's temp allocator.
@(private = "file", thread_local)
frame_arena: virtual.Arena

render_frame :: proc(f: ^Frame) {
	context.temp_allocator = virtual.arena_allocator(&frame_arena)
	defer virtual.arena_free_all(&frame_arena)
	v := &loaded
	S.cv, S.t, S.preview, S.video = f.cv, f.t, f.preview, v
	S.scale = f.scale > 0 ? f.scale : 1
	S.w, S.h = f32(v.width), f32(v.height)
	clear(&S.groups)
	layout_reset()
	sk.canvas_clear(f.cv, v.background)
	mastered := v.master != nil
	shown := true
	if mastered {
		// the background is part of the master group, so its glow and filters see it
		xf := v.master(f.t)
		if xf.bounds == nil do xf.bounds = stage()
		shown = group_begin(xf)
		if shown do rect(stage(), v.background)
	}
	if shown do for &s in v.scenes {
		if s.draw == nil || f.t < s.start || f.t >= s.start + s.dur do continue
		lt := f.t - s.start
		s.draw({t = f.t, lt = lt, p = s.dur > 0 ? lt / s.dur : 0, start = s.start, dur = s.dur, data = s.data})
	}
	if mastered do end_group(shown)
	if v.overlay != nil do v.overlay(f.t)
	sk.frame_end()
}

// The fonts every theme here uses: Space Grotesk (variable) as "SG",
// JetBrains Mono 400/500 as "JBM".
default_fonts :: proc() {
	dir := join({EFFECTS_ROOT, "assets/fonts"})
	at :: proc(dir, name: string) -> string {return join({dir, name})}
	font("SG", at(dir, "space-grotesk-latin-wght-normal.woff2"))
	font("JBM", at(dir, "jetbrains-mono-latin-400-normal.woff2"))
	font("JBM", at(dir, "jetbrains-mono-latin-500-normal.woff2"))
}
