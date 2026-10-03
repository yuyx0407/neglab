// calib_cli.m —— 无界面的标定 / 批量反相工具。
//
// 它和 NegLab.app 走的是同一套解码（NegImage）与同一套数学（NegMath），
// 所以拿它跟 Python 参考实现逐位对照，就能证明界面那条路没走偏；
// 同时它自己也是「整卷批处理」的入口。
//
// 编译：clang -O2 -fobjc-arc -Wno-deprecated-declarations \
//        -framework Foundation -framework CoreImage -framework ImageIO \
//        -framework CoreGraphics -o calib_cli calib_cli.m ../app/NegImage.m ../app/NegMath.m
//
// 用法：
//   ./calib_cli --selftest
//   ./calib_cli <负片> <半径> "x1,y1;x2,y2;..."      # 在一组归一化坐标上解 γ
//   ./calib_cli --render <负片> <标定.json> <输出.tif|.jpg|.png> [--ev X] [--black Y]
#import <Foundation/Foundation.h>
#include "../app/NegImage.h"
#include "../app/NegMath.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// 造合成负片：D = base + γ·L，第 0 行给 L0（零点）。返回透过率。
static const double GAMMA_TRUE[3] = {0.9331, 1.0, 1.6264};
static const double BASE_D[3] = {0.0969, 0.3188, 0.7212};

// 显示映射的白点百分位。和 app 里保持一致，否则「所见非所得」。
static const double DISP_PCT = 99.9;

static void synth(double L0, const double *Ls, int n, float *out) {
    for (int i = 0; i < n; i++) {
        double L = (i == 0) ? L0 : Ls[i];
        for (int c = 0; c < 3; c++)
            out[i * 3 + c] = (float)pow(10.0, -(BASE_D[c] + GAMMA_TRUE[c] * L));
    }
}

