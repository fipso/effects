// effects: renders a video project.
//
//   effects render <project> [--out f.mp4] [--from s] [--to s] [--fps n]
//                            [--workers n] [--scale k] [--crf n] [--preset p] [--tune t]
//                            [--encoder auto|x264|nvenc]
//   effects still  <project> <t>... [--out dir] [--scale k] [--release 1]
//   effects mix    <project> [--out f.wav] [--from s] [--to s]
//   effects bench  <project> [--frames n]
//   effects build  <project>
//   effects beats  <audio file> [--band bass|full|high] [--threshold x]
//
// The project is compiled to a shared library and each worker thread draws
// its own contiguous chunk of frames on a CPU raster surface, piping raw BGRA
// into its own ffmpeg (x264, or NVENC on an NVIDIA GPU: auto picks NVENC when
// a test encode works); the segments are concatenated without re-encoding and
// muxed with the video's sounds, mixed. `beats` prints the hits and drops
// found in an audio file, to cut to.
package main

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import fx "effects:fx"
import "effects:host"
import sk "effects:sk"

USAGE :: `usage:
  effects render <project> [--out f.mp4] [--from s] [--to s] [--fps n] [--workers n] [--scale k] [--crf n] [--preset p] [--tune t] [--encoder auto|x264|nvenc]
  effects still  <project> <t>... [--out dir] [--scale k] [--release 1]
  effects mix    <project> [--out f.wav] [--from s] [--to s]
  effects bench  <project> [--frames n]
  effects build  <project>
  effects beats  <audio file> [--band bass|full|high] [--threshold x]`

Opts :: struct {
	cmd, dir: string,
	times:    [dynamic]f32,
	out:      string,
	from, to: f32,
	fps:      int,
	workers:  int,
	scale:    f32,
	crf:      int,
	preset:   string,
	tune:     string, // x264 -tune: grain keeps fine noise in dark gradients (bigger files)
	encoder:  string,
	frames:   int,
	band:     fx.Band,
	threshold: f32,
	release:  bool, // stills from the optimized build (slow to compile, fast to draw)
}

NVENC_WORKERS :: 12

main :: proc() {
	o, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if o.cmd == "beats" {
		beats(o)
		return
	}
	p, found := host.open(o.dir)
	if !found do os.exit(1)

	release := o.cmd == "render" || o.cmd == "bench" || o.cmd == "mix" || o.release
	start := time.tick_now()
	lib, built, log := host.build(&p, release)
	if !built {
		fmt.eprint(log)
		os.exit(1)
	}
	fmt.eprintfln("built %s in %.2fs (%s)", p.name, time.duration_seconds(time.tick_since(start)), release ? "-o:speed" : "-o:none")
	if o.cmd == "build" do return
	if !host.load(&p, lib) do os.exit(1)

	switch o.cmd {
	case "render":
		render(&p, o)
	case "still":
		stills(&p, o)
	case "mix":
		mix(&p, o)
	case "bench":
		bench(&p, o)
	}
}

