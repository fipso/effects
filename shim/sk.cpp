#include "sk.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

#include "codec/SkCodec.h"
#include "codec/SkJpegDecoder.h"
#include "codec/SkPngDecoder.h"
#include "codec/SkWebpDecoder.h"
#include "core/SkBitmap.h"
#include "core/SkBlurTypes.h"
#include "core/SkCanvas.h"
#include "core/SkColorFilter.h"
#include "core/SkContourMeasure.h"
#include "core/SkData.h"
#include "core/SkFontArguments.h"
#include "core/SkFontMgr.h"
#include "core/SkFontStyle.h"
#include "core/SkImage.h"
#include "core/SkImageFilter.h"
#include "core/SkM44.h"
#include "core/SkMaskFilter.h"
#include "core/SkPaint.h"
#include "core/SkPath.h"
#include "core/SkPathBuilder.h"
#include "core/SkPathEffect.h"
#include "core/SkPixmap.h"
#include "core/SkRRect.h"
#include "core/SkStream.h"
#include "core/SkSurface.h"
#include "core/SkTypeface.h"
#include "effects/SkColorMatrix.h"
#include "effects/SkDashPathEffect.h"
#include "effects/SkGradientShader.h"
#include "effects/SkImageFilters.h"
#include "effects/SkRuntimeEffect.h"
#include "effects/SkTrimPathEffect.h"
#include "encode/SkPngEncoder.h"
#include "gpu/ganesh/GrBackendSurface.h"
#include "gpu/ganesh/GrDirectContext.h"
#include "gpu/ganesh/SkSurfaceGanesh.h"
#include "gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "gpu/ganesh/gl/GrGLBackendSurface.h"
#include "gpu/ganesh/gl/GrGLDirectContext.h"
#include "gpu/ganesh/gl/GrGLInterface.h"
#include "gpu/ganesh/gl/GrGLTypes.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphPainter.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skparagraph/include/TypefaceFontProvider.h"
#include "modules/skunicode/include/SkUnicode_icu.h"
#include "ports/SkFontMgr_fontconfig.h"
#include "ports/SkFontScanner_FreeType.h"
#include "utils/SkParsePath.h"

namespace tl = skia::textlayout;

struct sk_surface { sk_sp<SkSurface> s; };
struct sk_image { sk_sp<SkImage> i; };
struct sk_gpu { sk_sp<GrDirectContext> ctx; };
struct sk_path {
	SkPathBuilder b;
	SkPath p;
	bool dirty = false;
	const SkPath& get() {
		if (dirty) p = b.snapshot(), dirty = false;
		return p;
	}
};

static SkCanvas* C(sk_canvas* c) { return reinterpret_cast<SkCanvas*>(c); }
static SkRect R(float x, float y, float w, float h) { return SkRect::MakeXYWH(x, y, w, h); }

static SkFontMgr* system_fonts() {
	static sk_sp<SkFontMgr> mgr = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
	return mgr.get();
}

static void register_codecs() {
	static std::once_flag once;
	std::call_once(once, [] {
		SkCodecs::Register(SkPngDecoder::Decoder());
		SkCodecs::Register(SkJpegDecoder::Decoder());
		SkCodecs::Register(SkWebpDecoder::Decoder());
	});
}

// Compiled SkSL shaders, per thread; a shader that fails reports its error once.
static sk_sp<SkRuntimeEffect> runtime_effect(const char* sksl, std::string* error = nullptr) {
	thread_local std::unordered_map<std::string, sk_sp<SkRuntimeEffect>> cache;
	thread_local std::unordered_map<std::string, std::string> failed;
	if (auto it = cache.find(sksl); it != cache.end()) return it->second;
	if (auto it = failed.find(sksl); it != failed.end()) {
		if (error) *error = it->second;
		return nullptr;
	}
	auto res = SkRuntimeEffect::MakeForShader(SkString(sksl));
	if (!res.effect) {
		std::string e = res.errorText.c_str();
		fprintf(stderr, "sksl: %s\n", e.c_str());
		failed.emplace(sksl, e);
		if (error) *error = e;
		return nullptr;
	}
	cache.emplace(sksl, res.effect);
	return res.effect;
}

