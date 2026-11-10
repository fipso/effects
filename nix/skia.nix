# Skia from nixpkgs with two changes:
# - built with clang instead of gcc: Skia only vectorizes its raster pipeline
#   fully under clang. A full-screen gradient took ~20 ms with the gcc build
#   and ~5 ms with this one (1080p, one thread).
# - static libraries instead of a component build: skparagraph's classes carry
#   no export macro, so the shared libskparagraph.so exports nothing usable.
#   build.sh links these into build/libskshim.so.
{ pkgs ? (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem} }:
(pkgs.skia.override { stdenv = pkgs.clangStdenv; }).overrideAttrs (o: {
  gnFlags = map (f:
    if f == "cc=\"cc\"" then "cc=\"clang\""
    else if f == "cxx=\"c++\"" then "cxx=\"clang++\""
    else if f == "is_component_build=true" then "is_component_build=false"
    else f) o.gnFlags;
  installPhase = builtins.replaceStrings [ "cp *.so *.a *.dylib $out/lib" ] [ "cp *.a $out/lib" ] o.installPhase;
})