parse_args :: proc(args: []string) -> (o: Opts, ok: bool) {
	if len(args) < 2 do return
	o.cmd, o.dir = args[0], args[1]
	switch o.cmd {
	case "render", "still", "mix", "bench", "build", "beats":
	case:
		return
	}
	o.from, o.to, o.scale, o.crf, o.preset, o.encoder, o.frames = 0, -1, 1, 18, "medium", "auto", 240
	o.band, o.threshold = .Bass, 0.35
	o.workers = default_workers()
	num :: proc(s: string) -> f32 {v, _ := strconv.parse_f32(s); return v}
	for i := 2; i < len(args); i += 1 {
		a := args[i]
		if !strings.has_prefix(a, "--") {
			append(&o.times, num(a))
			continue
		}
		if i + 1 >= len(args) do return
		v := args[i + 1]
		i += 1
		switch a {
		case "--out":
			o.out = v
		case "--from":
			o.from = num(v)
		case "--to":
			o.to = num(v)
		case "--fps":
			o.fps = int(num(v))
		case "--workers":
			o.workers = max(1, int(num(v)))
		case "--scale":
			o.scale = num(v)
		case "--crf":
			o.crf = int(num(v))
		case "--preset":
			o.preset = v
		case "--tune":
			o.tune = v
		case "--encoder":
			switch v {
			case "auto", "x264", "nvenc":
				o.encoder = v
			case:
				fmt.eprintln("unknown encoder", v)
				return
			}
		case "--frames":
			o.frames = int(num(v))
		case "--release":
			o.release = v != "0"
		case "--threshold":
			o.threshold = num(v)
		case "--band":
			switch v {
			case "bass":
				o.band = .Bass
			case "full":
				o.band = .Full
			case "high":
				o.band = .High
			case:
				fmt.eprintln("unknown band", v)
				return
			}
		case:
			fmt.eprintln("unknown option", a)
			return
		}
	}
	return o, true
}

// One worker per core, but no more than memory allows: a worker is about
// 1 GB at 1080p (its x264 encoder, up to two footage decoders, its frames).
default_workers :: proc() -> int {
	cores := os.get_processor_core_count()
	data, err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if err != nil do return cores
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if !strings.has_prefix(line, "MemAvailable:") do continue
		kb, _ := strconv.parse_int(strings.trim_space(strings.trim_suffix(strings.trim_prefix(line, "MemAvailable:"), "kB")))
		by_memory := int(f64(kb) / (1024 * 1024) * 0.7)
		return clamp(by_memory, 1, cores)
	}
	return cores
}

// Whether ffmpeg can encode on an NVIDIA GPU here (driver, device and an
// NVENC-enabled build): one tiny test encode.
nvenc_works :: proc() -> bool {
	cmd := [?]string {
		"ffmpeg", "-hide_banner", "-v", "error", "-f", "lavfi", "-i", "color=s=256x256",
		"-frames:v", "1", "-c:v", "h264_nvenc", "-f", "null", "-",
	}
	state, _, _, err := fx.exec(cmd[:], context.temp_allocator)
	return err == nil && state.success && state.exit_code == 0
}

// Video frames in a file, by counting packets (-1 if ffprobe fails).
video_frames :: proc(path: string) -> int {
	cmd := [?]string {
		"ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
		"-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path,
	}
	state, out, _, err := fx.exec(cmd[:], context.temp_allocator)
	if err != nil || !state.success || state.exit_code != 0 do return -1
	n, ok := strconv.parse_int(strings.trim_space(string(out)))
	return ok ? n : -1
}

// Output size: the video's design size times scale, rounded to even pixels.
out_size :: proc(v: ^fx.Video, scale: f32) -> (w, h: i32) {
	w = i32(math.round(f32(v.width) * scale / 2)) * 2
	h = i32(math.round(f32(v.height) * scale / 2)) * 2
	return
}

draw :: proc(v: ^fx.Video, cv: ^sk.Canvas, t: f32, scale: f32) {
	sk.canvas_save(cv)
	sk.canvas_scale(cv, scale, scale)
	f := fx.Frame{cv = cv, t = t, scale = scale}
	v.render(&f)
	sk.canvas_restore(cv)
}

// ---------------------------------------------------------------- render

Chunk :: struct {
	v:        ^fx.Video,
	from, to: int, // frame numbers relative to the render's start
	t0:       f32, // time of frame 0
	fps:      int,
	w, h:     i32,
	scale:    f32,
	seg:      string,
	crf:      int,
	preset:   string,
	tune:     string,
	encoder:  string, // x264 or nvenc
	threads:  int, // x264 threads
	done:     ^int,
	ok:       bool,
}