static SkPaint to_paint(const sk_paint* p) {
	SkPaint paint;
	paint.setAntiAlias(true);
	paint.setColor(p->color);
	if (p->stroke > 0) {
		paint.setStyle(SkPaint::kStroke_Style);
		paint.setStrokeWidth(p->stroke);
		paint.setStrokeCap(p->square_cap ? SkPaint::kButt_Cap : SkPaint::kRound_Cap);
		paint.setStrokeJoin(p->square_cap ? SkPaint::kMiter_Join : SkPaint::kRound_Join);
	}
	if (p->blur > 0) paint.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, p->blur));
	if (p->blend > 0) paint.setBlendMode(SkBlendMode(p->blend - 1));

	sk_sp<SkPathEffect> fx;
	if (p->trim[0] != 0 || (p->trim[1] != 0 && p->trim[1] < 1)) fx = SkTrimPathEffect::Make(p->trim[0], p->trim[1]);
	if (p->dash[0] > 0) {
		auto d = SkDashPathEffect::Make({p->dash, 2}, 0.0f);
		fx = fx ? SkPathEffect::MakeCompose(d, fx) : d;
	}
	if (fx) paint.setPathEffect(fx);

	if (p->shader != SK_SHADER_NONE && p->stops >= 2) {
		int n = p->stops > SK_MAX_STOPS ? SK_MAX_STOPS : p->stops;
		SkColor colors[SK_MAX_STOPS];
		float pos[SK_MAX_STOPS];
		bool even = true;
		for (int i = 0; i < n; i++) {
			colors[i] = p->stop_colors[i];
			pos[i] = p->stop_pos[i];
			if (pos[i] != 0) even = false;
		}
		const float* ps = even ? nullptr : pos;
		sk_sp<SkShader> sh;
		if (p->shader == SK_SHADER_LINEAR) {
			SkPoint pts[2] = {{p->sh[0], p->sh[1]}, {p->sh[2], p->sh[3]}};
			sh = SkGradientShader::MakeLinear(pts, colors, ps, n, SkTileMode::kClamp);
		} else if (p->shader == SK_SHADER_RADIAL) {
			sh = SkGradientShader::MakeRadial({p->sh[0], p->sh[1]}, p->sh[2], colors, ps, n, SkTileMode::kClamp);
		} else if (p->shader == SK_SHADER_SWEEP) {
			sh = SkGradientShader::MakeSweep(p->sh[0], p->sh[1], colors, ps, n);
		}
		paint.setShader(sh);
		// 8 bits a channel are too few for a slow, dark gradient: without
		// dithering its levels show as bands.
		paint.setDither(true);
		// The paint's alpha scales the shader, so keep only the alpha of color.
		paint.setColor(SkColorSetA(SK_ColorBLACK, SkColorGetA(p->color)));
	}
	return paint;
}

extern "C" {

// ---------------------------------------------------------------- surfaces

sk_surface* sk_surface_raster(int32_t w, int32_t h) {
	auto s = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(w, h));
	return s ? new sk_surface{std::move(s)} : nullptr;
}
void sk_surface_free(sk_surface* s) { delete s; }
sk_canvas* sk_surface_canvas(sk_surface* s) { return reinterpret_cast<sk_canvas*>(s->s->getCanvas()); }
const void* sk_surface_pixels(sk_surface* s, size_t* row_bytes) {
	SkPixmap pm;
	if (!s->s->peekPixels(&pm)) return nullptr;
	*row_bytes = pm.rowBytes();
	return pm.addr();
}
sk_image* sk_surface_snapshot(sk_surface* s) {
	auto i = s->s->makeImageSnapshot();
	return i ? new sk_image{std::move(i)} : nullptr;
}
int32_t sk_surface_write_png(sk_surface* s, const char* path) {
	SkBitmap bm;
	bm.allocPixels(SkImageInfo::MakeN32Premul(s->s->width(), s->s->height()));
	if (!s->s->readPixels(bm, 0, 0)) return 0;
	SkFILEWStream out(path);
	return out.isValid() && SkPngEncoder::Encode(&out, bm.pixmap(), {});
}

// ---------------------------------------------------------------- canvas state

