// C ABI over the parts of Skia the renderer uses. Kept coarse on purpose: one
// call per drawn shape, paints and styles passed as plain structs, opaque
// handles for everything Skia owns.
//
// Threading: surfaces, canvases and paths belong to one thread at a time.
// Fonts are registered once up front; text layouts and runtime effects are
// cached per thread and stay valid until that thread calls sk_frame_end().
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sk_surface sk_surface;
typedef struct sk_canvas sk_canvas;
typedef struct sk_path sk_path;
typedef struct sk_image sk_image;
typedef struct sk_text sk_text;
typedef struct sk_gpu sk_gpu;

enum { SK_SHADER_NONE = 0, SK_SHADER_LINEAR = 1, SK_SHADER_RADIAL = 2, SK_SHADER_SWEEP = 3 };
#define SK_MAX_STOPS 8

typedef struct {
	uint32_t color;      // 0xAARRGGBB; with a shader only its alpha is used
	float stroke;        // stroke width, 0 = fill
	float blur;          // gaussian mask blur sigma, 0 = none
	int32_t shader;      // SK_SHADER_*
	float sh[4];         // linear: x0 y0 x1 y1 · radial: cx cy r · sweep: cx cy
	int32_t stops;       // number of gradient stops (2..8)
	uint32_t stop_colors[SK_MAX_STOPS];
	float stop_pos[SK_MAX_STOPS]; // all 0 = evenly spaced
	float dash[2];       // on, off; 0 = solid
	float trim[2];       // draw only [start, end] of the path length, both 0 = whole
	int32_t blend;       // SkBlendMode + 1, 0 = src-over
	int32_t square_cap;  // stroke caps/joins: 0 = round, 1 = square/miter
} sk_paint;

typedef struct {
	float bounds[4];     // x y w h, w or h <= 0 = whole canvas
	float alpha;         // 1 = opaque
	float blur;          // blur the layer's content, sigma
	float gray;          // 0..1 desaturate
	float bright;        // multiplier, 0 or 1 = unchanged
	float backdrop_blur; // blur what is already drawn behind the layer, sigma
	float blur_xy[2];    // directional blur (motion blur), sigma along x and y
	int32_t blend;       // how the layer lands on what is below: SkBlendMode + 1, 0 = src-over
	int32_t has_matrix;
	float matrix[20];    // color matrix after gray/bright: 4×5 row-major, offsets in 0..1
	// Runtime image filter over the layer's pixels: an SkSL shader whose
	// `uniform shader src;` is the layer's content, uniforms are floats in
	// declaration order, radius how far (px) it samples away from a pixel.
	const char* sksl;
	const float* uniforms;
	int32_t n_uniforms;
	float sksl_radius;
	// Glow added on top of the content (after blur and sksl): what is brighter
	// than threshold, blurred and added back. sigma_x, sigma_y, threshold
	// (0..1), gain; both sigmas 0 = off. Two passes, so a soft bloom can be
	// combined with wide anamorphic streaks (a large sigma_x, a small sigma_y).
	float glow[4];
	float glow2[4];
} sk_layer;

typedef struct {
	const char* family;  // registered with sk_font_register
	float size;
	float weight;        // 100..900, also drives a variable font's wght axis
	float tracking;      // letter spacing in px
	float line_height;   // multiple of size, 0 = font default
	int32_t align;       // 0 left, 1 center, 2 right
	int32_t tabular;     // tabular figures (tnum)
	int32_t italic;
	int32_t max_lines;   // 0 = unlimited, truncation ends in an ellipsis
	int32_t underline;
} sk_text_style;

typedef struct {
	float width;         // longest line
	float height;
	float baseline;      // first line's alphabetic baseline from the top
	float max_intrinsic; // width without wrapping
	int32_t lines;
} sk_text_metrics;

// ---- surfaces
sk_surface* sk_surface_raster(int32_t w, int32_t h);
void sk_surface_free(sk_surface* s);
sk_canvas* sk_surface_canvas(sk_surface* s);
// BGRA8888 premultiplied (raster surfaces only), row_bytes apart.
const void* sk_surface_pixels(sk_surface* s, size_t* row_bytes);
// Snapshot of the current contents; free with sk_image_free.
sk_image* sk_surface_snapshot(sk_surface* s);
int32_t sk_surface_write_png(sk_surface* s, const char* path);

// ---- canvas state
void sk_canvas_clear(sk_canvas* c, uint32_t argb);
int32_t sk_canvas_save(sk_canvas* c);
// Returns the save count to restore to. A layer whose SkSL does not compile
// is drawn without it (the error goes to stderr once).
int32_t sk_canvas_save_layer(sk_canvas* c, const sk_layer* l);
void sk_canvas_restore(sk_canvas* c);
void sk_canvas_restore_to(sk_canvas* c, int32_t count);
void sk_canvas_translate(sk_canvas* c, float x, float y);
void sk_canvas_scale(sk_canvas* c, float sx, float sy);
void sk_canvas_rotate(sk_canvas* c, float degrees);
// Row-major 4x4, applied on top of the current matrix (perspective tilts).
void sk_canvas_concat44(sk_canvas* c, const float m[16]);
// Maps a rect through the current transform to device pixels (bounding box).
void sk_canvas_map_rect(sk_canvas* c, const float in[4], float out[4]);
void sk_canvas_clip_rect(sk_canvas* c, float x, float y, float w, float h);
void sk_canvas_clip_rrect(sk_canvas* c, float x, float y, float w, float h, float r);
void sk_canvas_clip_path(sk_canvas* c, const sk_path* p);

