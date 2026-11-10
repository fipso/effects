// Shared by the CLI and the editor: compiling a project to a shared library,
// loading its video, and the timing overrides the editor writes.
package host

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import fx "../fx"

EFFECTS_ROOT :: #config(EFFECTS_ROOT, "")
EFFECTS_LINK :: #config(EFFECTS_LINK, "")

Project :: struct {
	dir:        string, // absolute project directory
	name:       string,
	out:        string, // <dir>/.effects
	video:      ^fx.Video,
	generation: int, // bumped on every load
	defaults:   Timing, // scene/cue/sound times as the code defines them
}

Scene_Time :: struct {
	start, dur: f32,
}

// timing.json: only what was moved in the editor.
Timing :: struct {
	scenes: map[string]Scene_Time,
	cues:   map[string]f32,
	sounds: map[string]f32, // where each sound starts
}

open :: proc(dir: string) -> (p: Project, ok: bool) {
	abs, err := os.get_absolute_path(dir, context.allocator)
	if err != nil || !os.is_dir(abs) {
		fmt.eprintln("not a project directory:", dir)
		return
	}
	p.dir = abs
	p.name = filepath.base(abs)
	p.out = fx.join({abs, ".effects"}, context.allocator)
	os.make_directory_all(p.out)
	return p, true
}

// Compiles the project into a shared library; returns the compiler output on failure.
build :: proc(p: ^Project, optimize: bool) -> (lib: string, ok: bool, log: string) {
	lib = fx.join({p.out, optimize ? "video-release.so" : "video-dev.so"}, context.allocator)
	cmd := [?]string {
		"odin",
		"build",
		p.dir,
		"-build-mode:shared",
		fmt.tprintf("-out:%s", lib),
		optimize ? "-o:speed" : "-o:none",
		fmt.tprintf("-collection:effects=%s", EFFECTS_ROOT),
		fmt.tprintf("-define:EFFECTS_PROJECT=%s", p.dir),
		fmt.tprintf("-define:EFFECTS_ROOT=%s", EFFECTS_ROOT),
		fmt.tprintf("-extra-linker-flags:%s", EFFECTS_LINK),
	}
	state, stdout, stderr, err := fx.exec(cmd[:], context.temp_allocator)
	if err != nil do return lib, false, fmt.tprint("cannot run odin:", err)
	if !state.success || state.exit_code != 0 {
		return lib, false, strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator)
	}
	return lib, true, ""
}

// Loads a built library. Each load gets its own copy of the file so the
// dynamic loader never hands back an older one; old libraries stay mapped
// (their code may still be referenced by threads finishing a frame). Call
// on the thread that renders: the old video's decoders are released there.
load :: proc(p: ^Project, lib: string) -> bool {
	if p.video != nil && p.video.release != nil do p.video.release()
	p.generation += 1
	copy_path := fx.join({p.out, fmt.tprintf("video-%d.so", p.generation)})
	if err := os.copy_file(copy_path, lib); err != nil {
		fmt.eprintln("cannot copy", lib, err)
		return false
	}
	handle, ok := dynlib.load_library(copy_path)
	if !ok {
		fmt.eprintln("cannot load", copy_path, dynlib.last_error())
		return false
	}
	os.remove(copy_path) // stays mapped
	sym, found := dynlib.symbol_address(handle, "effects_video")
	if !found {
		fmt.eprintln("project has no `@(export) effects_video :: proc() -> ^fx.Video`")
		return false
	}
	entry := cast(proc() -> ^fx.Video)sym
	v := entry()
	if v == nil do return false
	p.video = v
	p.defaults = snapshot(v)
	apply_timing(p)
	return true
}

@(private)
snapshot :: proc(v: ^fx.Video) -> (t: Timing) {
	for s in v.scenes do t.scenes[s.name] = {s.start, s.dur}
	for c in v.cues do t.cues[c.name] = c.t
	for s in v.sounds do t.sounds[s.name] = s.at
	return
}

timing_path :: proc(p: ^Project) -> string {return fx.join({p.dir, "timing.json"})}

// Applies timing.json on top of the code's times.
apply_timing :: proc(p: ^Project) {
	data, err := os.read_entire_file(timing_path(p), context.temp_allocator)
	if err != nil do return
	t: Timing
	if e := json.unmarshal(data, &t, allocator = context.temp_allocator); e != nil {
		fmt.eprintln("bad timing.json:", e)
		return
	}
	v := p.video
	for &s in v.scenes do if o, ok := t.scenes[s.name]; ok do s.start, s.dur = o.start, o.dur
	for &c in v.cues do if o, ok := t.cues[c.name]; ok do c.t = o
	for &s in v.sounds do if o, ok := t.sounds[s.name]; ok do s.at = o
	v.duration = max(v.duration, fx.scenes_end(v))
}

// Writes the scenes, cues and sounds that differ from the code to timing.json.
save_timing :: proc(p: ^Project) {
	t: Timing
	t.scenes = make(map[string]Scene_Time, allocator = context.temp_allocator)
	t.cues = make(map[string]f32, allocator = context.temp_allocator)
	t.sounds = make(map[string]f32, allocator = context.temp_allocator)
	for s in p.video.scenes {
		d, ok := p.defaults.scenes[s.name]
		if !ok || abs(d.start - s.start) > 1e-4 || abs(d.dur - s.dur) > 1e-4 do t.scenes[s.name] = {s.start, s.dur}
	}
	for c in p.video.cues {
		d, ok := p.defaults.cues[c.name]
		if !ok || abs(d - c.t) > 1e-4 do t.cues[c.name] = c.t
	}
	for s in p.video.sounds {
		d, ok := p.defaults.sounds[s.name]
		if !ok || abs(d - s.at) > 1e-4 do t.sounds[s.name] = s.at
	}
	if len(t.scenes) == 0 && len(t.cues) == 0 && len(t.sounds) == 0 {
		os.remove(timing_path(p))
		return
	}
	data, err := json.marshal(t, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil do return
	_ = os.write_entire_file(timing_path(p), data)
}

// Absolute path of a file the video refers to (audio, voice-over).
resolve :: proc(p: ^Project, path: string) -> string {
	if path == "" || filepath.is_abs(path) do return path
	return fx.join({p.dir, path})
}