render_chunk :: proc(ch: ^Chunk) {
	s := sk.surface_raster(ch.w, ch.h)
	defer sk.surface_free(s)
	cv := sk.surface_canvas(s)
	// every worker runs its own encoder, so x264 workers share the cores
	// instead of each starting a thread per core (and the memory that goes
	// with it); NVENC sessions share the GPU's encoder. Both get BT.709 YUV
	// converted here: NVENC's own RGB conversion tags the stream BT.601.
	codec: string
	if ch.encoder == "nvenc" {
		// x264 preset names mean nothing to NVENC (p1 fastest .. p7 best).
		// Constant QP at the CRF's number matches x264's quality; NVENC's
		// quality-targeted VBR caps the bitrate and smears grain and footage.
		preset := len(ch.preset) == 2 && ch.preset[0] == 'p' ? ch.preset : "p5"
		codec = fmt.tprintf("-c:v h264_nvenc -preset %s -tune hq -rc constqp -qp %d -bf 3", preset, ch.crf)
	} else {
		codec = fmt.tprintf("-c:v libx264 -threads %d -preset %s -crf %d", ch.threads, ch.preset, ch.crf)
		if ch.tune != "" do codec = fmt.tprintf("%s -tune %s", codec, ch.tune)
	}
	// Primaries and transfer go on the input: since ffmpeg 7 encoders take
	// them from the frames and ignore output options (only the matrix,
	// -colorspace, is negotiated through the conversion).
	cmd := fmt.ctprintf(
		"ffmpeg -y -hide_banner -loglevel error -f rawvideo -pix_fmt bgra -s %dx%d -r %d " +
		"-color_primaries bt709 -color_trc bt709 -i - %s -pix_fmt yuv420p -colorspace bt709 '%s'",
		ch.w,
		ch.h,
		ch.fps,
		codec,
		ch.seg,
	)
	pipe := posix.popen(cmd, "w")
	if pipe == nil do return
	frame_bytes: uint
	for i in ch.from ..< ch.to {
		draw(ch.v, cv, ch.t0 + f32(i) / f32(ch.fps), ch.scale)
		rb: uint
		px := sk.surface_pixels(s, &rb)
		frame_bytes = rb * uint(ch.h)
		if libc.fwrite(px, 1, frame_bytes, pipe) != frame_bytes do break
		sync.atomic_add(ch.done, 1)
	}
	ch.ok = posix.pclose(pipe) == 0
	ch.v.release()
}