void sk_canvas_clear(sk_canvas* c, uint32_t argb) { C(c)->clear(argb); }
int32_t sk_canvas_save(sk_canvas* c) { return C(c)->save(); }
int32_t sk_canvas_save_layer(sk_canvas* c, const sk_layer* l) {
	SkPaint paint;
	paint.setAlphaf(l->alpha);
	if (l->blend > 0) paint.setBlendMode(SkBlendMode(l->blend - 1));

	sk_sp<SkImageFilter> filter;
	float bx = std::hypot(l->blur, l->blur_xy[0]), by = std::hypot(l->blur, l->blur_xy[1]);
	if (bx > 0 || by > 0) filter = SkImageFilters::Blur(bx, by, nullptr);
	if (l->sksl) {
		if (auto fx = runtime_effect(l->sksl)) {
			size_t need = fx->uniformSize();
			auto data = SkData::MakeZeroInitialized(need);
			memcpy(data->writable_data(), l->uniforms, std::min(need, (size_t)l->n_uniforms * sizeof(float)));
			SkRuntimeEffectBuilder b(fx, std::move(data));
			filter = SkImageFilters::RuntimeShader(b, l->sksl_radius, "src", filter);
		}
	}
	for (const float* g : {l->glow, l->glow2}) {
		if (g[0] <= 0 && g[1] <= 0) continue;
		// bright = (c - threshold) * gain / (1 - threshold), clamped by the filter
		float th = std::clamp(g[2], 0.0f, 0.95f), k = (g[3] > 0 ? g[3] : 1) / (1 - th);
		float m[20] = {k, 0, 0, 0, -th * k, 0, k, 0, 0, -th * k, 0, 0, k, 0, -th * k, 0, 0, 0, 1, 0};
		auto bright = SkImageFilters::ColorFilter(SkColorFilters::Matrix(m), filter);
		filter = SkImageFilters::Blend(SkBlendMode::kPlus, filter, SkImageFilters::Blur(g[0], g[1], bright));
	}
	if (filter) paint.setImageFilter(filter);

	bool bright = l->bright > 0 && l->bright != 1;
	if (l->gray > 0 || bright || l->has_matrix) {
		SkColorMatrix cm;
		cm.setSaturation(1 - l->gray);
		if (bright) {
			SkColorMatrix b;
			b.setScale(l->bright, l->bright, l->bright, 1);
			cm.postConcat(b);
		}
		if (l->has_matrix) {
			SkColorMatrix m;
			m.setRowMajor(l->matrix);
			cm.postConcat(m);
		}
		paint.setColorFilter(SkColorFilters::Matrix(cm));
	}
	SkRect bounds = R(l->bounds[0], l->bounds[1], l->bounds[2], l->bounds[3]);
	const SkRect* b = l->bounds[2] > 0 && l->bounds[3] > 0 ? &bounds : nullptr;
	sk_sp<SkImageFilter> backdrop;
	if (l->backdrop_blur > 0) backdrop = SkImageFilters::Blur(l->backdrop_blur, l->backdrop_blur, SkTileMode::kClamp, nullptr);
	return C(c)->saveLayer(SkCanvas::SaveLayerRec(b, &paint, backdrop.get(), 0));
}
void sk_canvas_restore(sk_canvas* c) { C(c)->restore(); }
void sk_canvas_restore_to(sk_canvas* c, int32_t count) { C(c)->restoreToCount(count); }
void sk_canvas_translate(sk_canvas* c, float x, float y) { C(c)->translate(x, y); }
void sk_canvas_scale(sk_canvas* c, float sx, float sy) { C(c)->scale(sx, sy); }
void sk_canvas_rotate(sk_canvas* c, float degrees) { C(c)->rotate(degrees); }
void sk_canvas_concat44(sk_canvas* c, const float m[16]) { C(c)->concat(SkM44::RowMajor(m)); }
void sk_canvas_map_rect(sk_canvas* c, const float in[4], float out[4]) {
	SkRect r = C(c)->getLocalToDeviceAs3x3().mapRect(R(in[0], in[1], in[2], in[3]));
	out[0] = r.x(), out[1] = r.y(), out[2] = r.width(), out[3] = r.height();
}
void sk_canvas_clip_rect(sk_canvas* c, float x, float y, float w, float h) { C(c)->clipRect(R(x, y, w, h), true); }
void sk_canvas_clip_rrect(sk_canvas* c, float x, float y, float w, float h, float r) {
	C(c)->clipRRect(SkRRect::MakeRectXY(R(x, y, w, h), r, r), true);
}
void sk_canvas_clip_path(sk_canvas* c, const sk_path* p) { C(c)->clipPath(const_cast<sk_path*>(p)->get(), true); }

