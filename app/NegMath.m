// NegMath.m —— 见 NegMath.h
#import "NegMath.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

float negSrgbToLinear(float x) {
    if (x <= 0.04045f) return x / 12.92f;
    return powf((x + 0.055f) / 1.055f, 2.4f);
}

float negLinearToSrgb(float x) {
    if (x <= 0.0031308f) return x * 12.92f;
    return 1.055f * powf(x, 1.0f / 2.4f) - 0.055f;
}

// ── 对称 3×3 的 Jacobi 特征分解 ─────────────────────────────────────────────
// 用来做 N×3 矩阵的秩 1 分解：右奇异向量就是 M = CᵀC 的特征向量，
// 奇异值是特征值的平方根。手写是为了不引入 LAPACK。
// a 为 3×3 对称阵（行主序）；输出特征值 ev[3]（降序）与特征向量 vec[3][3]（按列）。
static void jacobi3(double a[3][3], double ev[3], double vec[3][3]) {
    double A[3][3];
    memcpy(A, a, sizeof(A));
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) vec[i][j] = (i == j) ? 1.0 : 0.0;

    for (int sweep = 0; sweep < 24; sweep++) {
        double off = fabs(A[0][1]) + fabs(A[0][2]) + fabs(A[1][2]);
        if (off < 1e-15) break;
        for (int p = 0; p < 2; p++) {
            for (int q = p + 1; q < 3; q++) {
                if (fabs(A[p][q]) < 1e-18) continue;
                double theta = (A[q][q] - A[p][p]) / (2.0 * A[p][q]);
                double t = (theta >= 0 ? 1.0 : -1.0) /
                           (fabs(theta) + sqrt(theta * theta + 1.0));
                double c = 1.0 / sqrt(t * t + 1.0), s = t * c;
                for (int k = 0; k < 3; k++) {
                    double akp = A[k][p], akq = A[k][q];
                    A[k][p] = c * akp - s * akq;
                    A[k][q] = s * akp + c * akq;
                }
                for (int k = 0; k < 3; k++) {
                    double apk = A[p][k], aqk = A[q][k];
                    A[p][k] = c * apk - s * aqk;
                    A[q][k] = s * apk + c * aqk;
                }
                for (int k = 0; k < 3; k++) {
                    double vkp = vec[k][p], vkq = vec[k][q];
                    vec[k][p] = c * vkp - s * vkq;
                    vec[k][q] = s * vkp + c * vkq;
                }
            }
        }
    }
    ev[0] = A[0][0]; ev[1] = A[1][1]; ev[2] = A[2][2];
    for (int i = 0; i < 2; i++)                       // 降序
        for (int j = i + 1; j < 3; j++)
            if (ev[j] > ev[i]) {
                double tt = ev[i]; ev[i] = ev[j]; ev[j] = tt;
                for (int k = 0; k < 3; k++) {
                    tt = vec[k][i]; vec[k][i] = vec[k][j]; vec[k][j] = tt;
                }
            }
}

// 单点：T → Pi → L（含 t0 归一与逐通道 γ/o）
static inline void negLCoord(const float *px, const double t0[3],
                             const double gamma[3], const double offset[3], double L[3]) {
    for (int c = 0; c < 3; c++) {
        double T = (double)px[c] / (t0[c] > 1e-9 ? t0[c] : 1e-9);
        if (T < 1e-7) T = 1e-7;
        if (T > 1.0)  T = 1.0;
        L[c] = (-log10(T) - offset[c]) / (fabs(gamma[c]) > 1e-9 ? gamma[c] : 1.0);
    }
}

