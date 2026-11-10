// Numbers the way German UI copy writes them.
package fx

import "core:fmt"
import "core:math"
import "core:strings"

// 1234567 → "1.234.567", plus suffix.
fmt_int :: proc(n: int, suffix := "") -> string {
	digits := fmt.tprint(abs(n))
	b := strings.builder_make(context.temp_allocator)
	if n < 0 do strings.write_byte(&b, '-')
	for i in 0 ..< len(digits) {
		if i > 0 && (len(digits) - i) % 3 == 0 do strings.write_byte(&b, '.')
		strings.write_byte(&b, digits[i])
	}
	strings.write_string(&b, suffix)
	return strings.to_string(b)
}

// 24000 → "24.000 €"
eur :: proc(v: f32) -> string {return fmt_int(int(math.round(v)), " €")}
