// NegImage.m —— 见 NegImage.h
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <math.h>
#include "NegImage.h"
#include "NegMath.h"

// ── 工具 ────────────────────────────────────────────────────────────────────

int negIsRawExt(const char *path) {
    const char *e = strrchr(path, '.');
    if (!e || !e[1]) return 0;
    static const char *exts[] = {"arw","cr3","cr2","nef","nrw","dng","raf","orf",
                                 "rw2","pef","srw","dcr","kdc","mrw","x3f", NULL};
    for (int i = 0; exts[i]; i++) if (!strcasecmp(e + 1, exts[i])) return 1;
    return 0;
}

static void setErr(char *err, size_t n, NSString *msg) {
    if (err && n) snprintf(err, n, "%s", msg.UTF8String);
}

static void setIf(id obj, NSString *key, id val) {
    @try { [obj setValue:val forKey:key]; } @catch (NSException *e) { (void)e; }
}

// ── 相机 raw → CGImage（线性）───────────────────────────────────────────────
// 属性名必须用运行时那套 input*（CIRAWFilterImpl 继承 CIFilter 的命名），
// 而不是 CIRAWFilter 头文件里那套 —— 照头文件写会「一项都没生效」。
// 关掉相机外观的理由：内置对比度 / 饱和度 / 高光恢复都是**按通道**施加的，
// 会把逐通道密度斜率拧弯，而那正是我们要测的量。详见 tools/raw2linear.m。
//
// ★ 第二趟曝光补偿是必须的，不是保险。负片上最亮的区域就是未曝光的片基，
//   而相机翻拍时曝光通常会给到「片基接近满量程」。CI 渲染成 16 位整数时超出
//   1.0 的部分被直接削平 —— 削掉的恰恰是零点要用的那部分（实测某张 NEF 的
//   红通道有 12.3% 的像素在 1.0 以上），于是零点被解成 1.0，全画面崩掉。
//   所以先渲染一张四分之一的小图，量出「每像素三通道最大值」的 99.95 百分位，
//   据此补一个只降不升的 EV，把最亮处压到 0.98 以下再正式渲染。
static CGImageRef rawToCGImage(const char *path, char *err, size_t errLen, double *evUsed) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CIRAWFilter *f = (CIRAWFilter *)[CIFilter filterWithImageURL:url options:@{}];
    if (!f) { setErr(err, errLen, @"系统不支持这个 raw（Core Image 认不出它的机型）"); return NULL; }

    setIf(f, @"inputDraftMode",                     @NO);
    setIf(f, @"inputBoost",                         @0.0f);
    setIf(f, @"inputBoostShadowAmount",             @0.0f);
    setIf(f, @"inputDisableGamutMap",               @YES);
    setIf(f, @"inputEnableSharpening",              @NO);
    setIf(f, @"inputEnableVendorLensCorrection",    @NO);
    setIf(f, @"inputEnableEDRMode",                 @NO);
    setIf(f, @"inputEnableNoiseTracking",           @NO);
    setIf(f, @"inputLocalToneMapAmount",            @0.0f);
    setIf(f, @"inputColorNoiseReductionAmount",     @0.0f);
    setIf(f, @"inputLuminanceNoiseReductionAmount", @0.0f);
    setIf(f, @"inputNoiseReductionAmount",          @0.0f);
    setIf(f, @"inputMoireAmount",                   @0.0f);
    setIf(f, @"inputIgnoreOrientation",             @NO);

    CGColorSpaceRef lin = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CIContext *ctx = [CIContext contextWithOptions:@{
        kCIContextWorkingColorSpace:  (__bridge id)lin,
        kCIContextOutputColorSpace:   (__bridge id)lin,
        kCIContextCacheIntermediates: @NO,
    }];

    // ── 第一趟：小图探顶 ────────────────────────────────────────────────────
    double ev = 0.0;
    {
        setIf(f, @"inputScaleFactor", @0.25f);
        setIf(f, @"inputEV",          @0.0f);
        CIImage *s = f.outputImage;
        if (s) {
            s = [s imageByCroppingToRect:CGRectMake(0, 0, f.nativeSize.width, f.nativeSize.height)];
            size_t w = (size_t)f.nativeSize.width, h = (size_t)f.nativeSize.height;
            if (w > 0 && h > 0 && w * h < 40u * 1000u * 1000u) {
                size_t rb = w * 4 * sizeof(float);
                float *buf = malloc(rb * h);
                float *peak = malloc(sizeof(float) * w * h);
                if (buf && peak) {
                    [ctx render:s toBitmap:buf rowBytes:rb bounds:s.extent
                          format:kCIFormatRGBAf colorSpace:lin];
                    size_t n = 0;
                    for (size_t i = 0; i < w * h; i++) {
                        if (buf[i * 4 + 3] <= 0) continue;      // 跳过无效像素
                        float m = buf[i * 4];
                        if (buf[i * 4 + 1] > m) m = buf[i * 4 + 1];
                        if (buf[i * 4 + 2] > m) m = buf[i * 4 + 2];
                        peak[n++] = m;
                    }
                    if (n > 1000) {
                        float p = negPercentileFast(peak, n, 99.95);
                        if (p > 0.98f) ev = -log2((double)p / 0.98);
                        if (ev < -6.0) ev = -6.0;               // 别把画面压死
                    }
                }
                free(buf);
                free(peak);
            }
        }
    }

    // ── 第二趟：正式渲染 ────────────────────────────────────────────────────
    setIf(f, @"inputScaleFactor", @1.0f);
    setIf(f, @"inputEV",          @(ev));
    if (evUsed) *evUsed = ev;

    CIImage *out = f.outputImage;
    if (!out) { CGColorSpaceRelease(lin); setErr(err, errLen, @"raw 解码失败"); return NULL; }
    out = [out imageByCroppingToRect:CGRectMake(0, 0, f.nativeSize.width, f.nativeSize.height)];

    CGImageRef cg = [ctx createCGImage:out fromRect:out.extent
                                 format:kCIFormatRGBA16 colorSpace:lin];
    CGColorSpaceRelease(lin);
    if (!cg) setErr(err, errLen, @"raw 渲染失败");
    return cg;
}

