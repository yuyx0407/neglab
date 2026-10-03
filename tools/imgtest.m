// imgtest.m —— 图像 IO 自检：读一张负片，打印它被解释成了什么、零点在哪、
// 反相往返之后的数值。用来确认「16-bit 视为线性 / 8-bit 反解 sRGB」这条约定
// 在各种文件上都真的成立。
//
// 编译：clang -O2 -fobjc-arc -Wno-deprecated-declarations \
//        -framework Foundation -framework CoreImage -framework ImageIO \
//        -framework CoreGraphics -o imgtest imgtest.m ../app/NegImage.m ../app/NegMath.m
// 用法：./imgtest <负片> [更多负片...]
#import <Foundation/Foundation.h>
#include "../app/NegImage.h"
#include "../app/NegMath.h"
#include <stdio.h>
#include <string.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { printf("用法: imgtest <负片> [更多负片...]\n"); return 2; }
        for (int i = 1; i < argc; i++) {
            NegFrame f; char enc[128] = {0}, err[256] = {0};
            if (negLoadFrame(argv[i], &f, enc, sizeof(enc), err, sizeof(err)) != 0) {
                printf("✗ %s : %s\n", argv[i], err);
                continue;
            }
            double t0[3];
            negEstimateZero(f.rgb, f.w, f.h, 0.0005, t0);
            const char *base = strrchr(argv[i], '/');
            printf("✓ %-26s %zu×%zu  %s\n", base ? base + 1 : argv[i], f.w, f.h, enc);
            printf("    自动零点 T0 = %.5f %.5f %.5f\n", t0[0], t0[1], t0[2]);

            size_t n = f.w * f.h;
            float *cp = malloc(sizeof(float) * n * 3);
            if (cp) {
                memcpy(cp, f.rgb, sizeof(float) * n * 3);
                double g[3] = {0.9331, 1.0, 1.6264}, o[3] = {0, 0, 0};
                negInvert(cp, n, t0, g, o, 0.0, NEG_PI_CLIP_DEFAULT, 0);
                float hi = negGreenPercentile(cp, f.w, f.h, 99.5);
                unsigned char *rgba = negRGBA8(cp, f.w, f.h, hi > 1e-9f ? hi : 1e-9f);
                printf("    反相后左上角 = %.5f %.5f %.5f   预览像素 = %d,%d,%d\n",
                       cp[0], cp[1], cp[2], rgba ? rgba[0] : -1, rgba ? rgba[1] : -1,
                       rgba ? rgba[2] : -1);
                free(rgba);
                free(cp);
            }
            negFreeFrame(&f);
        }
    }
    return 0;
}