// ---------------------------------------------------------------- shapes

void sk_canvas_draw_paint(sk_canvas* c, const sk_paint* p) { C(c)->drawPaint(to_paint(p)); }
void sk_canvas_draw_rect(sk_canvas* c, float x, float y, float w, float h, const sk_paint* p) {
	C(c)->drawRect(R(x, y, w, h), to_paint(p));
}
void sk_canvas_draw_rrect(sk_canvas* c, float x, float y, float w, float h, const float radii[4], const sk_paint* p) {
	SkVector rad[4] = {{radii[0], radii[0]}, {radii[1], radii[1]}, {radii[2], radii[2]}, {radii[3], radii[3]}};
	SkRRect rr;
	rr.setRectRadii(R(x, y, w, h), rad);
	C(c)->drawRRect(rr, to_paint(p));
}
void sk_canvas_draw_circle(sk_canvas* c, float cx, float cy, float r, const sk_paint* p) { C(c)->drawCircle(cx, cy, r, to_paint(p)); }
void sk_canvas_draw_oval(sk_canvas* c, float x, float y, float w, float h, const sk_paint* p) { C(c)->drawOval(R(x, y, w, h), to_paint(p)); }
void sk_canvas_draw_line(sk_canvas* c, float x0, float y0, float x1, float y1, const sk_paint* p) {
	C(c)->drawLine(x0, y0, x1, y1, to_paint(p));
}
void sk_canvas_draw_path(sk_canvas* c, const sk_path* path, const sk_paint* p) {
	C(c)->drawPath(const_cast<sk_path*>(path)->get(), to_paint(p));
}
void sk_canvas_draw_shadow(sk_canvas* c, float x, float y, float w, float h, float r, float dx, float dy, float blur, float spread, uint32_t color) {
	SkPaint paint;
	paint.setAntiAlias(true);
	paint.setColor(color);
	if (blur > 0) paint.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, blur / 2));
	SkRect rect = R(x + dx - spread, y + dy - spread, w + 2 * spread, h + 2 * spread);
	float rr = r + spread > 0 ? r + spread : 0;
	C(c)->drawRRect(SkRRect::MakeRectXY(rect, rr, rr), paint);
}

// ---------------------------------------------------------------- paths

sk_path* sk_path_new(void) { return new sk_path; }
sk_path* sk_path_from_svg(const char* d) {
	auto parsed = SkParsePath::FromSVGString(d);
	if (!parsed) return nullptr;
	auto p = new sk_path;
	p->b = SkPathBuilder(*parsed);
	p->p = *parsed;
	return p;
}
void sk_path_free(sk_path* p) { delete p; }
void sk_path_move_to(sk_path* p, float x, float y) { p->b.moveTo(x, y), p->dirty = true; }
void sk_path_line_to(sk_path* p, float x, float y) { p->b.lineTo(x, y), p->dirty = true; }
void sk_path_quad_to(sk_path* p, float x1, float y1, float x2, float y2) { p->b.quadTo(x1, y1, x2, y2), p->dirty = true; }
void sk_path_cubic_to(sk_path* p, float x1, float y1, float x2, float y2, float x3, float y3) {
	p->b.cubicTo(x1, y1, x2, y2, x3, y3), p->dirty = true;
}
void sk_path_close(sk_path* p) { p->b.close(), p->dirty = true; }
void sk_path_add_rrect(sk_path* p, float x, float y, float w, float h, float r) {
	p->b.addRRect(SkRRect::MakeRectXY(R(x, y, w, h), r, r)), p->dirty = true;
}
void sk_path_add_circle(sk_path* p, float cx, float cy, float r) { p->b.addCircle(cx, cy, r), p->dirty = true; }
void sk_path_bounds(const sk_path* p, float out[4]) {
	SkRect b = const_cast<sk_path*>(p)->get().getBounds();
	out[0] = b.x(), out[1] = b.y(), out[2] = b.width(), out[3] = b.height();
}
float sk_path_length(const sk_path* p) {
	float len = 0;
	SkContourMeasureIter it(const_cast<sk_path*>(p)->get(), false);
	while (auto m = it.next()) len += m->length();
	return len;
}

