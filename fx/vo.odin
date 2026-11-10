// Voice-over timings: the timeline.json the v3 pipeline's tools/vo.mjs writes,
// with every line's words and where each scene starts.
package fx

import "core:encoding/json"
import "core:fmt"
import "core:os"

Vo_Word :: struct {
	w:    string,
	s, e: f32,
}

Vo_Line :: struct {
	id, scene, text: string,
	start, end:      f32,
	words:           []Vo_Word,
}

Vo_Scene :: struct {
	id:         string,
	start, end: f32,
}

Vo :: struct {
	lines:    []Vo_Line,
	scenes:   []Vo_Scene,
	duration: f32,
}

// The voice-over of the loaded video, if it has one.
vo: Vo

load_vo :: proc(path: string, allocator := context.allocator) -> (v: Vo, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		fmt.eprintln("fx: cannot read", path, err)
		return
	}
	if e := json.unmarshal(data, &v, allocator = allocator); e != nil {
		fmt.eprintln("fx: bad timeline", path, e)
		return
	}
	return v, true
}

vo_line :: proc(id: string) -> ^Vo_Line {
	for &l in vo.lines do if l.id == id do return &l
	fmt.eprintln("fx: no voice-over line", id)
	return nil
}

@(private = "file")
word_at :: proc(id: string, i: int) -> ^Vo_Word {
	l := vo_line(id)
	if l == nil || len(l.words) == 0 do return nil
	j := i < 0 ? len(l.words) + i : i
	return &l.words[clamp(j, 0, len(l.words) - 1)]
}

// Start of word i of line id (negative i counts from the end).
W :: proc(id: string, i: int = 0) -> f32 {
	w := word_at(id, i)
	return w == nil ? 0 : w.s
}
// End of word i of line id.
WE :: proc(id: string, i: int = -1) -> f32 {
	w := word_at(id, i)
	return w == nil ? 0 : w.e
}
// A voice-over scene's span.
SC :: proc(id: string) -> Vo_Scene {
	for s in vo.scenes do if s.id == id do return s
	fmt.eprintln("fx: no voice-over scene", id)
	return {}
}
