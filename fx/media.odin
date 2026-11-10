// Footage: frames of video files, drawn like images.
//
//   fx.footage("assets/karp.mp4", 12.5 + s.lt, fx.stage())
//
// Each thread decodes through its own ffmpeg pipe per file, which keeps
// playing forward: drawing consecutive frames costs one decode each, and
// jumping back (or far ahead) restarts the pipe at the new spot. Footage cut
// to short GOPs (ffmpeg -g 12) restarts fastest. A thread keeps at most
// MAX_PIPES pipes open (each is an ffmpeg process holding a few frames), so
// a render with many workers and many clips stays within memory.
package fx

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import sk "../sk"

Media :: struct {
	w, h:     int,
	fps:      f32,
	rate:     string, // the frame rate as ffprobe gives it (30000/1001)
	duration: f32,
	frames:   int,
}

// os.process_exec with a correct copy of the environment. core:os (odin
// dev-2026-05, linked against libc) hands children its first variable twice;
// when that is PATH (a shell puts it first after `PATH=... effects`), nix's
// odin wrapper adds clang to one copy while sh reads the other.
exec :: proc(cmd: []string, allocator := context.allocator) -> (os.Process_State, []byte, []byte, os.Error) {
	env := make([dynamic]string, context.temp_allocator)
	for i := 0; posix.environ[i] != nil; i += 1 do append(&env, string(posix.environ[i]))
	return os.process_exec({command = cmd, env = env[:]}, allocator)
}

@(private = "file")
probed: struct {
	lock: sync.Mutex,
	m:    map[string]Media,
}

// Size, frame rate and length of a video file (ffprobe, once per process).
media :: proc(path: string) -> (Media, bool) {
	full := resolve(path)
	sync.guard(&probed.lock)
	if m, ok := probed.m[full]; ok do return m, m.frames > 0
	cmd := [?]string {
		"ffprobe", "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=width,height,r_frame_rate:format=duration",
		"-of", "default=nw=1", full,
	}
	m: Media
	state, out, _, err := exec(cmd[:], context.temp_allocator)
	if err == nil && state.success {
		for line in strings.split_lines(string(out), context.temp_allocator) {
			k, _, v := strings.partition(line, "=")
			switch k {
			case "width":
				m.w, _ = strconv.parse_int(v)
			case "height":
				m.h, _ = strconv.parse_int(v)
			case "duration":
				m.duration, _ = strconv.parse_f32(v)
			case "r_frame_rate":
				m.rate = strings.clone(v)
				num, _, den := strings.partition(v, "/")
				a, _ := strconv.parse_f32(num)
				b, ok := strconv.parse_f32(den)
				m.fps = ok && b > 0 ? a / b : a
			}
		}
	}
	if m.fps > 0 do m.frames = int(m.duration * m.fps)
	if m.frames <= 0 do fmt.eprintln("fx: cannot read video", full)
	probed.m[strings.clone(full)] = m
	return m, m.frames > 0
}

@(private = "file")
Decoder :: struct {
	path:   string,
	m:      Media,
	w, h:   int, // decoded size
	pipe:   ^libc.FILE,
	next:   int, // the frame the pipe delivers next
	cur:    int, // the frame in img
	end:    int, // first frame the file turned out not to have
	img:    ^sk.Image,
	buf:    []u8,
	used:   u64, // when this thread last drew from it
}

@(private = "file", thread_local)
decoders: map[string]^Decoder
@(private = "file", thread_local)
clock: u64

MAX_DECODE_W :: 1920
MAX_PIPES :: 2

// The frame of a video file at src seconds into it, held at its ends; nil
// if it cannot be read. Valid until the next call for the same file on this
// thread.
frame :: proc(path: string, src: f32) -> ^sk.Image {
	d := decoders[path]
	if d == nil {
		m, ok := media(path)
		if !ok do return nil
		d = new(Decoder)
		d.path = strings.clone(path)
		d.m = m
		k := min(f32(MAX_DECODE_W) / f32(m.w), 1)
		d.w, d.h = int(f32(m.w) * k) &~ 1, int(f32(m.h) * k) &~ 1
		d.cur, d.end = -1, m.frames
		d.buf = make([]u8, d.w * d.h * 4)
		decoders[d.path] = d
	}
	clock += 1
	d.used = clock
	n := clamp(int(math.floor(src * d.m.fps + 0.001)), 0, max(d.end - 1, 0))
	if n == d.cur && d.img != nil do return d.img
	if d.pipe == nil || n < d.next || n - d.next > int(d.m.fps * 2) do restart(d, n)
	got := -1
	for d.pipe != nil && d.next <= n {
		if libc.fread(raw_data(d.buf), 1, len(d.buf), d.pipe) != len(d.buf) {
			// the file is shorter than it said
			posix.pclose(d.pipe)
			d.pipe = nil
			d.end = max(d.next, 1)
			break
		}
		got = d.next
		d.next += 1
	}
	if got >= 0 {
		if d.img != nil do sk.image_free(d.img)
		d.img = sk.image_from_pixels(raw_data(d.buf), i32(d.w), i32(d.h), uint(d.w * 4))
		d.cur = got
	}
	return d.img
}

@(private = "file")
restart :: proc(d: ^Decoder, n: int) {
	if d.pipe != nil do posix.pclose(d.pipe)
	d.pipe = nil
	// make room: close the pipe this thread used least recently
	for {
		open := 0
		oldest: ^Decoder
		for _, o in decoders do if o.pipe != nil {
			open += 1
			if oldest == nil || o.used < oldest.used do oldest = o
		}
		if open < MAX_PIPES do break
		posix.pclose(oldest.pipe)
		oldest.pipe = nil
	}
	cmd := fmt.ctprintf(
		"ffmpeg -v fatal -nostdin -threads 2 -ss %.6f -i %s -an -sn -filter_threads 1 -vf 'fps=%s:start_time=0,scale=%d:%d:flags=bicubic' -pix_fmt bgra -f rawvideo -",
		(f64(n) - 0.25) / f64(d.m.fps), // a little early: frame n is the first at or after it
		shell_quote(resolve(d.path)),
		d.m.rate,
		d.w,
		d.h,
	)
	d.pipe = posix.popen(cmd, "r")
	d.next = n
}

shell_quote :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", r, "'"}, context.temp_allocator)
}

// Closes this thread's footage decoders (the renderers call it through
// Video.release when a thread is done or the code is reloaded).
release_media :: proc() {
	for _, d in decoders {
		if d.pipe != nil do posix.pclose(d.pipe)
		if d.img != nil do sk.image_free(d.img)
		delete(d.buf)
		delete(d.path)
		free(d)
	}
	clear(&decoders)
}

// Draws the frame of a video file at src seconds into r; focus picks which
// part stays in view when Cover crops (0..1 on each axis), zoom crops further in.
footage :: proc(path: string, src: f32, r: Rect, fit := Image_Fit.Cover, alpha: f32 = 1, focus := Vec2{0.5, 0.5}, zoom: f32 = 1) {
	image(frame(path, src), r, alpha, fit, focus, zoom)
}
