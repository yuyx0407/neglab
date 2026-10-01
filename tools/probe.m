// probe.m —— 探测 CGBitmapContextCreate 在本机接受哪些 16 位 RGB 组合。
// 一行一个组合，打勾表示建得出来。用来定位「建不出位图上下文」。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#include <stdio.h>

static void tryIt(const char *label, CGColorSpaceRef cs, size_t bpc, CGBitmapInfo info) {
    if (!cs) { printf("  %-52s  ✗ 色彩空间为空\n", label); return; }
    size_t bpr = 8 * 4 * (bpc / 8);
    CGContextRef ctx = CGBitmapContextCreate(NULL, 8, 4, bpc, bpr, cs, info);
    printf("  %-52s  %s\n", label, ctx ? "✅" : "✗");
    if (ctx) CGContextRelease(ctx);
}

int main(void) {
    @autoreleasepool {
        CGColorSpaceRef srgb   = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorSpaceRef lin    = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
        CGColorSpaceRef extlin = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        CGColorSpaceRef ext    = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
        CGColorSpaceRef dev    = CGColorSpaceCreateDeviceRGB();
        printf("kCGColorSpaceLinearSRGB=%p ExtendedLinearSRGB=%p\n",
               (void *)lin, (void *)extlin);

        printf("\n── 16 bpc ──\n");
        tryIt("sRGB        + NoneSkipLast | 16Little", srgb, 16, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder16Little);
        tryIt("LinearSRGB  + NoneSkipLast | 16Little", lin, 16, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder16Little);
        tryIt("ExtLinear   + NoneSkipLast | 16Little", extlin, 16, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder16Little);
        tryIt("ExtSRGB     + NoneSkipLast | 16Little", ext, 16, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder16Little);
        tryIt("DeviceRGB   + NoneSkipLast | 16Little", dev, 16, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder16Little);
        tryIt("sRGB        + PremultipliedLast | 16Lit", srgb, 16, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little);
        tryIt("ExtLinear   + PremultipliedLast | 16Lit", extlin, 16, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little);
        tryIt("ExtLinear   + NoneSkipLast | 16Host", extlin, 16, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder16Host);
        tryIt("ExtLinear   + NoneSkipLast | Default", extlin, 16, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        tryIt("ExtLinear   + None  (3 ch, bpr=6)", extlin, 16, (CGBitmapInfo)kCGImageAlphaNone);

        printf("\n── 8 bpc ──\n");
        tryIt("sRGB        + NoneSkipLast", srgb, 8, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        tryIt("ExtLinear   + NoneSkipLast", extlin, 8, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        tryIt("DeviceRGB   + NoneSkipLast", dev, 8, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);

        printf("\n── 32 bpc float ──\n");
        CGColorSpaceRef linF = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        tryIt("ExtLinear   + float | PremultipliedLast", linF, 32,
              kCGBitmapFloatComponents | kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedLast);
        tryIt("ExtLinear   + float | NoneSkipLast", linF, 32,
              kCGBitmapFloatComponents | kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipLast);
        if (linF) CGColorSpaceRelease(linF);
    }
    return 0;
}