render :: proc(p: ^host.Project, o: Opts) {
	v := p.video
	fps := o.fps > 0 ? o.fps : v.fps
	t1 := o.to >= 0 ? min(o.to, v.duration) : v.duration
	t0 := clamp(o.from, 0, t1)
	total := int(math.round((t1 - t0) * f32(fps)))
	if total <= 0 {
		fmt.eprintln("nothing to render")
		os.exit(1)
	}
	w, h := out_size(v, o.scale)
	out := o.out != "" ? o.out : fx.join({p.out, fmt.tprintf("%s.mp4", p.name)})
	seg_dir := fx.join({p.out, "segments"}, context.allocator)
	os.remove_all(seg_dir)
	os.make_directory_all(seg_dir)

	workers := min(o.workers, total)
	encoder := o.encoder
	if encoder == "auto" do encoder = nvenc_works() ? "nvenc" : "x264"
	// NVENC sessions share the GPU's encoder, and more of them make the
	// failures below more likely (22 failed most 70 s renders on the render
	// box, 12 some); 12 render as fast.
	if encoder == "nvenc" do workers = min(workers, NVENC_WORKERS)
	// A dying encoder fails its chunk instead of killing the render: with a
	// handler (unlike SIG_IGN, not inherited by the ffmpegs started), writes
	// to its pipe return EPIPE.
	on_pipe := posix.sigaction_t{sa_handler = proc "c" (_: posix.Signal) {}}
	posix.sigaction(.SIGPIPE, &on_pipe, nil)
	per := (total + workers - 1) / workers
	done := 0
	chunks := make([]Chunk, workers)
	threads: [dynamic]^thread.Thread
	list := strings.builder_make()
	start := time.tick_now()
	fmt.eprintfln("rendering %d frames (%.2fs–%.2fs) at %dx%d, %d fps, %d workers, %s", total, t0, t1, w, h, fps, workers, encoder)
	for i in 0 ..< workers {
		a, b := i * per, min(total, (i + 1) * per)
		if a >= b do break
		seg := fx.join({seg_dir, fmt.tprintf("seg%03d.mp4", i)}, context.allocator)
		enc_threads := max(2, os.get_processor_core_count() / workers)
		chunks[i] = {v, a, b, t0, fps, w, h, o.scale, seg, o.crf, o.preset, o.tune, encoder, enc_threads, &done, false}
		fmt.sbprintfln(&list, "file '%s'", seg)
		append(&threads, thread.create_and_start_with_poly_data(&chunks[i], render_chunk))
	}
	for {
		all := true
		for th in threads do if !thread.is_done(th) do all = false
		n := sync.atomic_load(&done)
		el := time.duration_seconds(time.tick_since(start))
		rate := f64(n) / max(el, 1e-3)
		fmt.eprintf("\r%d/%d frames · %.1f fps · eta %.0fs   ", n, total, rate, f64(total - n) / max(rate, 0.01))
		if all do break
		time.sleep(500 * time.Millisecond)
	}
	thread.join_multiple(..threads[:])
	started := chunks[:len(threads)]
	// The render box's NVENC (Debian's ffmpeg 7.1, driver 595.112) now and
	// then crashes mid-stream (a segfault copying a frame) or rejects a frame
	// (EINVAL) on long, grainy renders. Those chunks are drawn again and
	// encoded with x264.
	failed: [dynamic]^Chunk
	for &ch in started do if !ch.ok && ch.encoder == "nvenc" do append(&failed, &ch)
	if len(failed) > 0 {
		fmt.eprintfln("\nNVENC failed on %d of %d chunks: encoding them again with x264", len(failed), len(started))
		retry: [dynamic]^thread.Thread
		for ch in failed {
			ch.encoder = "x264"
			ch.threads = max(2, os.get_processor_core_count() / len(failed))
			append(&retry, thread.create_and_start_with_poly_data(ch, render_chunk))
		}
		thread.join_multiple(..retry[:])
	}
	secs := time.duration_seconds(time.tick_since(start))
	fmt.eprintfln("\nrendered %d frames in %.1fs (%.1f fps)", total, secs, f64(total) / secs)
	for ch in started do if !ch.ok {
		fmt.eprintln("ffmpeg failed for", ch.seg)
		os.exit(1)
	}

	list_path := fx.join({seg_dir, "list.txt"})
	_ = os.write_entire_file(list_path, strings.to_string(list))
	audio := fx.join({seg_dir, "mix.wav"})
	has_audio := len(v.sounds) > 0
	if has_audio {
		samples := fx.mixdown(v, t0, t1)
		has_audio = fx.write_wav(audio, samples)
		delete(samples)
	}
	cmd := strings.builder_make()
	fmt.sbprintf(&cmd, "ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i '%s'", list_path)
	// The mix is exactly as long as the video, so no -shortest: it once cut
	// the last video frame (or two) on the render box, at random.
	if has_audio do fmt.sbprintf(&cmd, " -i '%s' -map 0:v -map 1:a -c:a aac -b:a 256k", audio)
	fmt.sbprintf(&cmd, " -c:v copy -movflags +faststart '%s'", out)
	if libc.system(strings.to_cstring(&cmd)) != 0 {
		fmt.eprintln("muxing failed")
		os.exit(1)
	}
	if n := video_frames(out); n != total {
		fmt.eprintfln("warning: %s has %d video frames, %d were rendered", out, n, total)
	}
	os.remove_all(seg_dir)
	fmt.println(out)
}

