// raw2linear.m —— 相机 raw → 16-bit 线性 TIFF（macOS 自带 Core Image RAW 解码）
//
// 为什么不用 rawpy / dcraw / libraw：都要额外装东西。macOS 自带 CIRAWFilter，
// 支持的机型 = 系统能预览的 raw，覆盖 ARW / CR3 / NEF / RAF / DNG…
//
// 为什么是 ObjC 而不是 Swift：本机 CommandLineTools 的 Swift modulemap 有
// "redefinition of module 'SwiftBridging'" 的毛病，clang 不受影响。
//
// 关键：把「相机默认外观」全部关掉。相机内置的对比度（S 曲线）/饱和度/高光恢复
// 是**按通道**施加的，会扭曲「逐通道密度斜率」—— 而那正是 NegLab 要测的量。
//
// ★★ 一个大坑：属性名必须用运行时反射出来的 **input\*** 那一套
//    （CIRAWFilterImpl 继承的是 CIFilter 的 input 命名），
//    而不是 CIRAWFilter 类头文件里那套（draftModeEnabled / contrastAmount…）。
//    第一版照头文件写，结果是「生效 0 项、忽略 21 项」，相机外观一点没关掉。
//    反射命令见 README「开发者注记」。
//
// 编译：clang -O2 -fobjc-arc -Wno-deprecated-declarations \
//        -framework Foundation -framework CoreImage -framework ImageIO \
//        -framework CoreGraphics -o raw2linear raw2linear.m
// 用法：./raw2linear <input.raw> <output.tif> [--exposure EV] [--wb K] [--draft] [--list]

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

static void err(NSString *s) { fprintf(stderr, "%s\n", s.UTF8String); }

static int gApplied = 0, gSkipped = 0;
static void setIf(id obj, NSString *key, id val) {
    @try { [obj setValue:val forKey:key]; gApplied++; }
    @catch (NSException *e) { gSkipped++; }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            err(@"用法: raw2linear <input.raw> <output.tif> "
                 "[--exposure EV] [--wb K] [--draft] [--list]");
            return 2;
        }
        NSString *inPath  = [NSString stringWithUTF8String:argv[1]];
        NSString *outPath = [NSString stringWithUTF8String:argv[2]];
        float exposure = 0.0f, wbTemp = -1.0f;
        BOOL draft = NO, listOnly = NO;
        for (int i = 3; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqualToString:@"--exposure"] && i + 1 < argc) exposure = atof(argv[++i]);
            else if ([a isEqualToString:@"--wb"] && i + 1 < argc) wbTemp = atof(argv[++i]);
            else if ([a isEqualToString:@"--draft"]) draft = YES;
            else if ([a isEqualToString:@"--list"]) listOnly = YES;
        }

        NSURL *url = [NSURL fileURLWithPath:inPath];
        // CIRAWFilter 在 ObjC 头里没暴露构造器（Swift 侧才有 init(imageURL:)）。
        // 走已弃用的类方法建实例，拿到的对象本来就是 CIRAWFilterImpl。
        CIRAWFilter *f = (CIRAWFilter *)[CIFilter filterWithImageURL:url options:@{}];
        if (!f) { err([NSString stringWithFormat:@"❌ 打不开，或系统不支持这个 raw：%@", inPath]); return 1; }

        // ★ 关掉一切「相机外观」（真实属性名，见文件头的说明）
        setIf(f, @"inputDraftMode",                     @(draft));
        setIf(f, @"inputBoost",                         @0.0f);  // ★★ 0 = 线性响应
        setIf(f, @"inputBoostShadowAmount",             @0.0f);  // ★ 阴影提亮会压暗部斜率
        setIf(f, @"inputDisableGamutMap",               @YES);   // ★ 名字是 Disable：YES = 关
        setIf(f, @"inputEnableSharpening",              @NO);
        setIf(f, @"inputEnableVendorLensCorrection",    @NO);
        setIf(f, @"inputEnableEDRMode",                 @NO);
        setIf(f, @"inputEnableNoiseTracking",           @NO);
        setIf(f, @"inputLocalToneMapAmount",            @0.0f);  // ★ 局部色调映射更非线性
        setIf(f, @"inputColorNoiseReductionAmount",     @0.0f);
        setIf(f, @"inputLuminanceNoiseReductionAmount", @0.0f);
        setIf(f, @"inputNoiseReductionAmount",          @0.0f);
        setIf(f, @"inputMoireAmount",                   @0.0f);
        setIf(f, @"inputScaleFactor",                   @1.0f);
        setIf(f, @"inputIgnoreOrientation",             @NO);
        setIf(f, @"inputEV",                            @(exposure));
        if (wbTemp > 0) setIf(f, @"inputNeutralTemperature", @(wbTemp));

        if (listOnly) {
            printf("解码器信息:\n  nativeSize  %.0f × %.0f\n  exposure    %.2f\n"
                   "  属性生效 %d 项，忽略 %d 项\n",
                   f.nativeSize.width, f.nativeSize.height, f.exposure, gApplied, gSkipped);
            return 0;
        }

        CIImage *out = f.outputImage;
        if (!out) { err(@"❌ 解码失败（outputImage 为空）"); return 1; }
        out = [out imageByCroppingToRect:CGRectMake(0, 0, f.nativeSize.width, f.nativeSize.height)];

        // ★ 渲染到「扩展线性 sRGB」——传输函数是线性的，这正是我们要的
        CGColorSpaceRef lin = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        if (!lin) { err(@"❌ 拿不到线性色彩空间"); return 1; }
        CIContext *ctx = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace: (__bridge id)lin,
            kCIContextOutputColorSpace:  (__bridge id)lin,
            kCIContextCacheIntermediates: @NO,
        }];
        CGImageRef cg = [ctx createCGImage:out fromRect:out.extent
                                     format:kCIFormatRGBA16 colorSpace:lin];
        if (!cg) { err(@"❌ 渲染失败"); CGColorSpaceRelease(lin); return 1; }

        NSURL *outURL = [NSURL fileURLWithPath:outPath];
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)outURL, CFSTR("public.tiff"), 1, NULL);
        if (!dest) { err([NSString stringWithFormat:@"❌ 建不了输出文件：%@", outPath]); return 1; }
        CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)@{
            (id)kCGImagePropertyTIFFCompression: @1,
        });
        BOOL ok = CGImageDestinationFinalize(dest);

        fprintf(stderr, "✅ %s → %s\n   %zu×%zu  每通道 %zu bit  %zu 通道\n"
                        "   色彩空间：扩展线性 sRGB（已尽力关掉相机外观：生效 %d 项，忽略 %d 项）\n",
                inPath.lastPathComponent.UTF8String, outPath.lastPathComponent.UTF8String,
                CGImageGetWidth(cg), CGImageGetHeight(cg),
                CGImageGetBitsPerComponent(cg),
                CGImageGetBitsPerPixel(cg) / CGImageGetBitsPerComponent(cg), gApplied, gSkipped);
        CGImageRelease(cg); CFRelease(dest); CGColorSpaceRelease(lin);
        return ok ? 0 : 1;
    }
}