int negFitGamma(const float *samples, int n, const double t0[3], NegCal *out) {
    if (n < 2 || !samples || !t0 || !out) return -1;

    // 1) Pi = −log10( T / t0 )，同时累加列均值
    double *PP = malloc(sizeof(double) * (size_t)n * 3);
    if (!PP) return -1;
    double mean[3] = {0, 0, 0};
    for (int i = 0; i < n; i++)
        for (int c = 0; c < 3; c++) {
            double T = (double)samples[i * 3 + c] / (t0[c] > 1e-9 ? t0[c] : 1e-9);
            if (T < 1e-7) T = 1e-7;
            PP[i * 3 + c] = -log10(T);
            mean[c] += PP[i * 3 + c];
        }
    for (int c = 0; c < 3; c++) mean[c] /= n;

    // 2) 去列均值 → CᵀC
    double M[3][3] = {{0}};
    for (int i = 0; i < n; i++) {
        double p[3];
        for (int c = 0; c < 3; c++) p[c] = PP[i * 3 + c] - mean[c];
        for (int a = 0; a < 3; a++)
            for (int b = 0; b < 3; b++) M[a][b] += p[a] * p[b];
    }

    // 3) 特征分解 → 第一右奇异向量
    double ev[3], vec[3][3];
    jacobi3(M, ev, vec);
    double sig1 = sqrt(ev[0] > 0 ? ev[0] : 0);
    double sig2 = sqrt(ev[1] > 0 ? ev[1] : 0);
    double g[3] = {vec[0][0], vec[1][0], vec[2][0]};
    if (g[1] < 0) { g[0] = -g[0]; g[1] = -g[1]; g[2] = -g[2]; }
    if (fabs(g[1]) < 1e-12) { free(PP); return -1; }

    out->gamma[0] = g[0] / g[1];
    out->gamma[1] = 1.0;
    out->gamma[2] = g[2] / g[1];
    for (int c = 0; c < 3; c++) out->offset[c] = mean[c];
    out->lRef = -(out->offset[0] / out->gamma[0] +
                  out->offset[1] / out->gamma[1] +
                  out->offset[2] / out->gamma[2]) / 3.0;
    out->sigmaRatio = (sig1 > 1e-15) ? (sig2 / sig1) : 0.0;

    // 4) 秩 1 残差（密度）：C 与 L⊗g 的最大差
    double resid = 0.0;
    for (int i = 0; i < n; i++) {
        double L = (PP[i * 3 + 1] - mean[1]) / g[1];
        for (int c = 0; c < 3; c++) {
            double d = fabs((PP[i * 3 + c] - mean[c]) - L * g[c]);
            if (d > resid) resid = d;
        }
    }
    free(PP);

    out->residD = resid;
    out->n = n;
    return 0;
}

// 第二层：2383 印片观感（近似）。
// 输入是第一层产出的线性亮度 v。2383 公开 H&D 曲线的形状是：
//   趾部 logE<0.2 不感光，直线段 0.2..1.2 斜率≈3，肩部 >2.0 饱和于 D≈4。
// 印片曝光与场景亮度的关系是 logE_p = c + x（x = −log10 v）—— 场景越暗负片越透、
// 印片曝光越大、印片越黑。c 是印片机的曝光旋钮，这里取 0.15，绝对位置交给用户的曝光滑杆。
// ★ 这是观感近似，不是物理模拟：用的是三通道平均曲线（逐通道会引入偏色，
//   除非采集链与 2383 的分光严格互逆）。物理级模拟见 docs 里刘磊那篇。
static float negPrintLook(float v) {
    if (v <= 1e-7f) return 0.0f;
    double x = -log10((double)v);
    double logE = 0.15 + x;
    double D;
    if (logE <= 0.0)      D = 0.0;
    else if (logE >= 2.0) D = 4.0;
    else                  D = 2.6 * logE;
    return (float)pow(10.0, -D);
}

