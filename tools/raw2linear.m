// raw2linear.m —— 相机 raw → 16-bit 线性 TIFF。
//
// 为什么不用 rawpy / dcraw / libraw：都要额外装东西。macOS 自带 Core Image 的
// RAW 解码器，支持的机型 = 系统能预览的 raw，覆盖 ARW / CR3 / NEF / RAF / DNG…
//
// 为什么是 ObjC 而不是 Swift：本机 CommandLineTools 的 Swift modulemap 有
// "redefinition of module 'SwiftBridging'" 的毛病，clang 不受影响。
//
// ★ 解码逻辑在 app/NegImage.m 里，那里是唯一实现 —— 界面读 raw 走的也是它。
//   这个程序只是把它接到命令行上，免得两处各写一遍、修一处漏一处。
//   其中最关键的一条见 NegImage.m 里 rawToCGImage 的说明：负片上最亮的是
//   未曝光片基，相机翻拍常常给它顶到满量程，CI 渲染成 16 位整数时会直接削平，
//   削掉的正是零点要用的那部分。所以那里会先小图探顶、自动补一个只降不升的 EV。
//
// 编译：见 tools/build_tools.sh
// 用法：./raw2linear <input.raw> [output.tif]
#import <Foundation/Foundation.h>
#include "../app/NegImage.h"
#include "../app/NegMath.h"
#include <stdio.h>
#include <string.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: raw2linear <input.raw> [output.tif]\n"
                            "不给输出路径时，只报告解出来的尺寸、线性范围与零点。\n");
            return 2;
        }
        const char *in = argv[1];
        char def[4096];
        if (argc >= 3) {
            snprintf(def, sizeof(def), "%s", argv[2]);
        } else {
            const char *base = strrchr(in, '/');
            base = base ? base + 1 : in;
            const char *dot = strrchr(base, '.');
            int n = dot ? (int)(dot - base) : (int)strlen(base);
            snprintf(def, sizeof(def), "%.*s_linear.tif", n, base);
        }

        NegFrame f;
        char enc[192] = {0}, err[256] = {0};
        if (negLoadFrame(in, &f, enc, sizeof(enc), err, sizeof(err)) != 0) {
            fprintf(stderr, "读不了：%s\n", err);
            return 1;
        }

        // 线性范围的实测值。片基（最亮处）被削顶的话，这里会看到贴着 1.0。
        double t0[3];
        negEstimateZero(f.rgb, f.w, f.h, 0.0005, t0);
        size_t clipped = 0, n = f.w * f.h;
        for (size_t i = 0; i < n; i++)
            for (int c = 0; c < 3; c++)
                if (f.rgb[i * 3 + c] >= 0.9995f) { clipped++; break; }

        fprintf(stderr, "✓ %s\n   %zu × %zu   %s\n"
                        "   片基（最亮 0.05%% 的均值）= %.5f  %.5f  %.5f\n"
                        "   贴顶像素 = %.3f%%%s\n",
                in, f.w, f.h, enc,
                t0[0], t0[1], t0[2],
                100.0 * (double)clipped / (double)n,
                clipped ? "   ← 仍有削顶，说明超出了自动补偿的范围" : "");

        if (argc >= 3) {
            char werr[256] = {0};
            // hi = 1.0：保持线性尺度不变，不重新归一化
            if (negSaveLinearTIFF(def, f.rgb, f.w, f.h, 1.0f, werr, sizeof(werr)) != 0) {
                fprintf(stderr, "写不了：%s\n", werr);
                negFreeFrame(&f);
                return 1;
            }
            fprintf(stderr, "   → %s（16-bit 线性，未套传输函数）\n", def);
        }
        negFreeFrame(&f);
    }
    return 0;
}
