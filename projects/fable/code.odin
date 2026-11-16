// Source code drawn with syntax colors: one text run per token, on the
// mono font's grid.
package fable

import "core:strings"
import fx "effects:fx"

KEYWORDS := [?]string{"proc", "for", "in", "return", "if", "else", "do", "package", "import", "defer", "switch", "case", "when", "struct", "enum", "continue", "break", "or_else", "assert"}

@(private = "file")
ident_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// Draws one line of Odin at (x, y), at most max_chars of it; tabs are two
// columns. Returns the columns drawn.
code_line :: proc(line: string, x, y: f32, f: fx.Font, a: f32 = 1, max_chars: int = 400) -> int {
	adv := fx.measure("0", f).x
	col := 0
	i := 0
	n := len(line)
	run :: proc(s: string, col: int, x, y, adv: f32, f: fx.Font, c: fx.Color, max_chars: int) {
		if col >= max_chars || s == "" do return
		s := s
		if col + len(s) > max_chars do s = s[:max(max_chars - col, 0)]
		fx.text(s, x + f32(col) * adv, y, f, c)
	}
	for i < n {
		c := line[i]
		switch {
		case c == '\t':
			col += 2
			i += 1
		case c == ' ':
			col += 1
			i += 1
		case c == '/' && i + 1 < n && line[i + 1] == '/':
			run(line[i:], col, x, y, adv, f, fx.alpha(BONE, 0.36 * a), max_chars)
			col += n - i
			i = n
		case c == '"' || c == '`':
			j := i + 1
			for j < n && line[j] != c do j += 1
			j = min(j + 1, n)
			run(line[i:j], col, x, y, adv, f, fx.alpha(GOLD, a), max_chars)
			col += j - i
			i = j
		case c >= '0' && c <= '9':
			j := i
			for j < n && (ident_char(line[j]) || line[j] == '.') do j += 1
			// 0 ..< n: the dots belong to the operator
			if k := strings.index(line[i:j], ".."); k >= 0 do j = i + k
			run(line[i:j], col, x, y, adv, f, fx.alpha(EMBER, a), max_chars)
			col += j - i
			i = j
		case ident_char(c):
			j := i
			for j < n && ident_char(line[j]) do j += 1
			word := line[i:j]
			color := fx.alpha(BONE, 0.92 * a)
			for k in KEYWORDS do if k == word do color = fx.alpha(CLAY, a)
			if j < n && line[j] == '(' && color == fx.alpha(BONE, 0.92 * a) do color = fx.alpha(TEAL, a)
			if j < n && line[j] == '.' do color = fx.alpha(VIOLET, a)
			run(word, col, x, y, adv, f, color, max_chars)
			col += j - i
			i = j
		case:
			j := i
			for j < n && !ident_char(line[j]) && line[j] != ' ' && line[j] != '\t' && line[j] != '"' && line[j] != '`' && !(line[j] == '/' && j + 1 < n && line[j + 1] == '/') do j += 1
			if j == i do j = i + 1
			run(line[i:j], col, x, y, adv, f, fx.alpha(BONE, 0.5 * a), max_chars)
			col += j - i
			i = j
		}
	}
	return min(col, max_chars)
}

// A check mark in a circle.
check :: proc(p: fx.Vec2, r: f32, c: fx.Color, k: f32 = 1) {
	fx.ring(p, r, c, 2)
	a := p + {-r * 0.45, 0.02 * r}
	b := p + {-r * 0.1, r * 0.36}
	d := p + {r * 0.48, -r * 0.34}
	fx.line(a, fx.lerp2(a, b, fx.clamp01(k * 2)), c, 2.4)
	if k > 0.5 do fx.line(b, fx.lerp2(b, d, fx.clamp01(k * 2 - 1)), c, 2.4)
}