void negInvert(float *buf, size_t length,
               const double t0[3], const double gamma[3], const double offset[3],
               double lRef, double piClip, int paper) {
    if (!buf) return;
    if (piClip <= 0) piClip = NEG_PI_CLIP_DEFAULT;
    double loT = pow(10.0, -piClip);
    for (size_t i = 0; i < length; i++) {
        float *px = buf + i * 3;
        for (int c = 0; c < 3; c++) {
            double T = (double)px[c] / (t0[c] > 1e-9 ? t0[c] : 1e-9);
            if (T > 1.0) T = 1.0;
            if (T < loT) T = loT;
            double L = (-log10(T) - offset[c]) / (fabs(gamma[c]) > 1e-9 ? gamma[c] : 1.0);
            L -= lRef;
            if (L < 0) L = 0;
            double out = pow(10.0, L / NEG_GAMMA_OUT) - 1.0;   // 第一层：线性母版
            if (out < 0) out = 0;
            if (paper == NEG_PAPER_PRINT) out = negPrintLook(out);  // 第二层：印片观感
            px[c] = (float)out;
        }
    }
}

double negNeutralResidual(const float *samples, int n,
                          const double t0[3], const double gamma[3],
                          const double offset[3]) {
    if (n < 1 || !samples) return 0;
    const double k = NEG_GAMMA_OUT / log10(2.0);   // = 0.6 / log10(2) ≈ 1.99316
    double worst = 0;
    for (int i = 0; i < n; i++) {
        double L[3];
        negLCoord(samples + i * 3, t0, gamma, offset, L);
        for (int c = 0; c < 3; c++) {
            double d = fabs(L[c] - L[1]) * k;
            if (d > worst) worst = d;
        }
    }
    return worst;
}

static int cmp_float(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x < y) ? -1 : (x > y ? 1 : 0);
}

float negPercentile(const float *v, size_t n, double pct) {
    if (!v || n == 0) return 0;
    float *copy = malloc(sizeof(float) * n);
    if (!copy) return 0;
    memcpy(copy, v, sizeof(float) * n);
    qsort(copy, n, sizeof(float), cmp_float);
    double idx = (pct / 100.0) * (double)(n - 1);
    if (idx < 0) idx = 0;
    if (idx > (double)(n - 1)) idx = (double)(n - 1);
    size_t i0 = (size_t)floor(idx), i1 = (size_t)ceil(idx);
    float r = copy[i0] + (float)(idx - (double)i0) * (copy[i1] - copy[i0]);
    free(copy);
    return r;
}

// 直方图法。图像的百分位动辄要过千万个像素，排序法太慢；
// 而显示映射和零点只需要五六位有效数字，65536 个箱足够。
//
// ★ 第一版把取值截到 [0,1] 再进箱 —— 那对「线性透过率」成立，对「反相之后的
//   输出」完全不成立：输出可以到上万，全挤进最后一个箱，百分位于是算成 1.0，
//   整幅图会被打白。所以这里先扫一遍定出真实的值域，再按值域分箱。
float negPercentileFast(const float *v, size_t n, double pct) {
    if (!v || n == 0) return 0;
    float lo = v[0], hi = v[0];
    for (size_t i = 1; i < n; i++) {
        float x = v[i];
        if (x < lo) lo = x;
        if (x > hi) hi = x;
    }
    double span = (double)hi - (double)lo;
    if (!(span > 0)) return hi;

    enum { BINS = 65536 };
    unsigned *h = calloc(BINS, sizeof(unsigned));
    if (!h) return negPercentile(v, n, pct);
    double scale = (double)(BINS - 1) / span;
    for (size_t i = 0; i < n; i++) {
        int b = (int)(((double)v[i] - (double)lo) * scale + 0.5);
        if (b < 0) b = 0;
        if (b >= BINS) b = BINS - 1;
        h[b]++;
    }
    double need = (pct / 100.0) * (double)(n - 1);
    double acc = 0;
    float r = hi;
    for (int b = 0; b < BINS; b++) {
        if (acc + (double)h[b] > need) {
            double frac = (double)(need - acc) / (double)(h[b] ? h[b] : 1);
            r = (float)((double)lo + ((double)b + frac) / scale);
            break;
        }
        acc += h[b];
        r = (float)((double)lo + (double)b / scale);
    }
    free(h);
    return r;
}