// ---- shapes
void sk_canvas_draw_paint(sk_canvas* c, const sk_paint* p);
void sk_canvas_draw_rect(sk_canvas* c, float x, float y, float w, float h, const sk_paint* p);
// radii: top-left, top-right, bottom-right, bottom-left
void sk_canvas_draw_rrect(sk_canvas* c, float x, float y, float w, float h, const float radii[4], const sk_paint* p);
void sk_canvas_draw_circle(sk_canvas* c, float cx, float cy, float r, const sk_paint* p);
void sk_canvas_draw_oval(sk_canvas* c, float x, float y, float w, float h, const sk_paint* p);
void sk_canvas_draw_line(sk_canvas* c, float x0, float y0, float x1, float y1, const sk_paint* p);
void sk_canvas_draw_path(sk_canvas* c, const sk_path* path, const sk_paint* p);
// Soft box shadow under a rounded rect, like CSS box-shadow (blur is the CSS blur radius).
void sk_canvas_draw_shadow(sk_canvas* c, float x, float y, float w, float h, float r, float dx, float dy, float blur, float spread, uint32_t color);

// ---- paths
sk_path* sk_path_new(void);
sk_path* sk_path_from_svg(const char* d); // nullptr when d does not parse
void sk_path_free(sk_path* p);
void sk_path_move_to(sk_path* p, float x, float y);
void sk_path_line_to(sk_path* p, float x, float y);
void sk_path_quad_to(sk_path* p, float x1, float y1, float x2, float y2);
void sk_path_cubic_to(sk_path* p, float x1, float y1, float x2, float y2, float x3, float y3);
void sk_path_close(sk_path* p);
void sk_path_add_rrect(sk_path* p, float x, float y, float w, float h, float r);
void sk_path_add_circle(sk_path* p, float cx, float cy, float r);
void sk_path_bounds(const sk_path* p, float out[4]);
float sk_path_length(const sk_path* p);

// ---- images
sk_image* sk_image_from_file(const char* path); // decoded eagerly, nullptr on failure
void sk_image_free(sk_image* i);
void sk_image_size(const sk_image* i, int32_t* w, int32_t* h);
// BGRA8888 premultiplied pixels, copied.
sk_image* sk_image_from_pixels(const void* bgra, int32_t w, int32_t h, size_t row_bytes);
// Fills the rect with the image repeated, shifted by (dx, dy); blend as in sk_paint.
void sk_canvas_draw_image_tiled(sk_canvas* c, const sk_image* i, float x, float y, float w, float h, float dx, float dy, float alpha, int32_t blend);
// src may be null for the whole image; alpha 0..1.
void sk_canvas_draw_image(sk_canvas* c, const sk_image* i, const float src[4], float x, float y, float w, float h, float alpha);

// ---- text
// Registers a font file under a family name. Variable fonts get their weight
// from sk_text_style.weight. Call before any thread lays out text.
int32_t sk_font_register(const char* family, const char* path);
sk_text* sk_text_layout(const char* utf8, size_t len, const sk_text_style* st, float max_width);
void sk_text_get_metrics(sk_text* t, sk_text_metrics* out);
// Draws with the layout's top-left at (x, y).
void sk_text_draw(sk_canvas* c, sk_text* t, float x, float y, const sk_paint* p);
// Evicts this thread's text layouts that were not used for a while.
void sk_frame_end(void);

// ---- runtime effects (SkSL shaders)
// Fills the rect with an SkSL shader; uniforms are floats in declaration order.
// Returns 0 and writes the compile error to err when the shader is invalid.
int32_t sk_canvas_draw_sksl(sk_canvas* c, const char* sksl, const float* uniforms, size_t n_uniforms, float x, float y, float w, float h, char* err, size_t err_len);

// ---- GPU (OpenGL)
typedef void* (*sk_gl_get_proc)(void* ctx, const char* name);
sk_gpu* sk_gpu_new_gl(sk_gl_get_proc get, void* ctx);
void sk_gpu_free(sk_gpu* g);
// Wraps the default framebuffer of the current GL context.
sk_surface* sk_gpu_window_surface(sk_gpu* g, int32_t w, int32_t h, int32_t samples, int32_t stencil);
sk_surface* sk_gpu_offscreen(sk_gpu* g, int32_t w, int32_t h);
void sk_gpu_flush(sk_gpu* g);

#ifdef __cplusplus
}
#endif