static CGImageRef loadCGImage(const char *path, char *err, size_t errLen,
                              int *fromRaw, double *evUsed) {
    if (fromRaw) *fromRaw = 0;
    if (evUsed) *evUsed = 0.0;
    if (negIsRawExt(path)) {
        if (fromRaw) *fromRaw = 1;
        return rawToCGImage(path, err, errLen, evUsed);
    }
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) { setErr(err, errLen, @"打不开这个文件"); return NULL; }
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) setErr(err, errLen, @"解码失败（可能是不支持的位深或压缩方式）");
    return cg;
}

// 挑一个「整数位图上下文」能用的色彩空间。
//
// ★ 这里有个不显眼的坑：苹果的**扩展**色彩空间（kCGColorSpaceExtendedSRGB、
//   kCGColorSpaceExtendedLinearSRGB）**不能**用于整数位图上下文，只能配 32 位浮点。
//   而 Core Image 解码 raw 之后给出的 CGImage 恰恰就是扩展线性 sRGB ——
//   于是照抄过来建上下文必然失败，NEF 一张都读不进来（报「建不出位图上下文」）。
//   同族的非扩展版本传输函数完全一样，[0,1] 区间内的数值不会被改动，
//   所以换成 LinearSRGB / sRGB 只是丢掉了超出范围的部分，正是我们要的。
//
// 顺序是「能不改就不改」：先用源空间本身，不行再退到同族的非扩展版本。
// 源本身是线性的就优先 LinearSRGB，否则优先 sRGB —— 退错了会把传输函数套第二遍。
static CGColorSpaceRef pickIntSpace(CGColorSpaceRef src, size_t bpc, CGBitmapInfo info, BOOL *own) {
    CGColorSpaceRef lin = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    BOOL srcLinear = NO;
    if (src) {
        CFStringRef nm = CGColorSpaceCopyName(src);
        if (nm) {
            srcLinear = (CFStringFind(nm, CFSTR("Linear"), kCFCompareCaseInsensitive).location
                         != kCFNotFound);
            CFRelease(nm);
        }
    }
    CGColorSpaceRef cands[3];
    int n = 0;
    if (src) cands[n++] = src;
    if (srcLinear) { cands[n++] = lin; cands[n++] = srgb; }
    else           { cands[n++] = srgb; cands[n++] = lin; }

    CGColorSpaceRef chosen = NULL;
    for (int i = 0; i < n; i++) {
        if (!cands[i]) continue;
        CGContextRef probe = CGBitmapContextCreate(NULL, 2, 2, bpc, 32, cands[i], info);
        if (probe) { CGContextRelease(probe); chosen = cands[i]; break; }
    }
    if (!chosen) chosen = CGColorSpaceCreateDeviceRGB(), *own = YES;
    else *own = (chosen == lin || chosen == srgb);
    if (lin != chosen) CGColorSpaceRelease(lin);
    if (srgb != chosen) CGColorSpaceRelease(srgb);
    return chosen;
}