// 读标定 json。返回 0 成功。
static int loadCalib(const char *path, double gamma[3], double offset[3], double *lRef) {
    NSData *d = [NSData dataWithContentsOfFile:@(path)];
    if (!d) return -1;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSArray *g = j[@"gamma"];
    if (!g) return -1;
    gamma[0] = [g[0] doubleValue]; gamma[1] = 1.0; gamma[2] = [g[2] doubleValue];
    NSArray *o = j[@"offset"];
    for (int c = 0; c < 3; c++) offset[c] = o ? [o[c] doubleValue] : 0.0;
    *lRef = j[@"L_base"] ? [j[@"L_base"] doubleValue] : 0.0;
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--selftest")) {
            // 拿合成负片跑一遍：解出的 γ 应当等于真值
            printf("── 合成负片自检 ──\n");
            double Ls[8];
            for (int i = 0; i < 8; i++) Ls[i] = -0.4 + i * 0.25;
            float S[24];
            synth(-0.4, Ls, 8, S);
            double t0[3];
            for (int c = 0; c < 3; c++) t0[c] = S[c];
            NegCal cal;
            if (negFitGamma(S, 8, t0, &cal) != 0) { printf("✗ 拟合失败\n"); return 1; }
            printf("   真值 γ = %.4f : 1 : %.4f\n", GAMMA_TRUE[0], GAMMA_TRUE[2]);
            printf("   解出 γ = %.6f : 1 : %.6f   σ₂/σ₁ = %.2e%%\n",
                   cal.gamma[0], cal.gamma[2], cal.sigmaRatio * 100);
            double res = negNeutralResidual(S, 8, t0, cal.gamma, cal.offset);
            printf("   中性残差 = %.6f 档\n", res);
            int ok = fabs(cal.gamma[0] - GAMMA_TRUE[0]) < 1e-3 &&
                     fabs(cal.gamma[2] - GAMMA_TRUE[2]) < 1e-3 && res < 1e-6;
            printf("   %s\n", ok ? "✅" : "✗");
            return ok ? 0 : 1;
        }

        // ── --render：整卷批处理的入口 ────────────────────────────────────
        if (argc >= 5 && !strcmp(argv[1], "--render")) {
            const char *inPath = argv[2], *calPath = argv[3], *outPath = argv[4];
            double ev = 0.0, black = 0.0;
            double baseX = -1, baseY = -1;
            for (int i = 5; i + 1 < argc; i += 2) {
                if (!strcmp(argv[i], "--ev")) ev = atof(argv[i + 1]);
                else if (!strcmp(argv[i], "--black")) black = atof(argv[i + 1]);
                else if (!strcmp(argv[i], "--base")) sscanf(argv[i + 1], "%lf,%lf", &baseX, &baseY);
            }
            double gamma[3], offset[3], lRef;
            if (loadCalib(calPath, gamma, offset, &lRef) != 0) {
                printf("✗ 读不了标定：%s\n", calPath);
                return 1;
            }
            NegFrame f;
            char enc[128] = {0}, err[256] = {0};
            if (negLoadFrame(inPath, &f, enc, sizeof(enc), err, sizeof(err)) != 0) {
                printf("✗ 读不了负片：%s\n", err);
                return 1;
            }
            // 零点每帧重定。给了 --base 就手点片基（推荐），否则自动估计。
            // 相机翻拍且灯箱外露的片子里，自动估计会落到灯箱上 —— 那是最常见的翻车点。
            double t0[3];
            if (baseX >= 0 && baseY >= 0) {
                negSamplePatch(&f, baseX, baseY, 12, t0);
                for (int c = 0; c < 3; c++) if (t0[c] < 1e-6) t0[c] = 1e-6;
                printf("   零点：手动点选 (%.3f, %.3f) → T0 = %.5f %.5f %.5f\n",
                       baseX, baseY, t0[0], t0[1], t0[2]);
            } else {
                negEstimateZero(f.rgb, f.w, f.h, 0.0005, t0);
                printf("   零点：自动（最亮 0.05%%）→ T0 = %.5f %.5f %.5f\n",
                       t0[0], t0[1], t0[2]);
            }
            size_t n = f.w * f.h;
            negInvert(f.rgb, n, t0, gamma, offset, lRef, NEG_PI_CLIP_DEFAULT, 0);
            if (ev != 0.0 || black != 0.0) {          // 曝光/黑点在反相之后作用
                double k = pow(2.0, ev);
                for (size_t q = 0; q < n * 3; q++) {
                    double v = f.rgb[q] * k - black;
                    f.rgb[q] = (float)(v > 0 ? v : 0);
                }
            }
            float hi = negGreenPercentile(f.rgb, f.w, f.h, DISP_PCT);
            if (hi < 1e-6f) hi = 1e-6f;

            const char *e = strrchr(outPath, '.');
            int isTiff = e && (!strcasecmp(e, ".tif") || !strcasecmp(e, ".tiff"));
            int r = isTiff
                ? negSaveLinearTIFF(outPath, f.rgb, f.w, f.h, hi, err, sizeof(err))
                : negSaveDisplay8(outPath, f.rgb, f.w, f.h, hi, err, sizeof(err));
            if (r == 0)
                printf("✅ %s → %s　%zu×%zu　白点 %.4f　曝光 %+.2f EV\n",
                       inPath, outPath, f.w, f.h, hi, ev);
            else
                printf("✗ 写不了：%s\n", err);
            negFreeFrame(&f);
            return r == 0 ? 0 : 1;
        }

        if (argc < 4) {
            printf("用法:\n"
                   "  calib_cli --selftest\n"
                   "  calib_cli <负片> <半径> \"x1,y1;x2,y2;...\"\n"
                   "  calib_cli --render <负片> <标定.json> <输出.tif|.jpg|.png> "
                   "[--ev X] [--black Y] [--base x,y]\n");
            return 2;
        }
        NegFrame f;
        char enc[128] = {0}, err[256] = {0};
        if (negLoadFrame(argv[1], &f, enc, sizeof(enc), err, sizeof(err)) != 0) {
            printf("✗ 读不了：%s\n", err);
            return 1;
        }
        int radius = atoi(argv[2]);
        int n = 0;
        double pts[64][2];
        char *dup = strdup(argv[3]), *save = NULL;
        for (char *tok = strtok_r(dup, ";", &save); tok && n < 64;
             tok = strtok_r(NULL, ";", &save)) {
            double x, y;
            if (sscanf(tok, "%lf,%lf", &x, &y) == 2) {
                pts[n][0] = x; pts[n][1] = y; n++;
            }
        }
        free(dup);
        if (n < 2) { printf("✗ 至少要两个点\n"); return 1; }

        printf("文件 %s　%zu×%zu　%s　取样半径 %d px\n", argv[1], f.w, f.h, enc, radius);
        float samples[64 * 3];
        for (int i = 0; i < n; i++) {
            double v[3];
            negSamplePatch(&f, pts[i][0], pts[i][1], radius, v);
            printf("   点 %d (%.4f, %.4f) 线性 = %.6f %.6f %.6f\n",
                   i + 1, pts[i][0], pts[i][1], v[0], v[1], v[2]);
            for (int c = 0; c < 3; c++) samples[i * 3 + c] = (float)v[c];
        }

        double t0[3];
        negEstimateZero(f.rgb, f.w, f.h, 0.0005, t0);
        printf("   自动零点 T0 = %.5f %.5f %.5f\n", t0[0], t0[1], t0[2]);

        NegCal cal;
        if (negFitGamma(samples, n, t0, &cal) != 0) { printf("✗ 拟合失败\n"); return 1; }
        double res = negNeutralResidual(samples, n, t0, cal.gamma, cal.offset);
        printf("   γ = %.6f : 1 : %.6f\n", cal.gamma[0], cal.gamma[2]);
        printf("   σ₂/σ₁ = %.3f%%   秩 1 残差 = %.4f D   中性残差 = %.4f 档\n",
               cal.sigmaRatio * 100, cal.residD, res);
        printf("   偏移 o = %.5f %.5f %.5f   L_ref = %.5f\n",
               cal.offset[0], cal.offset[1], cal.offset[2], cal.lRef);
        negFreeFrame(&f);
    }
    return 0;
}
