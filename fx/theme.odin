// The product's visual language: paper surfaces, hairline borders, mono
// labels, the red bracket. Projects can replace `theme` wholesale.
package fx

Theme :: struct {
	// night (dark) surfaces and text
	night, night2: Color,
	nt, nm, ns:    Color, // text, muted, subtle
	nb:            Color, // hairline
	na:            Color, // accent on night
	// paper (light) surfaces and text
	bg, sf, sf2, sf3: Color,
	bd, bds:          Color, // hairline, stronger hairline
	ink, mut, sub:    Color,
	red, red_soft:    Color,
	ok, ok_soft:      Color,
	warn, warn_soft:  Color,
	sans, mono:       cstring,
}

LIERMANN :: Theme {
	night     = 0xff111110,
	night2    = 0xff1a1a15,
	nt        = 0xfff2f0e6,
	nm        = 0xb8f2f0e6,
	ns        = 0x7af2f0e6,
	nb        = 0x24f2f0e6,
	na        = 0xffdd5b3e,
	bg        = 0xfff3f2ec,
	sf        = 0xfffbfaf7,
	sf2       = 0xffedebe3,
	sf3       = 0xffe4e2d8,
	bd        = 0x2116160f,
	bds       = 0x3d16160f,
	ink       = 0xff16160f,
	mut       = 0xbd16160f,
	sub       = 0x8f16160f,
	red       = 0xffb4321f,
	red_soft  = 0x14b4321f,
	ok        = 0xff2f6b47,
	ok_soft   = 0x1a2f6b47,
	warn      = 0xff8a6410,
	warn_soft = 0x1a8a6410,
	sans      = "SG",
	mono      = "JBM",
}

theme := LIERMANN

sans :: proc(size: f32, weight: f32 = 400, tracking: f32 = 0) -> Font {
	return {family = theme.sans, size = size, weight = weight, tracking = tracking}
}
mono :: proc(size: f32, weight: f32 = 400, tracking: f32 = 0) -> Font {
	return {family = theme.mono, size = size, weight = weight, tracking = tracking}
}
// Mono label in capitals, the eyebrow/section style.
caps :: proc(size: f32, tracking: f32 = 0.1, weight: f32 = 400) -> Font {
	return {family = theme.mono, size = size, weight = weight, tracking = tracking, upper = true}
}