// CGImage → 线性 float。按位深决定要不要反解 sRGB。
// 位深 >= 16 视为已经是线性；8 位视为 sRGB 编码。
static float *cgToLinearRGB(CGImageRef cg, size_t *outW, size_t *outH,
                            int *bits, char *err, size_t errLen) {
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    size_t bpc = CGImageGetBitsPerComponent(cg);
    int is8 = (bpc <= 8);
    if (bits) *bits = (int)bpc;

    CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    if (!is8) info |= kCGBitmapByteOrder16Little;
    BOOL ownSpace = NO;
    CGColorSpaceRef space = pickIntSpace(CGImageGetColorSpace(cg), is8 ? 8 : 16, info, &ownSpace);

    size_t comp = 4, bpcs = is8 ? 1 : 2;
    size_t bpr = w * comp * bpcs;
    void *buf = calloc(h, bpr);
    if (!buf) {
        if (ownSpace) CGColorSpaceRelease(space);
        setErr(err, errLen, @"内存不够");
        return NULL;
    }
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, is8 ? 8 : 16, bpr, space, info);
    if (!ctx) {
        free(buf);
        if (ownSpace) CGColorSpaceRelease(space);
        setErr(err, errLen, @"建不出位图上下文");
        return NULL;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    CGContextRelease(ctx);
    if (ownSpace) CGColorSpaceRelease(space);

    float *rgb = malloc(sizeof(float) * w * h * 3);
    if (!rgb) { free(buf); setErr(err, errLen, @"内存不够"); return NULL; }
    if (is8) {
        const uint8_t *p = buf;
        for (size_t i = 0, n = w * h; i < n; i++)
            for (int c = 0; c < 3; c++)
                rgb[i * 3 + c] = negSrgbToLinear((float)p[i * 4 + c] / 255.0f);
    } else {
        const uint16_t *p = buf;
        for (size_t i = 0, n = w * h; i < n; i++)
            for (int c = 0; c < 3; c++)
                rgb[i * 3 + c] = (float)p[i * 4 + c] / 65535.0f;
    }
    free(buf);
    *outW = w; *outH = h;
    return rgb;
}

int negLoadFrame(const char *path, NegFrame *out,
                 char *enc, size_t encLen, char *err, size_t errLen) {
    if (!path || !out) return -1;
    memset(out, 0, sizeof(*out));
    int fromRaw = 0, bits = 8;
    double ev = 0.0;
    CGImageRef cg = loadCGImage(path, err, errLen, &fromRaw, &ev);
    if (!cg) return -1;
    size_t w = 0, h = 0;
    float *rgb = cgToLinearRGB(cg, &w, &h, &bits, err, errLen);
    CGImageRelease(cg);
    if (!rgb) return -1;

    if (enc && encLen) {
        if (fromRaw) {
            if (fabs(ev) >= 0.05)
                snprintf(enc, encLen, "相机 raw → 线性（防削顶，自动降 %.2f EV）", ev);
            else
                snprintf(enc, encLen, "相机 raw → 线性");
        } else if (bits <= 8) {
            snprintf(enc, encLen, "8-bit → 反解 sRGB 得线性");
        } else {
            snprintf(enc, encLen, "%d-bit → 视为线性", bits);
        }
    }
    out->rgb = rgb; out->w = w; out->h = h;
    return 0;
}

void negFreeFrame(NegFrame *f) {
    if (!f) return;
    free(f->rgb);
    f->rgb = NULL; f->w = f->h = 0;
}

NegFrame negDownsample(const NegFrame *src, size_t maxDim) {
    NegFrame d = {NULL, 0, 0};
    if (!src || !src->rgb || src->w == 0 || src->h == 0) return d;
    size_t longEdge = src->w > src->h ? src->w : src->h;
    if (longEdge <= maxDim) {
        d.rgb = malloc(sizeof(float) * src->w * src->h * 3);
        if (!d.rgb) return d;
        memcpy(d.rgb, src->rgb, sizeof(float) * src->w * src->h * 3);
        d.w = src->w; d.h = src->h;
        return d;
    }
    double s = (double)maxDim / (double)longEdge;
    size_t dw = (size_t)(src->w * s), dh = (size_t)(src->h * s);
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;
    d.rgb = malloc(sizeof(float) * dw * dh * 3);
    if (!d.rgb) return d;
    d.w = dw; d.h = dh;

    for (size_t y = 0; y < dh; y++) {
        size_t y0 = y * src->h / dh, y1 = (y + 1) * src->h / dh;
        if (y1 <= y0) y1 = y0 + 1;
        for (size_t x = 0; x < dw; x++) {
            size_t x0 = x * src->w / dw, x1 = (x + 1) * src->w / dw;
            if (x1 <= x0) x1 = x0 + 1;
            double acc[3] = {0, 0, 0};
            size_t cnt = 0;
            for (size_t yy = y0; yy < y1; yy++)
                for (size_t xx = x0; xx < x1; xx++) {
                    const float *p = src->rgb + (yy * src->w + xx) * 3;
                    acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2];
                    cnt++;
                }
            if (!cnt) cnt = 1;
            float *q = d.rgb + (y * dw + x) * 3;
            for (int c = 0; c < 3; c++) q[c] = (float)(acc[c] / (double)cnt);
        }
    }
    return d;
}