// ---------------------------------------------------------------- images

sk_image* sk_image_from_file(const char* path) {
	register_codecs();
	auto data = SkData::MakeFromFileName(path);
	if (!data) return nullptr;
	auto img = SkImages::DeferredFromEncodedData(data);
	if (!img) return nullptr;
	img = img->makeRasterImage(nullptr);
	return img ? new sk_image{std::move(img)} : nullptr;
}
void sk_image_free(sk_image* i) { delete i; }
sk_image* sk_image_from_pixels(const void* bgra, int32_t w, int32_t h, size_t row_bytes) {
	SkPixmap pm(SkImageInfo::MakeN32Premul(w, h), bgra, row_bytes);
	auto img = SkImages::RasterFromPixmapCopy(pm);
	return img ? new sk_image{std::move(img)} : nullptr;
}
void sk_canvas_draw_image_tiled(sk_canvas* c, const sk_image* i, float x, float y, float w, float h, float dx, float dy, float alpha, int32_t blend) {
	SkPaint paint;
	SkMatrix m = SkMatrix::Translate(dx, dy);
	paint.setShader(i->i->makeShader(SkTileMode::kRepeat, SkTileMode::kRepeat, SkSamplingOptions(SkFilterMode::kNearest), &m));
	paint.setAlphaf(alpha);
	if (blend > 0) paint.setBlendMode(SkBlendMode(blend - 1));
	C(c)->drawRect(R(x, y, w, h), paint);
}
void sk_image_size(const sk_image* i, int32_t* w, int32_t* h) { *w = i->i->width(), *h = i->i->height(); }
void sk_canvas_draw_image(sk_canvas* c, const sk_image* i, const float src[4], float x, float y, float w, float h, float alpha) {
	SkPaint paint;
	paint.setAntiAlias(true);
	paint.setAlphaf(alpha);
	SkRect s = src ? R(src[0], src[1], src[2], src[3]) : SkRect::MakeIWH(i->i->width(), i->i->height());
	// Mipmaps only help when shrinking, and make every other draw much slower on the CPU.
	auto m = C(c)->getTotalMatrix();
	float k = std::min(w * m.getScaleX() / s.width(), h * m.getScaleY() / s.height());
	SkSamplingOptions sampling(SkFilterMode::kLinear, k < 0.75f ? SkMipmapMode::kLinear : SkMipmapMode::kNone);
	C(c)->drawImageRect(i->i.get(), s, R(x, y, w, h), sampling, &paint, SkCanvas::kFast_SrcRectConstraint);
}

// ---------------------------------------------------------------- text

} // extern "C"

namespace {
struct Registry {
	std::mutex m;
	struct Font {
		std::string family, path;
		sk_sp<SkTypeface> tf;
	};
	std::vector<Font> fonts;
	std::atomic<int> version{0};
};
Registry& registry() {
	static Registry r;
	return r;
}
} // namespace

struct sk_text {
	std::unique_ptr<tl::Paragraph> p;
	size_t len;
	uint64_t used;
};

namespace {
struct TextCache {
	int version = -1;
	sk_sp<tl::FontCollection> fc;
	sk_sp<SkUnicode> unicode;
	std::unordered_map<std::string, std::unique_ptr<sk_text>> map;
	uint64_t frame = 0;

	void refresh() {
		auto& r = registry();
		int v = r.version.load();
		if (v == version && fc) return;
		auto provider = sk_make_sp<tl::TypefaceFontProvider>();
		{
			std::lock_guard<std::mutex> lock(r.m);
			for (auto& f : r.fonts) provider->registerTypeface(f.tf, SkString(f.family.c_str()));
		}
		fc = sk_make_sp<tl::FontCollection>();
		fc->setAssetFontManager(provider);
		fc->setDefaultFontManager(sk_ref_sp(system_fonts()));
		fc->enableFontFallback();
		if (!unicode) unicode = SkUnicodes::ICU::Make();
		map.clear();
		version = v;
	}
};
thread_local TextCache text_cache;

template <typename T> void put(std::string& k, const T& v) { k.append(reinterpret_cast<const char*>(&v), sizeof v); }
} // namespace

