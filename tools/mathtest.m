// mathtest.m —— NegLab 数学核心自检（对应原先的 tools/verify.py）
//
// 编译：clang -O2 -o mathtest mathtest.m ../app/NegMath.m -lm
// 运行：./mathtest      退出码 0 = 全部通过
//
// 五项里每一项都对应一个曾经踩过的坑，注释写的就是那个坑。
#import "../app/NegMath.h"
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

// 真值：从第六轮起固定用它造合成负片（与 docs/calibration.json 的实测值同源）
static const double GAMMA_TRUE[3] = {0.9331, 1.0, 1.6264};
static const double BASE_D[3] = {0.0969, 0.3188, 0.7212};   // −log10(0.80 / 0.48 / 0.19)

// 真实标定：gold200/000364980009.TIF 里量出来的（见 docs/calibration.json）
static const double CAL_DMIN[3] = {0.8083, 0.4833, 0.18947};
static const float  CAL_GREY[18] = {
    0.13563f,0.07421f,0.01229f,  0.14413f,0.07819f,0.01370f,
    0.18447f,0.09990f,0.02122f,  0.24228f,0.13843f,0.03820f,
    0.32778f,0.19120f,0.06480f,  0.50888f,0.30054f,0.11444f };

// 按 D = base + γ·L 造一帧；第 0 行是零点（片基）。输出透过率，n×3 行主序。
static void synth(double L0, const double *Ls, int n, float *out) {
    for (int i = 0; i < n; i++) {
        double L = (i == 0) ? L0 : Ls[i];
        for (int c = 0; c < 3; c++)
            out[i * 3 + c] = (float)pow(10.0, -(BASE_D[c] + GAMMA_TRUE[c] * L));
    }
}

// 输出里三通道之间的最大散差（档）——只统计三通道都还没塌到 0 的行。
// ★ 片基那一行反相后恰好是 0，对它取 log2 会得到假的天文数字。这个坑踩过三次。
static double devStops(const float *b, int n) {
    double worst = 0;
    for (int i = 0; i < n; i++) {
        if (!(b[i*3] > 1e-6 && b[i*3+1] > 1e-6 && b[i*3+2] > 1e-6)) continue;
        double v[3];
        for (int c = 0; c < 3; c++) v[c] = log2(b[i * 3 + c]);
        for (int c = 0; c < 3; c++) {
            double d = fabs(v[c] - v[1]);
            if (d > worst) worst = d;
        }
    }
    return worst;
}