// ---------------------------------------------------------------- audio

mix :: proc(p: ^host.Project, o: Opts) {
	v := p.video
	t1 := o.to >= 0 ? min(o.to, v.duration) : v.duration
	t0 := clamp(o.from, 0, t1)
	out := o.out != "" ? o.out : fx.join({p.out, fmt.tprintf("%s.wav", p.name)})
	start := time.tick_now()
	samples := fx.mixdown(v, t0, t1)
	defer delete(samples)
	if !fx.write_wav(out, samples) {
		fmt.eprintln("cannot write", out)
		os.exit(1)
	}
	peak: f32
	for x in samples do peak = max(peak, abs(x[0]), abs(x[1]))
	fmt.eprintfln("mixed %d sounds, %.2fs–%.2fs, in %.2fs (peak %.1f dB)", len(v.sounds), t0, t1, time.duration_seconds(time.tick_since(start)), 20 * math.log10(max(peak, 1e-9)))
	fmt.println(out)
}

beats :: proc(o: Opts) {
	if !os.exists(o.dir) {
		fmt.eprintln("no such file:", o.dir)
		os.exit(1)
	}
	hits := fx.onsets(o.dir, o.band, o.threshold)
	fmt.printfln("%d hits (%v, threshold %.2f): time  strength  level", len(hits), o.band, o.threshold)
	for h in hits do fmt.printfln("  %7.3f  %5.2f  %4.2f", h.t, h.strength, h.level)
	// the most common gap between neighbouring hits, as a tempo guess
	counts: map[int]int
	defer delete(counts)
	for i in 1 ..< len(hits) {
		gap := int(math.round((hits[i].t - hits[i - 1].t) * 100))
		if gap >= 30 && gap <= 100 do counts[gap] += 1
	}
	best, n := 0, 0
	for gap, c in counts do if c > n do best, n = gap, c
	if n > 0 do fmt.printfln("most common gap %.2fs (%.1f bpm)", f32(best) / 100, 6000 / f32(best))
	for d in fx.drops(o.dir, o.band) do fmt.printfln("drop at %.3f (energy ×%.1f)", d.t, d.strength)
}

// ---------------------------------------------------------------- stills & bench

stills :: proc(p: ^host.Project, o: Opts) {
	v := p.video
	w, h := out_size(v, o.scale)
	dir := o.out != "" ? o.out : fx.join({p.out, "stills"})
	os.make_directory_all(dir)
	s := sk.surface_raster(w, h)
	defer sk.surface_free(s)
	times := o.times[:]
	if len(times) == 0 do times = {0}
	for t in times {
		draw(v, sk.surface_canvas(s), t, o.scale)
		path := fx.join({dir, fmt.tprintf("%07.2f.png", t)})
		if !sk.surface_write_png(s, strings.clone_to_cstring(path, context.temp_allocator)) {
			fmt.eprintln("cannot write", path)
			os.exit(1)
		}
		fmt.println(path)
	}
}

bench :: proc(p: ^host.Project, o: Opts) {
	v := p.video
	w, h := out_size(v, 1)
	s := sk.surface_raster(w, h)
	defer sk.surface_free(s)
	cv := sk.surface_canvas(s)
	n := o.frames
	for i in 0 ..< 10 do draw(v, cv, f32(i) / f32(v.fps), 1)
	start := time.tick_now()
	worst: f64
	for i in 0 ..< n {
		t := f32(i) / f32(n) * v.duration
		a := time.tick_now()
		draw(v, cv, t, 1)
		worst = max(worst, time.duration_milliseconds(time.tick_since(a)))
	}
	ms := time.duration_milliseconds(time.tick_since(start)) / f64(n)
	fmt.printfln("%d frames across %.1fs · %.2f ms/frame average, %.2f ms worst (one thread, %dx%d)", n, v.duration, ms, worst, w, h)
}