extern "C" {

int32_t sk_font_register(const char* family, const char* path) {
	auto& r = registry();
	std::lock_guard<std::mutex> lock(r.m);
	for (auto& f : r.fonts)
		if (f.family == family && f.path == path) return 1; // hot reloads register again
	auto tf = system_fonts()->makeFromFile(path);
	if (!tf) return 0;
	r.fonts.push_back({family, path, std::move(tf)});
	r.version++;
	return 1;
}

sk_text* sk_text_layout(const char* utf8, size_t len, const sk_text_style* st, float max_width) {
	auto& tc = text_cache;
	tc.refresh();
	std::string key(st->family ? st->family : "");
	key.push_back('\0');
	put(key, st->size), put(key, st->weight), put(key, st->tracking), put(key, st->line_height);
	put(key, st->align), put(key, st->tabular), put(key, st->italic), put(key, st->max_lines), put(key, st->underline);
	put(key, max_width);
	key.append(utf8, len);
	if (auto it = tc.map.find(key); it != tc.map.end()) {
		it->second->used = tc.frame;
		return it->second.get();
	}

	tl::TextStyle ts;
	ts.setFontFamilies({SkString(st->family ? st->family : "")});
	ts.setFontSize(st->size);
	int weight = st->weight > 0 ? (int)st->weight : 400;
	ts.setFontStyle(SkFontStyle(weight, SkFontStyle::kNormal_Width, st->italic ? SkFontStyle::kItalic_Slant : SkFontStyle::kUpright_Slant));
	SkFontArguments::VariationPosition::Coordinate wght = {SkSetFourByteTag('w', 'g', 'h', 't'), (float)weight};
	SkFontArguments args;
	args.setVariationDesignPosition({&wght, 1});
	ts.setFontArguments(args);
	ts.setLetterSpacing(st->tracking);
	if (st->line_height > 0) ts.setHeight(st->line_height), ts.setHeightOverride(true);
	if (st->tabular) ts.addFontFeature(SkString("tnum"), 1);
	if (st->underline) ts.setDecoration(tl::TextDecoration::kUnderline);
	ts.setColor(SK_ColorBLACK);

	tl::ParagraphStyle ps;
	ps.setTextStyle(ts);
	ps.setTextAlign(st->align == 1 ? tl::TextAlign::kCenter : st->align == 2 ? tl::TextAlign::kRight : tl::TextAlign::kLeft);
	if (st->max_lines > 0) ps.setMaxLines(st->max_lines), ps.setEllipsis(SkString("…"));

	auto b = tl::ParagraphBuilder::make(ps, tc.fc, tc.unicode);
	b->pushStyle(ts);
	b->addText(utf8, len);
	b->pop();
	auto p = b->Build();
	if (max_width > 0) {
		p->layout(max_width);
	} else {
		// Unbounded: lay out once to measure, then again at that width so alignment works.
		p->layout(INFINITY);
		p->layout(std::ceil(p->getMaxIntrinsicWidth()) + 1);
	}
	auto t = std::make_unique<sk_text>(sk_text{std::move(p), len, tc.frame});
	sk_text* out = t.get();
	tc.map.emplace(std::move(key), std::move(t));
	return out;
}

void sk_text_get_metrics(sk_text* t, sk_text_metrics* out) {
	out->width = t->p->getLongestLine();
	out->height = t->p->getHeight();
	out->baseline = t->p->getAlphabeticBaseline();
	out->max_intrinsic = t->p->getMaxIntrinsicWidth();
	out->lines = (int32_t)t->p->lineNumber();
}

} // extern "C"