float negGreenPercentile(const float *rgb, size_t w, size_t h, double pct) {
    size_t n = w * h;
    if (!rgb || !n) return 0;
    float *g = malloc(sizeof(float) * n);
    if (!g) return 0;
    for (size_t i = 0; i < n; i++) g[i] = rgb[i * 3 + 1];
    float v = negPercentileFast(g, n, pct);   // 百万像素级必须走直方图
    free(g);
    return v;
}

unsigned char *negRGBA8(const float *rgb, size_t w, size_t h, float hi) {
    size_t n = w * h;
    if (!rgb || !n) return NULL;
    unsigned char *out = malloc(n * 4);
    if (!out) return NULL;
    double inv = (hi > 1e-9f) ? (1.0 / (double)hi) : 1.0 / 1e-9;
    for (size_t i = 0; i < n; i++)
        for (int c = 0; c < 3; c++) {
            double v = (double)rgb[i * 3 + c] * inv;
            if (v < 0) v = 0;
            if (v > 1) v = 1;
            out[i * 4 + c] = (unsigned char)(negLinearToSrgb((float)v) * 255.0f + 0.5f);
        }
    return out;
}

// 小规模插入排序取中位数。n ≤ (2·radius+1)²，radius 一般 ≤ 32，够用且没有分配。
static double medianOf(double *v, size_t n) {
    for (size_t i = 1; i < n; i++) {
        double k = v[i];
        size_t j = i;
        while (j > 0 && v[j - 1] > k) { v[j] = v[j - 1]; j--; }
        v[j] = k;
    }
    return v[n / 2];
}

void negSamplePatch(const NegFrame *f, double nx, double ny, int radius, double out[3]) {
    out[0] = out[1] = out[2] = 0;
    if (!f || !f->rgb || f->w == 0 || f->h == 0) return;
    if (radius < 1) radius = 1;
    if ((size_t)(2 * radius + 1) > f->w) radius = (int)((f->w - 1) / 2);
    if ((size_t)(2 * radius + 1) > f->h) radius = (int)((f->h - 1) / 2);

    long X = lround(nx * (double)f->w), Y = lround(ny * (double)f->h);
    if (X < radius) X = radius;
    if (Y < radius) Y = radius;
    if (X > (long)f->w - 1 - radius) X = (long)f->w - 1 - radius;
    if (Y > (long)f->h - 1 - radius) Y = (long)f->h - 1 - radius;
    if (X < 0 || Y < 0) return;

    size_t cap = (size_t)(2 * radius + 1) * (size_t)(2 * radius + 1);
    double *v = malloc(sizeof(double) * cap * 3);
    double *d = malloc(sizeof(double) * cap);
    double *tmp = malloc(sizeof(double) * cap);
    if (!v || !d || !tmp) { free(v); free(d); free(tmp); return; }

    size_t n = 0;
    for (long y = Y - radius; y <= Y + radius; y++)
        for (long x = X - radius; x <= X + radius; x++) {
            const float *p = f->rgb + ((size_t)y * f->w + (size_t)x) * 3;
            v[n * 3] = p[0]; v[n * 3 + 1] = p[1]; v[n * 3 + 2] = p[2];
            n++;
        }

    for (int round = 0; round < 3 && n > 16; round++) {
        double med[3];
        for (int c = 0; c < 3; c++) {
            for (size_t i = 0; i < n; i++) tmp[i] = v[i * 3 + c];
            med[c] = medianOf(tmp, n);
        }
        for (size_t i = 0; i < n; i++) {
            double a = v[i * 3] - med[0], b = v[i * 3 + 1] - med[1], c = v[i * 3 + 2] - med[2];
            d[i] = sqrt(a * a + b * b + c * c);
        }
        for (size_t i = 0; i < n; i++) tmp[i] = d[i];
        double cut = medianOf(tmp, n);           // 中位数就是 50% 分位，下面放宽到 60%
        for (size_t i = 0; i < n; i++) tmp[i] = d[i];
        for (size_t i = 1; i < n; i++) {         // 排序后取 60% 分位
            double k = tmp[i];
            size_t j = i;
            while (j > 0 && tmp[j - 1] > k) { tmp[j] = tmp[j - 1]; j--; }
            tmp[j] = k;
        }
        cut = tmp[(size_t)(0.6 * (double)(n - 1))];
        size_t m = 0;
        for (size_t i = 0; i < n; i++)
            if (d[i] <= cut) {
                v[m * 3] = v[i * 3]; v[m * 3 + 1] = v[i * 3 + 1]; v[m * 3 + 2] = v[i * 3 + 2];
                m++;
            }
        if (m >= 16) n = m;
    }
    for (int c = 0; c < 3; c++) {
        for (size_t i = 0; i < n; i++) tmp[i] = v[i * 3 + c];
        out[c] = medianOf(tmp, n);
    }
    free(v); free(d); free(tmp);
}

