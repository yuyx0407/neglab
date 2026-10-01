// NegImage.h —— 负片的读与写。走 macOS 自带的 ImageIO / Core Image，不依赖任何第三方库。
//
// 约定（与 README 里写给冲洗店的那段一致）：
//   · 16-bit 及以上  → 视为「线性」，直接除以满量程
//   · 8-bit          → 视为 sRGB 编码，反解传输函数得到线性
//   · 相机 raw       → 用 Core Image 解码，关掉一切相机外观，渲染到扩展线性 sRGB
//
// 为什么不干脆全部交给色彩管理：扫描件常常不带 profile 或带的是线性 profile，
// 交给色彩管理会「顺手」把传输函数再套一遍，逐通道密度斜率就毁了 —— 而那正是
// NegLab 要测的量。所以这里按位深显式判断，行为可预期。
#ifndef NEGIMAGE_H
#define NEGIMAGE_H

#include <stddef.h>

typedef struct {
    float *rgb;     // 线性透过率 0..1，行主序，每像素 3 个
    size_t w, h;
} NegFrame;

// 读负片。成功返回 0，失败返回 -1 并在 err 里写原因。
// enc/encLen 里写回「按什么编码解释的」，供界面显示。
int  negLoadFrame(const char *path, NegFrame *out,
                  char *enc, size_t encLen, char *err, size_t errLen);
void negFreeFrame(NegFrame *f);

// 等比例缩到长边不超过 maxDim（面积平均，不产生锯齿混色）。原始线性域内做。
NegFrame negDownsample(const NegFrame *src, size_t maxDim);

// 第 pct 百分位（只看绿通道）。用于自动亮度映射与导出归一化。
float negGreenPercentile(const float *rgb, size_t w, size_t h, double pct);

// 在一帧上取「一小块区域」的代表值。归一化坐标 nx, ny ∈ [0,1]；
// radius 是方形半径（像素）。做法：取中位数 → 三轮「只留离该中位数最近的 60%」，
// 把压在色块边缘、被隔壁色块污染的那些像素剔掉，最后再取中位数。
// 界面里点灰、命令行批量取样，走的都是这一个函数 —— 免得两处给出两个答案。
void negSamplePatch(const NegFrame *f, double nx, double ny, int radius, double out[3]);

// 线性 RGB → sRGB 编码的 8-bit RGBA（供 CGImage 显示）。调用者负责 free。
// 映射：v = clamp(rgb / hi, 0, 1)，再套 sRGB 传输函数。
unsigned char *negRGBA8(const float *rgb, size_t w, size_t h, float hi);

// 导出。hi 为归一化用的亮度上限（一般传第 99.9 百分位）。
// 十六位线性 TIFF：v = clamp(rgb / hi)，直接写满量程，不套传输函数（留给后续调色）。
int negSaveLinearTIFF(const char *path, const float *rgb, size_t w, size_t h,
                      float hi, char *err, size_t errLen);
// 8-bit sRGB（按扩展名决定 JPEG / PNG）：套传输函数，可直接看。
int negSaveDisplay8(const char *path, const float *rgb, size_t w, size_t h,
                    float hi, char *err, size_t errLen);

// 这个扩展名是不是相机 raw
int negIsRawExt(const char *path);

#endif