// 3×3 中值。去孤立亮点 —— 热噪点会让「最亮 0.05%」的均值显著偏高，
// 而零点偏高的代价是整幅密度偏低、色罩没去干净。
static void median3x3(const float *src, float *dst, size_t w, size_t h) {
    for (size_t y = 0; y < h; y++) {
        long y0 = (long)y - 1, y1 = (long)y + 1;
        if (y0 < 0) y0 = 0;
        if (y1 > (long)h - 1) y1 = (long)h - 1;
        for (size_t x = 0; x < w; x++) {
            long x0 = (long)x - 1, x1 = (long)x + 1;
            if (x0 < 0) x0 = 0;
            if (x1 > (long)w - 1) x1 = (long)w - 1;
            for (int c = 0; c < 3; c++) {
                float v[9];
                int n = 0;
                for (long yy = y0; yy <= y1; yy++)
                    for (long xx = x0; xx <= x1; xx++)
                        v[n++] = src[((size_t)yy * w + (size_t)xx) * 3 + c];
                for (int i = 1; i < 9; i++) {          // 9 个元素，插入排序
                    float k = v[i];
                    int j = i;
                    while (j > 0 && v[j - 1] > k) { v[j] = v[j - 1]; j--; }
                    v[j] = k;
                }
                dst[(y * w + x) * 3 + c] = v[4];
            }
        }
    }
}

void negEstimateZero(const float *rgb_in, size_t w, size_t h, double topFrac, double t0[3]) {
    t0[0] = t0[1] = t0[2] = 1.0;
    if (!rgb_in || !w || !h || !t0) return;
    if (topFrac <= 0 || topFrac > 0.5) topFrac = 0.0005;

    // ★ 片基是大面积属性，不需要全分辨率：超过 2MP 就先做 2×2 盒式降采样。
    //   36MP 上把 3×3 中值从数秒压到零点几秒；均值面积更大，估计也更稳。
    //   降采样在函数内做，避免 NegMath 反向依赖 NegImage 的 negDownsample。
    const float *rgb = rgb_in;
    float *own = NULL;
    while ((double)w * (double)h > 2.0e6) {
        size_t nw = w / 2, nh = h / 2;
        if (nw < 2 || nh < 2) break;
        float *d = malloc(sizeof(float) * nw * nh * 3);
        if (!d) break;
        for (size_t y = 0; y < nh; y++)
            for (size_t x = 0; x < nw; x++)
                for (int c = 0; c < 3; c++)
                    d[(y * nw + x) * 3 + c] = 0.25f *
                        (rgb[(y * 2 * w + x * 2) * 3 + c] +
                         rgb[(y * 2 * w + x * 2 + 1) * 3 + c] +
                         rgb[((y * 2 + 1) * w + x * 2) * 3 + c] +
                         rgb[((y * 2 + 1) * w + x * 2 + 1) * 3 + c]);
        if (own) free(own);
        rgb = d; own = d; w = nw; h = nh;
    }

    size_t n = w * h;

    float *sm = malloc(sizeof(float) * n * 3);
    if (!sm) { if (own) free(own); return; }
    median3x3(rgb, sm, w, h);

    float *ch = malloc(sizeof(float) * n);
    if (!ch) { free(sm); if (own) free(own); return; }
    for (int c = 0; c < 3; c++) {
        for (size_t i = 0; i < n; i++) ch[i] = sm[i * 3 + c];
        // 直方图求出「最亮 topFrac」的下界，再一趟求和取均值（都是 O(n)）
        float thr = negPercentileFast(ch, n, 100.0 * (1.0 - topFrac));
        double sum = 0;
        size_t m = 0;
        for (size_t i = 0; i < n; i++)
            if (ch[i] >= thr) { sum += ch[i]; m++; }
        double v = m ? (sum / (double)m) : (double)thr;
        t0[c] = (v > 1e-6) ? v : 1e-6;
    }
    free(ch);
    free(sm);
    if (own) free(own);
}