namespace {
// Draws a laid-out paragraph with one paint for all of its glyphs and
// decorations. The paragraph caches its text blobs together with the paint
// of its first draw, so recoloring it through its own styles has no effect.
struct PaintPainter : tl::ParagraphPainter {
	SkCanvas* c;
	SkPaint paint;
	PaintPainter(SkCanvas* c, SkPaint p) : c(c), paint(std::move(p)) {}
	SkPaint stroked(const DecorationStyle& d) {
		SkPaint p = paint;
		p.setStyle(SkPaint::kStroke_Style);
		p.setStrokeWidth(d.getStrokeWidth());
		return p;
	}
	void drawTextBlob(const sk_sp<SkTextBlob>& blob, SkScalar x, SkScalar y, const SkPaintOrID&) override { c->drawTextBlob(blob, x, y, paint); }
	void drawTextShadow(const sk_sp<SkTextBlob>& blob, SkScalar x, SkScalar y, SkColor color, SkScalar sigma) override {
		SkPaint p;
		p.setColor(color);
		if (sigma > 0) p.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, sigma));
		c->drawTextBlob(blob, x, y, p);
	}
	void drawRect(const SkRect& r, const SkPaintOrID& p) override {
		if (auto* sp = std::get_if<SkPaint>(&p)) c->drawRect(r, *sp);
	}
	void drawFilledRect(const SkRect& r, const DecorationStyle&) override { c->drawRect(r, paint); }
	void drawPath(const SkPath& path, const DecorationStyle& d) override { c->drawPath(path, stroked(d)); }
	void drawLine(SkScalar x0, SkScalar y0, SkScalar x1, SkScalar y1, const DecorationStyle& d) override {
		c->drawLine(x0, y0, x1, y1, stroked(d));
	}
	void clipRect(const SkRect& r) override { c->clipRect(r); }
	void translate(SkScalar dx, SkScalar dy) override { c->translate(dx, dy); }
	void save() override { c->save(); }
	void restore() override { c->restore(); }
};
} // namespace

extern "C" {

void sk_text_draw(sk_canvas* c, sk_text* t, float x, float y, const sk_paint* p) {
	PaintPainter painter(C(c), to_paint(p));
	t->p->paint(&painter, x, y);
}

void sk_frame_end(void) {
	auto& tc = text_cache;
	tc.frame++;
	if (tc.map.size() < 256) return;
	for (auto it = tc.map.begin(); it != tc.map.end();) {
		if (tc.frame - it->second->used > 30) it = tc.map.erase(it);
		else ++it;
	}
}

// ---------------------------------------------------------------- runtime effects

int32_t sk_canvas_draw_sksl(sk_canvas* c, const char* sksl, const float* uniforms, size_t n_uniforms, float x, float y, float w, float h, char* err, size_t err_len) {
	std::string error;
	auto fx = runtime_effect(sksl, &error);
	if (!fx) {
		if (err && err_len) snprintf(err, err_len, "%s", error.c_str());
		return 0;
	}
	size_t need = fx->uniformSize();
	auto data = SkData::MakeZeroInitialized(need);
	memcpy(data->writable_data(), uniforms, std::min(need, n_uniforms * sizeof(float)));
	SkPaint paint;
	paint.setShader(fx->makeShader(data, nullptr, 0));
	paint.setDither(true);
	C(c)->drawRect(R(x, y, w, h), paint);
	return 1;
}

// ---------------------------------------------------------------- GPU

sk_gpu* sk_gpu_new_gl(sk_gl_get_proc get, void* ctx) {
	auto iface = GrGLMakeAssembledInterface(ctx, reinterpret_cast<GrGLGetProc>(get));
	if (!iface) return nullptr;
	auto dc = GrDirectContexts::MakeGL(iface);
	return dc ? new sk_gpu{std::move(dc)} : nullptr;
}
void sk_gpu_free(sk_gpu* g) {
	if (g) g->ctx->abandonContext();
	delete g;
}
sk_surface* sk_gpu_window_surface(sk_gpu* g, int32_t w, int32_t h, int32_t samples, int32_t stencil) {
	GrGLFramebufferInfo fb = {0, 0x8058 /* GL_RGBA8 */};
	auto rt = GrBackendRenderTargets::MakeGL(w, h, samples, stencil, fb);
	auto s = SkSurfaces::WrapBackendRenderTarget(g->ctx.get(), rt, kBottomLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType, nullptr, nullptr);
	return s ? new sk_surface{std::move(s)} : nullptr;
}
sk_surface* sk_gpu_offscreen(sk_gpu* g, int32_t w, int32_t h) {
	auto s = SkSurfaces::RenderTarget(g->ctx.get(), skgpu::Budgeted::kNo, SkImageInfo::MakeN32Premul(w, h));
	return s ? new sk_surface{std::move(s)} : nullptr;
}
void sk_gpu_flush(sk_gpu* g) { g->ctx->flushAndSubmit(); }

} // extern "C"