static int writeImage(const char *path, CGImageRef cg, CFStringRef type,
                      CFDictionaryRef props, char *err, size_t errLen) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, type, 1, NULL);
    if (!dest) { setErr(err, errLen, @"建不了输出文件（路径不可写？）"); return -1; }
    CGImageDestinationAddImage(dest, cg, props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    if (!ok) { setErr(err, errLen, @"写文件失败"); return -1; }
    return 0;
}

// 把 float 缓冲包成 16-bit CGImage。上下文用 **LinearSRGB**（不能用扩展版，
// 见 pickIntSpace 的说明）：数据本来就是线性的，非扩展版传输函数相同，
// 只是少了超出范围的部分。原来用扩展线性 sRGB 建上下文，这里必然失败 ——
// 也就是「导出 16-bit TIFF」一直是坏的。
static CGImageRef wrap16(const float *rgb, size_t w, size_t h, float hi) {
    size_t bpr = w * 4 * 2;
    uint16_t *buf = malloc(h * bpr);
    if (!buf) return NULL;
    double inv = (hi > 1e-9f) ? (1.0 / (double)hi) : 1.0 / 1e-9;
    size_t n = w * h;
    for (size_t i = 0; i < n; i++)
        for (int c = 0; c < 3; c++) {
            double v = (double)rgb[i * 3 + c] * inv;
            if (v < 0) v = 0;
            if (v > 1) v = 1;
            buf[i * 4 + c] = (uint16_t)(v * 65535.0 + 0.5);
        }
    CGColorSpaceRef lin = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 16, bpr, lin,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipLast |
                                             kCGBitmapByteOrder16Little);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(lin);
    free(buf);
    return cg;
}

int negSaveLinearTIFF(const char *path, const float *rgb, size_t w, size_t h,
                      float hi, char *err, size_t errLen) {
    CGImageRef cg = wrap16(rgb, w, h, hi);
    if (!cg) { setErr(err, errLen, @"内存不够"); return -1; }
    NSDictionary *props = @{ (id)kCGImagePropertyTIFFCompression: @1 };
    int r = writeImage(path, cg, CFSTR("public.tiff"),
                       (__bridge CFDictionaryRef)props, err, errLen);
    CGImageRelease(cg);
    return r;
}

int negSaveDisplay8(const char *path, const float *rgb, size_t w, size_t h,
                    float hi, char *err, size_t errLen) {
    unsigned char *rgba = negRGBA8(rgb, w, h, hi);
    if (!rgba) { setErr(err, errLen, @"内存不够"); return -1; }
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, srgb,
                                             kCGImageAlphaNoneSkipLast);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(srgb);
    free(rgba);
    if (!cg) { setErr(err, errLen, @"建不出图像"); return -1; }

    const char *e = strrchr(path, '.');
    CFStringRef type = CFSTR("public.jpeg");
    NSDictionary *props = @{ (id)kCGImageDestinationLossyCompressionQuality: @0.95 };
    if (e && e[1]) {
        if (!strcasecmp(e + 1, "png")) { type = CFSTR("public.png"); props = @{}; }
        else if (!strcasecmp(e + 1, "tif") || !strcasecmp(e + 1, "tiff")) {
            type = CFSTR("public.tiff"); props = @{ (id)kCGImagePropertyTIFFCompression: @1 };
        }
    }
    int r = writeImage(path, cg, type, (__bridge CFDictionaryRef)props, err, errLen);
    CGImageRelease(cg);
    return r;
}
