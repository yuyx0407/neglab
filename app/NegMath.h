// NegMath.h —— NegLab 的全部数学。纯 C，无第三方依赖。
//
// 三行核心：
//   Pi_c  = −log10( clip( T_c / T0_c ) )        负片相对零点的密度
//   L_c   = ( Pi_c − o_c ) / γ_c                逐通道曝光坐标
//   out_c = 10^( (L_c − L_ref) / 0.6 ) − 1      反相
//
// 三个参数各有各的更新频率：
//   T0   零点   每帧都要重定（点片基最准，或取画面最亮的那 0.05%）
//   γ, o 斜率与偏移   一次性的，管一个「胶片型号 × 扫描/翻拍链路」
//
// γ 与 o 由「点若干块中性灰」经秩 1 分解解出：
//   Pi_c(k) = o_c + γ_c · L_k      →   去掉列均值后，N×3 矩阵应当秩 1
// 第二奇异值占比 σ2/σ1 就是「这批点够不够中性」的读数。
#ifndef NEGMATH_H
#define NEGMATH_H

#include <stddef.h>

// 输出端固定的印片 γ（柯达 Cineon 的负片 γ，见 docs/参考文献.md）
#define NEG_GAMMA_OUT 0.6

// 密度上限。取 2.5：截断是逐通道分别生效的，取 1.8 会平白削出最多 1.08 档假偏色，
// 取 2.5 时该值为 0。见 tools/mathtest.m 第 ④ 项。
#define NEG_PI_CLIP_DEFAULT 2.5

typedef struct {
    double gamma[3];      // 逐通道斜率比，绿通道归一为 1
    double offset[3];     // 逐通道偏移（只在与其同时解出的那个零点下有效）
    double lRef;          // 黑点锚 = mean(−o_c / γ_c)
    double sigmaRatio;    // σ2/σ1，越小说明这批点越中性
    double residD;        // 秩 1 残差，密度单位
    int    n;             // 参与拟合的点数
} NegCal;

// sRGB 传输函数
float negSrgbToLinear(float x);
float negLinearToSrgb(float x);

// 秩 1 分解。samples: n×3 的线性透过率；t0: 与之配套的零点（3 个值）。
// 返回 0 成功，-1 点数不足或退化。
int negFitGamma(const float *samples, int n, const double t0[3], NegCal *out);

// 反相一整块 RGB float 缓冲（原地）。length = 像素数。
enum { NEG_PAPER_LINEAR = 0, NEG_PAPER_PRINT = 1 };

// paper: NEG_PAPER_LINEAR = 线性母版（10^(L/0.6)−1，供后续分级）；
//        NEG_PAPER_PRINT  = 在母版之上再过一道 2383 印片观感（见 NegMath.m 的说明）。
void negInvert(float *buf, size_t length, const double t0[3], const double gamma[3],
               const double offset[3], double lRef, double piClip, int paper);

// 中性残差：给定点上三通道曝光坐标的最大散差，换算成「档」。
//   ΔL × 0.6 / log10(2)     即「以 0.6 印片 γ 计的输出密度差，折合成档」
// 这个量不会因为某个通道被压到 0 而炸掉，因此可以当验收指标用。
// 阈值 0.15 档：超了说明这些点不是真中性 / 零点不对 / 卡拍得不正。
double negNeutralResidual(const float *samples, int n,
                          const double t0[3], const double gamma[3],
                          const double offset[3]);

// 自动估零点（片基）。做法与 Python 参考实现一致：
//   ① 3×3 中值预滤波，压掉热噪点与颗粒 —— 它们是「片基估偏高」的首要来源；
//   ② 取每通道最亮 topFrac 的**均值**（默认 0.0005 = 最亮的 0.05%）。
// 零点 -log10 之后就是密度，所以它对结果的影响是全流程里最大的一处：
// 估高一倍，输出能差 5～10 档。宁可手动点片基。
void negEstimateZero(const float *rgb, size_t w, size_t h, double topFrac, double t0[3]);

// 百分位（0..100），不修改输入。exact = 排序法，元素少时用。
float negPercentile(const float *v, size_t n, double pct);
// 同上，但走直方图（O(n)，精度约 1/65535）。图像尺度（百万像素以上）必须用这个。
float negPercentileFast(const float *v, size_t n, double pct);

#endif
