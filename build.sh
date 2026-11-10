#!/usr/bin/env bash
# Builds the Skia shim (build/libskshim.so), the CLI (build/effects) and the
# editor (build/effects-edit). Skia comes from nix/skia.nix unless SKIA (the
# built library) and SKIA_SRC (its source tree, for headers) point elsewhere.
#   ./build.sh [shim|cli|edit]...   default: all
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
nixpath() { nix build "$@" --no-link --print-out-paths; }
SKIA=${SKIA:-$(nixpath --impure --expr "(import ./nix/skia.nix {})")}
# The installed headers miss src/ internals that skparagraph's public headers
# include, so compile against the source tree the library was built from.
SKIA_SRC=${SKIA_SRC:-$(nixpath --impure --expr "(import ./nix/skia.nix {}).src")}
HB=${HB:-$(nixpath nixpkgs#harfbuzz.dev)}
FC=${FC:-$(nixpath nixpkgs#fontconfig.dev)}
ICU=${ICU:-$(nixpath nixpkgs#icu.dev)}
mkdir -p build
targets=${*:-shim cli edit}

# Everything that links the shim finds it and Skia through these rpaths, so the
# binaries run from anywhere without LD_LIBRARY_PATH.
LINK="-L$ROOT/build -Wl,-rpath,$ROOT/build"
DEFS=(-define:EFFECTS_ROOT="$ROOT" -define:EFFECTS_LINK="$LINK")

for t in $targets; do
	case $t in
	shim)
		# Skia is static; its system libraries come from the nix derivation's inputs.
		deps=$(nix eval --impure --raw --expr 'builtins.concatStringsSep " " (map (p: "${p.lib or p.out or p}") (import ./nix/skia.nix {}).buildInputs)')
		deps="$deps $(nixpath nixpkgs#harfbuzz.out) $(nixpath nixpkgs#libpng.out) $(nixpath nixpkgs#zlib.out)"
		libdirs=()
		for d in $deps; do [ -d "$d/lib" ] && libdirs+=(-L"$d/lib" -Wl,-rpath,"$d/lib"); done
		g++ -std=c++20 -O2 -fPIC -shared shim/sk.cpp -o build/libskshim.so \
			-I"$SKIA_SRC" -I"$SKIA_SRC/include" -I"$HB/include/harfbuzz" -I"$FC/include" -I"$ICU/include" \
			-Wl,--no-undefined -L"$SKIA/lib" "${libdirs[@]}" \
			-Wl,--start-group -lskparagraph -lskshaper -lskunicode_icu -lskunicode_core -lskia -lskcms -lbentleyottmann -Wl,--end-group \
			-lfreetype -lfontconfig -lharfbuzz -licuuc -licui18n -lpng -ljpeg -lwebp -lwebpdemux -lwebpmux -lexpat -lz -lGL -lpthread -ldl
		;;
	cli)
		odin build cli -out:build/effects -o:speed -collection:effects="$ROOT" "${DEFS[@]}" -extra-linker-flags:"$LINK"
		;;
	edit)
		SDL=${SDL:-$(nixpath nixpkgs#sdl3.lib)}
		odin build editor -out:build/effects-edit -o:speed -collection:effects="$ROOT" "${DEFS[@]}" \
			-extra-linker-flags:"$LINK -L$SDL/lib -Wl,-rpath,$SDL/lib"
		;;
	*) echo "unknown target $t" >&2; exit 1 ;;
	esac
done