int main(void) {
    int pass = 0, total = 5;
    printf("========================================================\n");
    printf("NegLab 数学核心自检\n");
    printf("========================================================\n");

    // ── ① 合成往返 ────────────────────────────────────────────────────────
    {
        printf("\n① 合成往返（给定 γ，看能不能精确解回来）\n");
        double L[9]; for (int i = 0; i < 9; i++) L[i] = -0.8 + i * 0.2;
        float S[27]; synth(-0.8, L, 9, S);
        double t0[3]; for (int c = 0; c < 3; c++) t0[c] = S[c];
        NegCal cal;
        if (negFitGamma(S, 9, t0, &cal) == 0) {
            printf("   真值 γ = %.4f, %.4f, %.4f\n", GAMMA_TRUE[0], GAMMA_TRUE[1], GAMMA_TRUE[2]);
            printf("   解出 γ = %.6f, %.6f, %.6f   σ2/σ1 = %.2e%%   残差 = %.2e D\n",
                   cal.gamma[0], cal.gamma[1], cal.gamma[2], cal.sigmaRatio * 100, cal.residD);
            int ok = fabs(cal.gamma[0]-GAMMA_TRUE[0]) < 1e-3 &&
                     fabs(cal.gamma[2]-GAMMA_TRUE[2]) < 1e-3 &&
                     cal.sigmaRatio < 1e-4 && cal.residD < 1e-6;
            printf("   %s\n", ok ? "✅ 精确还原" : "✗ 与真值不符");
            pass += ok;
        } else printf("   ✗ 拟合失败\n");
    }

    // ── ② 跨帧代数 ────────────────────────────────────────────────────────
    {
        printf("\n② 代数自检：跨帧要不要给偏移做平移？（结论：不需要，而且平移是错的）\n");
        double Ls[5] = {-0.55, -0.40, -0.25, -0.10, 0.05};
        float A[15]; synth(-0.55, Ls, 5, A);
        double tA[3]; for (int c = 0; c < 3; c++) tA[c] = A[c];
        NegCal cal; negFitGamma(A, 5, tA, &cal);
        printf("   A 帧解出 o = %.4f, %.4f, %.4f   o/γ = %.4f, %.4f, %.4f   L_ref = %.4f\n",
               cal.offset[0], cal.offset[1], cal.offset[2],
               cal.offset[0]/cal.gamma[0], cal.offset[1]/cal.gamma[1],
               cal.offset[2]/cal.gamma[2], cal.lRef);
        int ok = 1;
        const char *nm[3] = {"片基在画面里", "最亮处稍欠曝", "最亮处过曝"};
        double l0s[3] = {-0.55, -0.35, -0.75};
        for (int k = 0; k < 3; k++) {
            float B[15]; synth(l0s[k], Ls, 5, B);
            double t0b[3];
            for (int c = 0; c < 3; c++)
                t0b[c] = pow(10.0, -(BASE_D[c] + GAMMA_TRUE[c] * l0s[k]));
            negInvert(B, 5, t0b, GAMMA_TRUE, cal.offset, cal.lRef, 1.0, 0.0, 0.0);
            double d = devStops(B, 5);
            printf("     %-14s L0=%+.2f  输出最大通道差 = %.8f 档  %s\n",
                   nm[k], l0s[k], d, d < 1e-5 ? "✅" : "✗");
            if (d >= 1e-5) ok = 0;
        }
        printf("   → o 与 L_ref 是常数、不该动；每帧零点通过 Pi 自己进去，天然中性。\n");
        pass += ok;
    }

    // ── ③ 真实标定 ────────────────────────────────────────────────────────
    {
        printf("\n③ 真实色卡：用 dmin 当零点解 γ，并做六点中性验收\n");
        NegCal cal; int r = negFitGamma(CAL_GREY, 6, CAL_DMIN, &cal);
        if (r == 0) {
            printf("   γ = %.4f : 1 : %.4f   σ2/σ1 = %.2f%%   秩 1 残差 = %.4f D\n",
                   cal.gamma[0], cal.gamma[2], cal.sigmaRatio * 100, cal.residD);
            double res = negNeutralResidual(CAL_GREY, 6, CAL_DMIN, cal.gamma, cal.offset);
            printf("   六点中性残差 = %.4f 档（阈值 0.15）\n", res);
            int ok = fabs(cal.gamma[0]-0.9331) < 5e-3 &&
                     fabs(cal.gamma[2]-1.6264) < 5e-3 &&
                     fabs(cal.residD-0.0397) < 1e-3 && res < 0.15;
            printf("   %s\n", ok ? "✅ 与第八轮实测一致（γ=0.9331:1:1.6264，残差 0.0486 档）"
                                : "✗ 与实测不一致");
            pass += ok;
        } else printf("   ✗ 拟合失败\n");
    }

    // ── ④ 密度上限 ────────────────────────────────────────────────────────
    {
        printf("\n④ 密度上限 PI_CLIP 会制造多少「假偏色」\n");
        double L[12]; for (int i = 0; i < 12; i++) L[i] = -0.3 + i * (1.3 / 11);
        float S[36]; synth(-0.3, L, 12, S);
        double t0[3]; for (int c = 0; c < 3; c++) t0[c] = S[c];
        double zero[3] = {0,0,0};
        // ★ 必须用真值 γ 反相。用 γ=1 的话三通道本来就差着 4.5 档，
        //   量出来的是「没标定」，不是「截断造成的」。
        double d18, d25, d99;
        float B[36];
        memcpy(B,S,sizeof(B)); negInvert(B,12,t0,GAMMA_TRUE,zero,0,1.0,0.0,1.8); d18 = devStops(B,12);
        memcpy(B,S,sizeof(B)); negInvert(B,12,t0,GAMMA_TRUE,zero,0,1.0,0.0,2.5); d25 = devStops(B,12);
        memcpy(B,S,sizeof(B)); negInvert(B,12,t0,GAMMA_TRUE,zero,0,1.0,0.0,99.0); d99 = devStops(B,12);
        printf("   PI_CLIP=1.8   输出最大通道差 = %8.4f 档\n", d18);
        printf("   PI_CLIP=2.5   输出最大通道差 = %8.4f 档\n", d25);
        printf("   PI_CLIP=99    输出最大通道差 = %8.4f 档\n", d99);
        int ok = fabs(d18-1.081) < 0.01 && d25 < 1e-6 && d99 < 1e-6;
        printf("   → 截断逐通道分别生效：1.8 时多出 1.081 档假偏色，2.5 时不截断。%s\n",
               ok ? "✅ 默认取 2.5" : "✗");
        pass += ok;
    }

    // ── ⑤ 单调性 ──────────────────────────────────────────────────────────
    {
        printf("\n⑤ invert() 的单调性与像素逐通道一致\n");
        float S[30]; for (int i = 0; i < 10; i++)
            for (int c = 0; c < 3; c++) S[i*3+c] = 0.01f + i * 0.11f;
        double t0[3] = {1.0,1.0,1.0}, one[3] = {1.0,1.0,1.0}, zero[3] = {0,0,0};
        negInvert(S, 10, t0, one, zero, 0, 1.0, 0.0, 2.5);
        int mono = 1;
        for (int i = 1; i < 10; i++) if (S[i*3+1] > S[(i-1)*3+1] + 1e-6) mono = 0;
        printf("   输出（绿通道）= ");
        for (int i = 0; i < 10; i++) printf("%.4f ", S[i*3+1]);
        printf("\n   单调递减：%s\n", mono ? "✅" : "✗");
        pass += mono;
    }

    printf("\n========================================================\n");
    printf("总结：%s（%d/%d）\n", pass == total ? "✅ 全部通过" : "⚠️ 有项目未通过", pass, total);
    printf("========================================================\n");
    return pass == total ? 0 : 1;
}
