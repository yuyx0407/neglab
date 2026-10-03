// main.m —— NegLab 的界面。AppKit 原生，不含 Python、不含 Qt。
//
// 刻意的取舍：没有侧边栏、没有标签页、没有主题设置。整条流程就是四步 ——
// 打开 → 定零点 → 解 γ → 导出 —— 所以界面就是四步。参数分成「每帧都要定的」
// 和「一次性定的」两组分开摆，因为这是这套数学里最容易搞混的地方。
//
// 编译见 build_app.sh。
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "NegImage.h"
#include "NegMath.h"
#include <math.h>
#include <string.h>

// ═══════════════════════════════════════════════ 设计尺度
//
// 全部对齐 macOS 人机界面指南。两条硬规矩：
//
// ① **只用语义颜色**（labelColor / secondaryLabelColor / controlBackgroundColor /
//    separatorColor / controlAccentColor / systemGreen…）。它们会随浅色与深色外观
//    自动切换。写死 RGB 的界面在深色模式下一定翻车，这是最常见的低级错误。
// ② **只规定四种字号**：11 节标题、13 正文、11 说明、11.5 等宽数值。
//    上一版用了 10.5 / 11 / 11.5 / 12 / 12.5 / 19 六种字号且都偏小，中文挤成一团。
//    现在正文一律 13，说明文字也是 11，靠颜色深浅分层而不是靠字号。
static NSString *gLaunchPath = nil;      // argv[1]：要打开的负片
static NSString *gLaunchCalib = nil;     // argv[2]：可选，跟着一起载入的标定 json

static const CGFloat PANEL_W       = 350;   // 检查器宽度
static const CGFloat PROXY_MAX_DIM = 1500;
static const CGFloat PAD_SIDE      = 16;    // 侧栏外边距
static const CGFloat PAD_CARD      = 14;    // 卡片内边距
static const CGFloat GAP_CARD      = 12;    // 卡片之间
static const CGFloat GAP_ROW       = 8;     // 卡片内行距
static const CGFloat SIDEBAR_TEXT_W = 264;  // 侧栏里折行文字的排版宽度

static NSColor *C_ACCENT(void) { return NSColor.controlAccentColor; }
static NSColor *C_OK(void)     { return NSColor.systemGreenColor; }
static NSColor *C_WARN(void)   { return NSColor.systemRedColor; }
static NSColor *C_INK(void)    { return NSColor.labelColor; }
static NSColor *C_MUT(void)    { return NSColor.secondaryLabelColor; }
static NSColor *C_FAINT(void)  { return NSColor.tertiaryLabelColor; }
static NSColor *C_SURFACE(void){ return NSColor.controlBackgroundColor; }
static NSColor *C_HAIR(void)   { return NSColor.separatorColor; }

static NSFont *F_SECTION(void) { return [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; }
static NSFont *F_BODY(void)    { return [NSFont systemFontOfSize:13]; }
static NSFont *F_SMALL(void)   { return [NSFont systemFontOfSize:11]; }
static NSFont *F_VALUE(void)   { return [NSFont monospacedDigitSystemFontOfSize:11.5
                                                                    weight:NSFontWeightRegular]; }

// ═══════════════════════════════════════════════ 小工具

static NSTextField *mkLabel(NSString *s, NSFont *font, NSColor *color) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = font;
    t.textColor = color;
    t.lineBreakMode = NSLineBreakByWordWrapping;
    t.maximumNumberOfLines = 0;          // 0 = 不限行数；这是「文字显示不全」的根治办法
    t.usesSingleLineMode = NO;
    t.selectable = NO;
    [t setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}

// 单行标签（标题、数值这类不该折行的）
static NSTextField *mkLabel1(NSString *s, NSFont *font, NSColor *color) {
    NSTextField *t = mkLabel(s, font, color);
    t.usesSingleLineMode = YES;
    t.maximumNumberOfLines = 1;
    return t;
}

// 卡片里的说明文字。**必须给 preferredMaxLayoutWidth** ——
// 自动折行的标签如果不知道自己的行宽，AppKit 会按「单行宽度」算高度，
// 于是卡片里会多出一大截空白（侧栏里看起来就像卡片之间隔着一条河）。
static NSTextField *mkHelp(NSString *s) {
    NSTextField *t = mkLabel(s, F_SMALL(), C_MUT());
    t.preferredMaxLayoutWidth = SIDEBAR_TEXT_W;
    // 抗压缩拉到 required：说明文字宁可把卡片撑高，也不许被压成「…」。
    // 这正是「文字显示不全」的根源 —— 布局为了塞下别的控件，把说明行挤掉了。
    [t setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationVertical];
    return t;
}

// 等宽数字标签。数值列必须等宽，否则拖动滑杆时数字会左右跳。
static NSTextField *mkValue(NSString *s) {
    NSTextField *t = mkLabel1(s, F_VALUE(), C_MUT());
    t.alignment = NSTextAlignmentRight;
    [t setContentHuggingPriority:NSLayoutPriorityRequired
                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}

static NSButton *mkButton(NSString *title, id target, SEL action) {
    return [NSButton buttonWithTitle:title target:target action:action];
}

// 带 SF Symbol 图标的按钮（macOS 13 起的标配做法）
static NSButton *mkSymbolButton(NSString *symbol, NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    if (img) { b.image = img; b.imagePosition = NSImageLeading; }
    return b;
}

// 垂直栈：alignment 用 Width，让每一行都撑满宽度（AppKit 里这是「拉伸」的意思）
static NSStackView *vstack(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeWidth;
    s.spacing = spacing;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

static NSStackView *hstack(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = NSLayoutAttributeCenterY;
    s.spacing = spacing;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

static int cmpFloatAsc(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x < y) ? -1 : (x > y ? 1 : 0);
}

// 卡片。用普通 NSView，但走 updateLayer 上色 —— 这样切换深色外观时 AppKit 会
// 重新调用它，颜色才跟着变。直接把 CGColor 写进 layer 是静态的，外观一变就留在旧颜色。
@interface NegCard : NSView
@property (nonatomic, strong) NSTextField *titleLabel;
@end

@implementation NegCard
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.backgroundColor = C_SURFACE().CGColor;
    self.layer.borderColor = C_HAIR().CGColor;
    self.layer.borderWidth = 1;
    self.layer.cornerRadius = 9;
    self.layer.cornerCurve = kCACornerCurveContinuous;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

// 卡片工厂：标题（可着色成当前步骤）+ 若干行
static NegCard *mkCard(NSString *title, NSArray<NSView *> *rows) {
    NegCard *box = [[NegCard alloc] initWithFrame:NSMakeRect(0, 0, 100, 40)];
    box.translatesAutoresizingMaskIntoConstraints = NO;

    NSMutableArray<NSView *> *all = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gap = [NSMutableArray array];
    if (title.length) {
        box.titleLabel = mkLabel(title, F_SECTION(), C_MUT());
        [all addObject:box.titleLabel];
        [gap addObject:@8];
    }
    for (NSView *r in rows) { [all addObject:r]; [gap addObject:@(GAP_ROW)]; }

    NSStackView *st = vstack(all, GAP_ROW);
    for (NSUInteger i = 0; i + 1 < st.arrangedSubviews.count; i++)
        [st setCustomSpacing:gap[i].doubleValue afterView:st.arrangedSubviews[i]];

    [box addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor  constraintEqualToAnchor:box.leadingAnchor constant:PAD_CARD],
        [st.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-PAD_CARD],
        [st.topAnchor      constraintEqualToAnchor:box.topAnchor constant:PAD_CARD - 2],
        [st.bottomAnchor   constraintEqualToAnchor:box.bottomAnchor constant:-(PAD_CARD - 2)],
    ]];
    return box;
}

// 一行「标签 ——— 滑杆 ——— 数值」
@interface NegSliderRow : NSStackView
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSTextField *value;
@property (nonatomic, copy)   NSString   *fmt;   // 记下来，滑杆动了才能刷新读数
- (instancetype)initWithTitle:(NSString *)title lo:(double)lo hi:(double)hi
                          val:(double)val fmt:(NSString *)fmt;
@end

@implementation NegSliderRow
- (instancetype)initWithTitle:(NSString *)title lo:(double)lo hi:(double)hi
                          val:(double)val fmt:(NSString *)fmt {
    self = [super init];
    self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.alignment = NSLayoutAttributeCenterY;
    self.spacing = 8;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *t = mkLabel1(title, F_BODY(), C_INK());
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [t.widthAnchor constraintEqualToConstant:46].active = YES;
    [t setContentHuggingPriority:NSLayoutPriorityRequired
                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    [t setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                forOrientation:NSLayoutConstraintOrientationHorizontal];

    _slider = [NSSlider sliderWithValue:val minValue:lo maxValue:hi target:nil action:nil];
    _slider.continuous = YES;
    _slider.controlSize = NSControlSizeSmall;
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider setContentHuggingPriority:NSLayoutPriorityDefaultLow - 2
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_slider setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 2
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _fmt = fmt;
    _value = mkValue([NSString stringWithFormat:fmt, val]);
    _value.translatesAutoresizingMaskIntoConstraints = NO;
    [_value.widthAnchor constraintEqualToConstant:58].active = YES;

    [self addArrangedSubview:t];
    [self addArrangedSubview:_slider];
    [self addArrangedSubview:_value];
    [self.heightAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
    return self;
}

// 滑杆一动就刷新右侧读数。原来只在初始化时写一次，所以数字永远不动。
- (void)refresh {
    self.value.stringValue = [NSString stringWithFormat:self.fmt, self.slider.doubleValue];

}
@end

// ═══════════════════════════════════════════════ 预览画布

@interface NegCanvas : NSView
@property (nonatomic, strong) NSImage *shown;
@property (nonatomic, copy) void (^onSample)(double nx, double ny);
@property (nonatomic) BOOL picking;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *marks;
@end

@implementation NegCanvas {
    NSRect _imgRect;
}

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _marks = [NSMutableArray array];
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.20 blue:0.21 alpha:1].CGColor;
        self.layer.cornerRadius = 10;
        [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }

- (void)setPicking:(BOOL)picking {
    _picking = picking;
    [self.window invalidateCursorRectsForView:self];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds
                 cursor:(_picking ? NSCursor.crosshairCursor : NSCursor.arrowCursor)];
}

- (void)setShown:(NSImage *)shown {
    _shown = shown;
    [self setNeedsDisplay:YES];
}

- (void)layoutImageRect {
    if (!_shown || _shown.size.width < 1 || _shown.size.height < 1) {
        _imgRect = NSZeroRect;
        return;
    }
    NSSize s = _shown.size;
    CGFloat k = MIN((NSWidth(self.bounds) - 24) / s.width,
                    (NSHeight(self.bounds) - 24) / s.height);
    CGFloat w = s.width * k, h = s.height * k;
    _imgRect = NSMakeRect(floor((NSWidth(self.bounds) - w) / 2),
                          floor((NSHeight(self.bounds) - h) / 2), w, h);
}

- (void)drawRect:(NSRect)dirty {
    [self layoutImageRect];
    if (!_shown) { [self drawPlaceholder]; return; }
    [_shown drawInRect:_imgRect fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver fraction:1.0
       respectFlipped:YES
                hints:@{ NSImageHintInterpolation: @(NSImageInterpolationHigh) }];

    for (NSDictionary *m in _marks) {
        CGFloat x = _imgRect.origin.x + [m[@"nx"] doubleValue] * _imgRect.size.width;
        CGFloat y = _imgRect.origin.y + [m[@"ny"] doubleValue] * _imgRect.size.height;
        BOOL base = [m[@"kind"] isEqualToString:@"base"];
        NSColor *c = base ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
        NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 8, y - 8, 16, 16)];
        p.lineWidth = 2;
        [c setStroke];
        [p stroke];
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 1, y - 1, 2, 2)];
        [dot stroke];
    }
}

- (void)drawPlaceholder {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *a = @{
        NSFontAttributeName: [NSFont systemFontOfSize:17 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.66 alpha:1],
        NSParagraphStyleAttributeName: ps };
    NSDictionary *b = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.48 alpha:1],
        NSParagraphStyleAttributeName: ps };
    CGFloat cy = NSHeight(self.bounds) / 2;
    [@"把负片拖进来"
        drawInRect:NSMakeRect(0, cy - 26, NSWidth(self.bounds), 24) withAttributes:a];
    [@"或按 ⌘O 打开。扫描件和相机 raw 都可以。"
        drawInRect:NSMakeRect(0, cy + 2, NSWidth(self.bounds), 20) withAttributes:b];
}

- (void)mouseDown:(NSEvent *)e {
    if (!_shown || !self.onSample) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (!NSPointInRect(p, _imgRect)) return;
    double nx = (p.x - _imgRect.origin.x) / _imgRect.size.width;
    double ny = (p.y - _imgRect.origin.y) / _imgRect.size.height;
    self.onSample(MIN(MAX(nx, 0), 1), MIN(MAX(ny, 0), 1));
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s {
    NSArray<NSURL *> *urls =
        [s.draggingPasteboard readObjectsForClasses:@[ NSURL.class ]
                                           options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @(YES) }];
    if (!urls.count) return NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NegLabOpenURL" object:urls.firstObject];
    return YES;
}
@end

// ═══════════════════════════════════════════════ 主控制器

@interface NegApp : NSObject <NSApplicationDelegate, NSToolbarDelegate>
@end

// ── 根视图：用「框架布局」而不是 Auto Layout 摆放四大块 ────────────────────
// 为什么不全程用 Auto Layout：窗口的尺寸和内容的尺寸互为因果时，AppKit 会拿内容
// 的拟合尺寸去定窗口，而且 contentMinSize / setContentSize: / setFrame: 全部拦不住
// （这台机器上实测窗口被钉成 691 × 754，画布只剩 303 pt 宽，连冲突日志都不打）。
// 顶层这四块用框架布局就没有这个问题：窗口尺寸是**因**，各块的位置是**果**。
// 侧栏内部仍然用 Auto Layout —— 它的宽度是固定的，不会反过来影响窗口。
// ── 胶片条：横向缩略图，点哪张载哪张 ───────────────────────────────────────
// 自绘而非用 NSButton：按钮数量随卷长变化，自绘省掉一整套增删与生命周期管理。
static const CGFloat TH_W = 96, TH_H = 64, TH_GAP = 8;

@interface NegStrip : NSView
@property (nonatomic, strong) NSMutableArray<NSImage *> *thumbs;
@property (nonatomic) NSInteger sel;
@property (nonatomic, copy) void (^onPick)(NSInteger idx);
@end

@implementation NegStrip
- (BOOL)isFlipped { return YES; }
- (void)setThumbs:(NSMutableArray<NSImage *> *)t { _thumbs = t; self.needsDisplay = YES; }
- (void)setSel:(NSInteger)v { _sel = v; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)d {
    CGFloat x = TH_GAP;
    // 背景 + 总数提示：让用户知道胶片条在这儿，不是被吞掉了
    [[NSColor controlBackgroundColor] setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2, 2, d.size.width - 4, d.size.height - 4)
                                                       xRadius:4 yRadius:4];
    [[NSColor separatorColor] setStroke]; bg.lineWidth = 0.5; [bg stroke]; [bg fill];
    if (_thumbs.count == 0) {
        [[NSColor tertiaryLabelColor] set];
        [@"正在装入…" drawAtPoint:NSMakePoint(10, d.size.height / 2 - 6)
                   withAttributes:@{ NSFontAttributeName : [NSFont systemFontOfSize:12],
                                     NSForegroundColorAttributeName : NSColor.tertiaryLabelColor }];
        return;
    }
    for (NSUInteger i = 0; i < _thumbs.count; i++) {
        NSRect r = NSMakeRect(x, TH_GAP, TH_W, TH_H);
        if (NSIntersectsRect(r, d)) {
            NSImage *im = _thumbs[i];
            if ([im isKindOfClass:[NSImage class]]) {
                [im drawInRect:r fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver fraction:1.0];
            } else {                                    // 占位：画序号，告诉用户在排队
                [[NSColor quaternaryLabelColor] setFill]; NSRectFill(r);
                [[NSColor tertiaryLabelColor] set];
                NSString *t = [NSString stringWithFormat:@"%@", @(i + 1)];
                [t drawAtPoint:NSMakePoint(r.origin.x + r.size.width/2 - 5,
                                           r.origin.y + r.size.height/2 - 7)
                 withAttributes:@{ NSFontAttributeName : [NSFont systemFontOfSize:13] }];
            }
            if ((NSInteger)i == _sel) {
                [[NSColor controlAccentColor] setStroke];
                NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r,-2,-2)
                                                                   xRadius:5 yRadius:5];
                bp.lineWidth = 2.5; [bp stroke];
            }
        }
        x += TH_W + TH_GAP;
    }
}
- (void)mouseDown:(NSEvent *)e {
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = (NSInteger)floor(pt.x / (TH_W + TH_GAP));
    if (i >= 0 && i < (NSInteger)_thumbs.count && _onPick) _onPick(i);
}
@end

@interface NegRoot : NSView
@property (nonatomic, weak) NSView *canvas, *status, *hair, *side, *strip;
@end

@implementation NegRoot
- (void)layout {
    [super layout];
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    if (W < 10 || H < 10) return;

    self.side.frame = NSMakeRect(W - PANEL_W, 0, PANEL_W, H);
    self.hair.frame = NSMakeRect(W - PANEL_W - 1, 0, 1, H);

    CGFloat pad = 18, statusH = 16;
    CGFloat cw = W - PANEL_W - 1 - pad * 2;
    if (cw < 80) cw = 80;
    CGFloat cy = 16 + statusH + 10;
    self.status.frame = NSMakeRect(pad, 16, cw, statusH);
    CGFloat sy = 16 + statusH + 10, sH = TH_H + 2 * TH_GAP;
    self.strip.frame = NSMakeRect(pad, sy, cw, sH);
    cy = sy + sH + 10;
    CGFloat ch = H - cy - pad;
    if (ch < 80) ch = 80;
    self.canvas.frame = NSMakeRect(pad, cy, cw, ch);
}
@end

@interface NegApp ()
- (void)jumpTo:(NSInteger)i;
- (void)setPaths:(NSArray<NSString *> *)paths;
- (void)buildThumbs;
@end

@implementation NegApp {
    NSWindow *_win;
    NegCanvas *_canvas;
    NSTextField *_lblFile, *_lblFileMeta, *_lblStatus;
    NSTextField *_lblT0, *_lblFit, *_lblHealth;
    NegCard *_cardZero, *_cardGamma, *_cardOut;
    NSSegmentedControl *_segView, *_segZero;
    NSButton *_chkLock;
    NSButton *_btnGrey, *_btnUndo, *_btnClearCal;
    NegSliderRow *_slGammaR, *_slGammaB, *_slExposure, *_slY, *_slM, *_slC;
    NSSegmentedControl *_segPaper;
    int _paper;
    NSScrollView *_sidebar;
    NSScrollView *_stripBox;
    NegStrip *_stripView;
    NSMutableArray<NSString *> *_paths;
    NSMutableArray<NSImage *> *_thumbs;
    NSInteger _curIdx, _curThumb;
    NSArray<NSString *> *_pendingPaths;   // 界面就绪前送来的文件先存这里
    NSWindow *_guide;

    NegFrame     _full, _proxy;
    NSImage *_imgOriginal, *_imgResult;
    double _t0[3];          // 手动点选的零点
    double _autoT0[3];      // 自动零点，载入时算一次
    double _lockedT0[3];    // 被锁住的零点，供同一批的其余帧共用
    BOOL _hasLockedT0;
    double _gamma[3];
    double _offset[3];
    double _lRef;
    NSMutableArray<NSDictionary *> *_greys;
    NSURL *_pendingCalib;        // 命令行第二参数给的标定，等这张负片读完了再套
    BOOL _haveBase;
    int _mode;                   // 0 无 / 1 点片基 / 2 点中性灰
    NSString *_currentPath;
    BOOL _loading;
}

// ── 启动 ───────────────────────────────────────────────────────────────────
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _gamma[0] = 1.0; _gamma[1] = 1.0; _gamma[2] = 1.0;
    _greys = [NSMutableArray array];
    [self buildMenu];
    [self buildWindow];
    [NSApp activateIgnoringOtherApps:YES];
    if (gLaunchPath) {
        if (gLaunchCalib) _pendingCalib = [NSURL fileURLWithPath:gLaunchCalib];
        [self loadPath:gLaunchPath];
    } else if (![[NSUserDefaults standardUserDefaults] boolForKey:@"NegLabSeenGuide"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NegLabSeenGuide"];
        [self showGuide:nil];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)files {
    if (!files.count) return;
    [self setPaths:[files sortedArrayUsingSelector:@selector(compare:)]];
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];

    NSMenuItem *appItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"关于 NegLab" action:@selector(showAbout:) keyEquivalent:@""].target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"隐藏 NegLab" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 NegLab" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [bar addItemWithTitle:@"文件" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [NSMenu new];
    [fileMenu addItemWithTitle:@"打开负片…" action:@selector(openDoc:) keyEquivalent:@"o"].target = self;
    [fileMenu addItemWithTitle:@"导出…" action:@selector(exportDoc:) keyEquivalent:@"s"].target = self;
    [fileMenu addItem:NSMenuItem.separatorItem];
    fileItem.submenu = fileMenu;

    NSMenuItem *viewItem = [bar addItemWithTitle:@"视图" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [NSMenu new];
    [viewMenu addItemWithTitle:@"切换原始／结果" action:@selector(toggleView:) keyEquivalent:@"b"].target = self;
    [viewMenu addItemWithTitle:@"清空所有取样点" action:@selector(clearAll:) keyEquivalent:@"k"].target = self;
    viewItem.submenu = viewMenu;

    NSMenuItem *helpItem = [bar addItemWithTitle:@"帮助" action:nil keyEquivalent:@""];
    NSMenu *helpMenu = [NSMenu new];
    [helpMenu addItemWithTitle:@"使用说明" action:@selector(showGuide:) keyEquivalent:@"?"].target = self;
    helpItem.submenu = helpMenu;

    NSApp.mainMenu = bar;
}

- (void)showAbout:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = @"NegLab 1.0";
    a.informativeText =
        @"科学去色罩工作台。\n\n"
        @"先把参数定下来（零点、逐通道密度斜率、偏移），再谈反相的方法。\n"
        @"数学只有三行，见 app/NegMath.h 顶部。\n\n"
        @"MIT 许可。负片里没有标准答案 —— 一切结论以你自己点的那几块中性灰为准。";
    [a runModal];
}

// ── 检查器（右侧） ─────────────────────────────────────────────────────────
// 用 NSScrollView 包住：窗口高度不够时内容可以滚动，而不是被裁掉。
// 上一版没有滚动视图，窗口一矮下面的卡片就直接看不见了。
- (NSScrollView *)buildSidebar {
    // ── 文件 ──
    _lblFile = mkLabel1(@"尚未打开文件", F_BODY(), C_INK());
    _lblFile.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _lblFileMeta = mkHelp(@"拖入窗口，或按 ⌘O。店家扫的 TIFF、你翻拍的相机 raw 都能读。");
    NegCard *cardFile = mkCard(@"文件", @[_lblFile, _lblFileMeta]);

    // ── ① 零点 ──
    _segZero = [NSSegmentedControl segmentedControlWithLabels:@[ @"自动", @"手动点选" ]
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                       target:self action:@selector(zeroModeChanged:)];
    _segZero.selectedSegment = 0;
    _segZero.controlSize = NSControlSizeRegular;
    _segZero.segmentDistribution = NSSegmentDistributionFillEqually;

    NSButton *btnBase = mkSymbolButton(@"scope", @"在图上点片基", self, @selector(armBase:));
    _lblT0 = mkLabel(@"T0 —", F_VALUE(), C_MUT());   // 可换行：三通道数值一行放不下

    _chkLock = [NSButton checkboxWithTitle:@"锁住，供同一批的其余帧共用" target:self
                                    action:@selector(lockToggled:)];
    _chkLock.controlSize = NSControlSizeSmall;
    _chkLock.font = F_SMALL();

    NegCard *cardZero = mkCard(@"① 零点　每帧都要重定",
        @[_segZero, btnBase, _lblT0, _chkLock,
          mkHelp(@"零点 = 未曝光片基的透过率。有片基就点它，最准；自动估计会被画面里的强光带偏。"
                 @"店家扫不到片基时，在胶卷开头空拍一格（盖着镜头盖按一次快门），"
                 @"那一格就是纯片基 —— 点它，再勾上这里。")]);

    // ── ② 斜率 γ ──
    _btnGrey = mkSymbolButton(@"eyedropper", @"点中性灰（0 块）", self, @selector(armGrey:));
    _btnUndo = mkButton(@"撤销", self, @selector(undoGrey:));
    NSButton *btnFit = mkButton(@"解算 γ", self, @selector(doFit:));
    btnFit.keyEquivalent = @"\r";
    NSButton *btnSaveCal = mkButton(@"存标定…", self, @selector(saveCal:));
    NSButton *btnLoadCal = mkButton(@"载入…", self, @selector(loadCal:));
    _btnClearCal = mkButton(@"清空取样", self, @selector(clearAll:));
    NSButton *btnHow = mkButton(@"怎么做", self, @selector(howToCalibrate:));

    NSStackView *rowGrey = hstack(@[_btnGrey, _btnUndo], 8);
    [rowGrey setDistribution:NSStackViewDistributionFillEqually];
    NSStackView *rowFit = hstack(@[btnFit, btnHow], 8);
    [rowFit setDistribution:NSStackViewDistributionFillEqually];
    NSStackView *rowCal = hstack(@[btnSaveCal, btnLoadCal], 8);
    [rowCal setDistribution:NSStackViewDistributionFillEqually];

    _slGammaR = [[NegSliderRow alloc] initWithTitle:@"γ 红" lo:0.3 hi:3.0 val:1.0 fmt:@"%.3f"];
    _slGammaB = [[NegSliderRow alloc] initWithTitle:@"γ 蓝" lo:0.3 hi:3.0 val:1.0 fmt:@"%.3f"];
    for (NegSliderRow *r in @[_slGammaR, _slGammaB]) {
        r.slider.target = self;
        r.slider.action = @selector(manualGammaChanged:);
    }
    _lblFit = mkHelp(@"尚未标定。没有 γ 也能看，只是三个通道的斜率对不齐，会留下明显偏色。");

    NegCard *cardGamma = mkCard(@"② 斜率 γ 与偏移　一个型号定一次",
        @[rowGrey, rowFit, _slGammaR, _slGammaB, _lblFit, _btnClearCal, rowCal]);

    // ── ③ 输出 ──
    _slExposure = [[NegSliderRow alloc] initWithTitle:@"曝光" lo:-6 hi:6 val:0 fmt:@"%+.2f"];
    // 数字放大机的滤色片。单位 CC（1 CC = 0.01 密度），刻度用真放大机头的 Y/M/C。
    _slY = [[NegSliderRow alloc] initWithTitle:@"Y" lo:-100 hi:100 val:0 fmt:@"%.0f"];
    _slM = [[NegSliderRow alloc] initWithTitle:@"M" lo:-100 hi:100 val:0 fmt:@"%.0f"];
    _slC = [[NegSliderRow alloc] initWithTitle:@"C" lo:-100 hi:100 val:0 fmt:@"%.0f"];
    for (NegSliderRow *r in @[_slExposure, _slY, _slM, _slC]) {
        r.slider.target = self;
        r.slider.action = @selector(outputChanged:);
    }
    _lblHealth = mkHelp(@"");
    _segPaper = [NSSegmentedControl segmentedControlWithLabels:@[ @"线性母版", @"印片 (2383)" ]
                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                        target:self action:@selector(paperChanged:)];
    _segPaper.selectedSegment = 0;
    _segPaper.controlSize = NSControlSizeSmall;
    _segPaper.segmentDistribution = NSSegmentDistributionFillEqually;

    NegCard *cardOut = mkCard(@"③ 输出　Y/M/C = 印片机滤色片（CC）",
        @[_slExposure, _slY, _slM, _slC,
          _segPaper,
          mkHelp(@"Y/M/C 是印片机的滤色片，单位 CC：1 CC ≈ 0.01 密度，30 CC ≈ 1 档。\n"
                 @"0 CC = 本次标定确定的中性 —— 所以先把标定做掉，这里的零点才有意义。\n"
                 @"方向与暗房一致：加 Y 偏蓝、加 M 偏绿、加 C 偏红。\n"
                 @"但 CYM 只能改「整体偏色」，改不了「逐颜色的误差」—— 饱和色上的残余，"
                 @"调它治不了，得靠色靶标定。"),
          _lblHealth]);

    // ── 组装 ──
    NSStackView *stack = vstack(@[cardFile, cardZero, cardGamma, cardOut], GAP_CARD);
    stack.edgeInsets = NSEdgeInsetsMake(PAD_SIDE, PAD_SIDE, PAD_SIDE, PAD_SIDE);

    NSView *inner = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, PANEL_W, 600)];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [inner addSubview:stack];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, PANEL_W, 600)];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = NO;
    sv.autohidesScrollers = YES;
    sv.drawsBackground = NO;
    sv.documentView = inner;
    sv.contentView.drawsBackground = NO;

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:inner.topAnchor],
        [stack.bottomAnchor   constraintEqualToAnchor:inner.bottomAnchor],
        [stack.leadingAnchor  constraintEqualToAnchor:inner.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:inner.trailingAnchor],
        // ★ 用固定宽度，别用「等于滚动视图裁剪区宽度」。
        //   把 documentView 的宽度和 clipView 绑在一起，会让滚动视图去参与整个窗口的
        //   尺寸推导，结果是窗口被自己缩到最小（实测 691 宽），而且画布上的宽度下限
        //   被无声地破掉、还不会打冲突日志。
        [inner.widthAnchor    constraintEqualToConstant:PANEL_W],
    ]];

    // ★ 卡片宽度必须钉死。只靠 stack 的 alignment = Width 时，各卡的宽度会退化成
    //   各自内容的固有宽度，结果右边缘勉强对齐、左边缘参差（实测三张卡左边缘差 200pt）。
    for (NSView *v in @[cardFile, cardZero, cardGamma, cardOut])
        [v.widthAnchor constraintEqualToConstant:PANEL_W - 2 * PAD_SIDE].active = YES;

    _cardZero = cardZero; _cardGamma = cardGamma; _cardOut = cardOut;
    _sidebar = sv;
    return sv;
}

// ── 主窗 ───────────────────────────────────────────────────────────────────
- (void)buildWindow {
    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1240, 820)
                                       styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                         backing:NSBackingStoreBuffered defer:NO];
    _win.title = @"NegLab";
    _win.backgroundColor = NSColor.windowBackgroundColor;
    // ★ 关掉状态恢复。macOS 会把窗口尺寸另存进 ~/Library/Saved Application State/，
    //   那和 NSUserDefaults 是两个独立存储 —— 只删 defaults 是清不掉的。
    _win.restorable = NO;
    [_win center];
    [_win setFrameAutosaveName:@"NegLabMainWindow"];

    NegRoot *root = [[NegRoot alloc] initWithFrame:NSMakeRect(0, 0, 1240, 800)];
    _win.contentView = root;

    // 画布
    _canvas = [[NegCanvas alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    __weak NegApp *ws = self;
    _canvas.onSample = ^(double nx, double ny) { [ws handleClickX:nx y:ny]; };

    // 检查器
    NSScrollView *side = [self buildSidebar];

    // 分隔线（AppKit 的标准做法：1pt 的 separatorColor）
    NSView *hair = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 100)];
    hair.translatesAutoresizingMaskIntoConstraints = NO;
    hair.wantsLayer = YES;
    hair.layer.backgroundColor = C_HAIR().CGColor;

    // 状态行：当前该做什么、刚做了什么。放在画布正下方，不抢视线但一直在。
    //
    // ★★ 这里必须是**单行**，不能自动折行。否则会形成一个循环依赖：
    //     状态行的宽度 ← 画布宽度；画布的高度 ← 状态行的行数 ← 状态行的宽度。
    //    Auto Layout 解不开这种环，只会挑一个退化解 —— 表现为整个窗口被钉在
    //    「刚好装下这行字」的宽度（实测 691 × 754），而且画布上的宽度下限会被
    //    无声地破掉、连冲突日志都不打。这个坑查了很久，记在这里。
    _lblStatus = mkLabel1(@"把负片拖进窗口，或按 ⌘O。扫描件与相机 raw 都能读。",
                          F_SMALL(), C_MUT());
    _lblStatus.lineBreakMode = NSLineBreakByTruncatingTail;
    _lblStatus.toolTip = _lblStatus.stringValue;

    [root addSubview:_canvas];
    [root addSubview:_lblStatus];
    [root addSubview:hair];
    [root addSubview:side];

    // 视图模式：原始负片 / 结果。放进工具栏右侧，跟系统里的预览、照片一个位置。
    _segView = [NSSegmentedControl segmentedControlWithLabels:@[ @"原始负片", @"结果" ]
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                       target:self action:@selector(viewChanged:)];
    _segView.selectedSegment = 1;
    _segView.controlSize = NSControlSizeRegular;
    _segView.segmentDistribution = NSSegmentDistributionFillEqually;
    [_segView.widthAnchor constraintEqualToConstant:176].active = YES;

    // ── 工具栏：动作放这里，跟系统里的预览、照片一个位置 ──
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"dev.neglab.toolbar"];
    tb.delegate = self;
    tb.allowsUserCustomization = NO;
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    if (@available(macOS 11.0, *)) _win.toolbarStyle = NSWindowToolbarStyleUnified;
    _win.toolbar = tb;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(openURLNote:)
                                                 name:@"NegLabOpenURL" object:nil];

    // 四块交给 NegRoot 的 -layout 摆，这里只登记引用
    _stripView = [[NegStrip alloc] initWithFrame:NSMakeRect(0, 0, 400, TH_H + 2 * TH_GAP)];
    _thumbs = [NSMutableArray array];
    _stripView.thumbs = _thumbs;
    __weak NegApp *wss = self;
    _stripView.onPick = ^(NSInteger i) { [wss jumpTo:i]; };
    _stripBox = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, TH_H + 2 * TH_GAP)];
    _stripBox.hasHorizontalScroller = YES;
    _stripBox.hasVerticalScroller = NO;
    _stripBox.autohidesScrollers = YES;
    _stripBox.drawsBackground = NO;
    _stripBox.documentView = _stripView;

    [root addSubview:_stripBox];
    root.strip  = _stripBox;
    root.canvas = _canvas;
    root.status = _lblStatus;
    root.hair   = hair;
    root.side   = side;

    _win.contentMinSize = NSMakeSize(960, 640);
    [_win setContentSize:NSMakeSize(1240, 800)];
    [_win center];
    [_win makeKeyAndOrderFront:nil];
    [self refreshEnabled];
    if (_pendingPaths) {                        // 补上启动时送进来的那批文件
        NSArray<NSString *> *p = _pendingPaths;
        _pendingPaths = nil;
        [self setPaths:p];
    }
}

// ── 工具栏 ─────────────────────────────────────────────────────────────────
static NSString *const TB_OPEN  = @"open";
static NSString *const TB_EXPORT= @"export";
static NSString *const TB_VIEW  = @"view";
static NSString *const TB_HELP  = @"help";

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)tb {
    return @[ TB_OPEN, TB_EXPORT, NSToolbarFlexibleSpaceItemIdentifier, TB_VIEW, TB_HELP ];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb {
    return @[ TB_OPEN, TB_EXPORT, NSToolbarFlexibleSpaceItemIdentifier, TB_VIEW, TB_HELP ];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)tb itemForItemIdentifier:(NSToolbarItemIdentifier)ident
     willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    if ([ident isEqualToString:TB_OPEN]) {
        it.label = @"打开";
        it.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:@"打开"];
        it.target = self;
        it.action = @selector(openDoc:);
    } else if ([ident isEqualToString:TB_EXPORT]) {
        it.label = @"导出";
        it.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.up"
                             accessibilityDescription:@"导出"];
        it.target = self;
        it.action = @selector(exportDoc:);
    } else if ([ident isEqualToString:TB_HELP]) {
        it.label = @"使用说明";
        it.image = [NSImage imageWithSystemSymbolName:@"questionmark.circle"
                             accessibilityDescription:@"使用说明"];
        it.target = self;
        it.action = @selector(showGuide:);
    }
    return it;
}

- (void)openURLNote:(NSNotification *)n {
    NSURL *u = n.object;
    if ([u isKindOfClass:NSURL.class] && u.isFileURL) [self loadPath:u.path];
}

// ── 载入 ───────────────────────────────────────────────────────────────────
// ── 批量导入与胶片条 ───────────────────────────────────────────────────────
- (void)setPaths:(NSArray<NSString *> *)paths {
    NSLog(@"NegLab setPaths: 收到 %lu 个文件", (unsigned long)paths.count);
    if (!_stripView) {                          // 界面还没搭好：存起来，等就绪后再走一遍
        _pendingPaths = [paths copy];
        return;
    }                    // 界面还没搭好就先不走这条
    _paths = [NSMutableArray arrayWithArray:paths];
    _thumbs = [NSMutableArray array];
    for (NSUInteger i = 0; i < _paths.count; i++) [_thumbs addObject:(NSImage *)NSNull.null];
    _curIdx = 0; _curThumb = 0;
    _stripView.thumbs = _thumbs;
    _stripView.sel = 0;
    if (_paths.count) [self loadPath:_paths[0]];
    if (_paths.count > 1) [self buildThumbs];
}

- (void)jumpTo:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_paths.count) return;
    [self loadPath:_paths[(NSUInteger)i]];
}

// 缩略图一帧一帧在主线程做（performSelector 排队），不做后台线程 ——
// 避免上次那个「AppKit 方法在后台调用会抛异常」的坑。每帧之间隔 0.05s，
// 界面在两帧之间是响应的。36 帧全程约 10 秒，可接受。
- (void)buildThumbs {
    // ★ 同步循环跑完全部缩略图，不再用 performSelector 排队。
    //   排队版的问题：主线程忙时 performSelector 被推迟，链条可能断，
    //   表现为「39 张只出一张」。同步循环没有这个问题。
    for (NSUInteger i = 0; i < _paths.count; i++) {
        NSString *path = _paths[i];

        CGImageSourceRef src = CGImageSourceCreateWithURL(
            (CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!src) continue;
        CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (CFDictionaryRef)@{
            (NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (NSString *)kCGImageSourceCreateThumbnailWithTransform   : @YES,
            (NSString *)kCGImageSourceThumbnailMaxPixelSize          : @160 });
        CFRelease(src);
        if (!cg) continue;

        size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                                 kCGImageAlphaPremultipliedLast |
                                                 kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (!ctx) { CGImageRelease(cg); continue; }
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        uint8_t *px = (uint8_t *)CGBitmapContextGetData(ctx);

        // 简化反相：sRGB→线性→粗略片基扣除→去负片 gamma
        float *lin = malloc(sizeof(float) * w * h * 3);
        if (!lin) { CGContextRelease(ctx); CGImageRelease(cg); continue; }
        double t0[3] = {0, 0, 0};
        for (int c = 0; c < 3; c++) {
            float mx = 0;
            for (size_t j = 0; j < w * h; j++) {
                float v = negSrgbToLinear(px[j * 4 + c] / 255.0f);
                lin[j * 3 + c] = v;
                if (v > mx) mx = v;
            }
            t0[c] = (mx > 1e-6) ? mx * 0.98 : 1.0;
        }
        for (size_t j = 0; j < w * h; j++)
            for (int c = 0; c < 3; c++) {
                double T = lin[j * 3 + c] / (t0[c] > 1e-9 ? t0[c] : 1e-9);
                if (T < 1e-4) T = 1e-4;
                lin[j * 3 + c] = (float)pow(10.0, log10(T) / NEG_GAMMA_OUT);
            }
        CGContextRelease(ctx); CGImageRelease(cg);

        // 打包成 NSImage（主线程 —— 上次崩溃的教训）
        dispatch_async(dispatch_get_main_queue(), ^{
            CGColorSpaceRef csp = CGColorSpaceCreateDeviceRGB();
            CGContextRef c2 = CGBitmapContextCreate(NULL, w, h, 8, w * 4, csp,
                                                    kCGImageAlphaPremultipliedLast |
                                                    kCGBitmapByteOrder32Big);
            CGColorSpaceRelease(csp);
            if (!c2) { free(lin); return; }
            for (size_t j = 0; j < w * h; j++)
                for (int c = 0; c < 3; c++) {
                    float v = lin[j * 3 + c];
                    ((uint8_t *)CGBitmapContextGetData(c2))[j * 4 + c] =
                        (uint8_t)(negLinearToSrgb(v > 1 ? 1 : v) * 255.0f);
                }
            CGImageRef outImg = CGBitmapContextCreateImage(c2);
            CGContextRelease(c2);
            if (outImg) {
                NSImage *im = [[NSImage alloc] initWithCGImage:outImg
                                                          size:NSMakeSize(w, h)];
                CGImageRelease(outImg);
                if (i < self->_thumbs.count) self->_thumbs[i] = im;
                self->_stripView.needsDisplay = YES;
                if (i == self->_paths.count - 1)
                    [self setStatus:[NSString stringWithFormat:
                        @"%lu 张缩略图已就绪。点胶片条换片。",
                        (unsigned long)self->_paths.count]];
            }
            free(lin);
        });
    }
    [self setStatus:[NSString stringWithFormat:
        @"已装入 %lu 张，正在生成缩略图…", (unsigned long)_paths.count]];
}

- (void)openDoc:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = YES;
    p.canChooseDirectories = NO;
    p.message = @"选负片。可以一次选多张（按 ⌘ 点选，或 ⇧ 选范围）。";
    if ([p runModal] != NSModalResponseOK) return;
    NSMutableArray<NSString *> *ps = [NSMutableArray array];
    for (NSURL *u in p.URLs) if (u.isFileURL) [ps addObject:u.path];
    if (!ps.count) return;
    [ps sortUsingSelector:@selector(compare:)];
    [self setPaths:ps];
}

- (void)loadPath:(NSString *)path {
    if (!path.length || _loading) return;
    _loading = YES;
    _lblFile.stringValue = [NSString stringWithFormat:@"正在读 %@ …", path.lastPathComponent];
    _lblFileMeta.stringValue = @"正在解码，请稍候。";
    [self setStatus:@"正在解码。45 MB 的 TIFF 大约要一两秒。"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 块里不能引用 C 数组，所以在这一层就把它们变成 NSString
        NegFrame f; char enc[128] = {0}, err[256] = {0};
        int ok = negLoadFrame(path.UTF8String, &f, enc, sizeof(enc), err, sizeof(err));
        NegFrame px = {NULL, 0, 0};
        // C 数组进不了 block，用堆上的指针；生命周期交给下面那个主线程 block
        double *autoT0 = calloc(3, sizeof(double));
        if (!autoT0) autoT0 = NULL;
        if (autoT0) { autoT0[0] = autoT0[1] = autoT0[2] = 1.0; }
        if (ok == 0) {
            px = negDownsample(&f, PROXY_MAX_DIM);
            if (px.rgb && autoT0) negEstimateZero(px.rgb, px.w, px.h, 0.0005, autoT0);
        }
        NSString *encStr = @(enc), *errStr = @(err);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            if (ok != 0) {
                NSAlert *a = [NSAlert new];
                a.messageText = @"打不开这张负片";
                a.informativeText = [NSString stringWithFormat:
                    @"%@\n\n能读的：TIFF / PNG / JPEG，以及系统认得出来的相机 raw"
                    @"（ARW、CR3、NEF、RAF、DNG…）。\n"
                    @"若店家给的是别家的专有格式，请让他们重导一份 16-bit TIFF。", errStr];
                [a runModal];
                self->_lblFile.stringValue = @"未打开文件";
                [self setStatus:@"打开失败。"];
                free(autoT0);
                return;
            }
            negFreeFrame(&self->_full);
            negFreeFrame(&self->_proxy);
            self->_full = f;
            self->_proxy = px;
            for (int c = 0; c < 3; c++) self->_autoT0[c] = autoT0 ? autoT0[c] : 1.0;
            free(autoT0);
            [self->_greys removeAllObjects];
            [self->_canvas.marks removeAllObjects];
            self->_haveBase = NO;
            self->_mode = 0;
            self->_canvas.picking = NO;
            self->_currentPath = path;
            NSUInteger idx = [self->_paths indexOfObject:path];
            if (idx == NSNotFound) {
                self->_paths = [NSMutableArray arrayWithObject:path];
                self->_thumbs = [NSMutableArray arrayWithObject:(NSImage *)NSNull.null];
                self->_stripView.thumbs = self->_thumbs;
                idx = 0;
            }
            self->_curIdx = (NSInteger)idx;
            self->_stripView.sel = (NSInteger)idx;
            self->_segZero.selectedSegment = 0;   // ★ 不要在这里复位 _curThumb：

            self->_hasLockedT0 = NO;
            self->_chkLock.state = NSControlStateValueOff;
            self->_lblFile.stringValue = path.lastPathComponent;
            NSNumber *sz = [[NSFileManager defaultManager]
                            attributesOfItemAtPath:path error:nil][NSFileSize];
            self->_lblFileMeta.stringValue = [NSString stringWithFormat:
                @"%zu × %zu 像素　%.1f MB\n%@", f.w, f.h,
                sz ? sz.doubleValue / 1e6 : 0.0, encStr];
            [_win setTitle:path.lastPathComponent];
            [self setStatus:@"先把零点定下来。画面里有未曝光的片基就点它，最准。"];
            [self renderViews];
            if (self->_pendingCalib) {
                NSURL *u = self->_pendingCalib;
                self->_pendingCalib = nil;
                [self loadCalFromPath:u];
            }
        });
    });
}

// ── 取样 ───────────────────────────────────────────────────────────────────
// 与界面无关的一步：先在「全分辨率」上取样，再谈反相。
// 画面缩放不参与 —— 否则同一块灰在窗口大小不同时给出不同答案。
// 具体的抽样规则在 negSamplePatch() 里（tools/calib_cli 走的是同一个函数）。
- (void)sampleAt:(double)nx y:(double)ny out:(double *)out {
    negSamplePatch(&_full, nx, ny, 40, out);
}

- (void)handleClickX:(double)nx y:(double)ny {
    if (_full.rgb == NULL) return;
    if (_mode == 0) {
        [self setStatus:@"要取样，先按「在图上点片基」或「点中性灰」进入取点模式。"];
        return;
    }
    double s[3];
    [self sampleAt:nx y:ny out:s];
    NSString *kind = @"grey";
    if (_mode == 1) {
        for (int c = 0; c < 3; c++) _t0[c] = MAX(s[c], 1e-6);
        _haveBase = YES;
        _segZero.selectedSegment = 1;
        [self setStatus:@"零点已设为手动点选。接着去点中性灰解 γ。"];
        kind = @"base";
    } else {
        [_greys addObject:@{ @"nx": @(nx), @"ny": @(ny),
                             @"lin": @[ @(s[0]), @(s[1]), @(s[2]) ] }];
        [self setStatus:[NSString stringWithFormat:@"已点 %lu 块中性灰。%@",
                         (unsigned long)_greys.count,
                         _greys.count >= 2 ? @"可以按「解算 γ」了。" : @"至少两块，亮度要拉开。"]];
    }
    [_canvas.marks addObject:@{ @"nx": @(nx), @"ny": @(ny), @"kind": kind }];
    [_canvas setNeedsDisplay:YES];
    [self renderViews];
}

// ── 参数变化 ───────────────────────────────────────────────────────────────
- (void)armBase:(id)s {
    _mode = (_mode == 1) ? 0 : 1;
    _canvas.picking = (_mode != 0);
    [self setStatus:_mode == 1
        ? @"在图上点「未曝光的片基」—— 负片上最亮、最干净的那条边。"
        : @""];
}

- (void)armGrey:(id)s {
    _mode = (_mode == 2) ? 0 : 2;
    _canvas.picking = (_mode != 0);
    [self setStatus:_mode == 2
        ? @"点你确定是中性的灰块。多点几块、亮度拉开，都点在色块正中央。"
        : @""];
}

- (void)undoGrey:(id)s {
    if (!_greys.count) return;
    [_greys removeLastObject];
    for (NSInteger i = (NSInteger)_canvas.marks.count - 1; i >= 0; i--)
        if ([_canvas.marks[(NSUInteger)i][@"kind"] isEqualToString:@"grey"]) {
            [_canvas.marks removeObjectAtIndex:(NSUInteger)i];
            break;
        }
    [self renderViews];
}

- (void)zeroModeChanged:(id)s {
    if (_segZero.selectedSegment == 0) {
        _haveBase = NO;
        for (NSInteger i = (NSInteger)_canvas.marks.count - 1; i >= 0; i--)
            if ([_canvas.marks[(NSUInteger)i][@"kind"] isEqualToString:@"base"]) {
                [_canvas.marks removeObjectAtIndex:(NSUInteger)i];
                break;
            }
        [self setStatus:@"零点改用自动：取画面最亮的那 0.05%。黑白边干净的画面最准。"];
    } else {
        // ★ 选「手动点选」= 进入**等待态**：先允许用户去点，点了才会有值。
        //   旧写法在 _haveBase 为假时直接把选中项弹回「自动」并 return，
        //   于是用户一点它自己就跳回去 —— 现象就是「按钮点不动」。
        //   分段控件在这里是「模式选择」，不是「结果显示」。
        _mode = 1;                       // 1 = 等用户点片基
        _canvas.picking = YES;           // 光标切成取点状
        [self setStatus:@"请在图上点一下未曝光的片基（齿孔区、帧边透明条最准）。"];
    }
    [_canvas setNeedsDisplay:YES];
    [self refreshEnabled];
    [self renderViews];
}

- (void)manualGammaChanged:(id)s {
    _gamma[0] = MAX(_slGammaR.slider.doubleValue, 0.05);
    _gamma[2] = MAX(_slGammaB.slider.doubleValue, 0.05);
    _slGammaR.value.stringValue = [NSString stringWithFormat:@"%.3f", _gamma[0]];
    _slGammaB.value.stringValue = [NSString stringWithFormat:@"%.3f", _gamma[2]];
    [self renderViews];
}

- (void)paperChanged:(id)s { _paper = (int)_segPaper.selectedSegment; [self renderViews]; }

- (void)outputChanged:(id)s {
    [_slExposure refresh]; [_slY refresh]; [_slM refresh]; [_slC refresh];
    [self renderViews];
}

- (void)viewChanged:(id)s {
    _canvas.shown = _imgResult;   // 「原始负片」已删，恒显示结果
}

- (void)toggleView:(id)s {
    _segView.selectedSegment = (_segView.selectedSegment == 0) ? 1 : 0;
    [self viewChanged:nil];
}

// ── 零点 ───────────────────────────────────────────────────────────────────
// 自动零点在载入时就算好并缓存。它是「最亮 0.05% 的均值」，要过一遍 3×3 中值 +
// 两趟统计，拖动滑杆时每帧重算没必要，也会卡。
- (void)curT0:(double *)t0 {
    // ① 锁住的零点优先：店家把画幅裁掉、片基扫不进来时，用同批里某一帧
    //    （通常是专门空拍的那一格纯片基）量到的值，套给其余帧。
    //    这在数学上成立的前提是：同一批扫描里，片基在扫描件上的读数不变 ——
    //    也就是店家没有开逐帧自动曝光 / 自动白平衡。
    if (_hasLockedT0) {
        for (int c = 0; c < 3; c++) t0[c] = _lockedT0[c];
        return;
    }
    if (_haveBase) {
        for (int c = 0; c < 3; c++) t0[c] = _t0[c];
        return;
    }
    for (int c = 0; c < 3; c++) t0[c] = _autoT0[c];
}

- (void)lockToggled:(id)s {
    if (_chkLock.state == NSControlStateValueOn) {
        double t[3];
        _hasLockedT0 = NO;          // 先取「当前算出来的」那个值
        [self curT0:t];
        for (int c = 0; c < 3; c++) _lockedT0[c] = t[c];
        _hasLockedT0 = YES;
        [self setStatus:@"零点已锁住，之后每一帧都用它。换卷、换店家请先取消勾选。"];
    } else {
        _hasLockedT0 = NO;
        [self setStatus:@"零点已解锁，回到逐帧单独估计。"];
    }
    [self renderViews];
}

- (void)doFit:(id)sender {
    if (_greys.count < 2) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"还差一点";
        a.informativeText = @"至少要点两块中性灰，而且亮度要拉开。\n\n"
                            @"只点一块的话，「斜率」和「偏移」分不开 —— "
                            @"RawTherapee 的 Film Negative 也要求点两块，是同一个道理。";
        [a runModal];
        return;
    }
    double t0[3];
    [self curT0:t0];
    int n = (int)_greys.count;
    float *samples = malloc(sizeof(float) * (size_t)n * 3);
    if (!samples) return;
    for (int i = 0; i < n; i++) {
        NSArray *arr = _greys[(NSUInteger)i][@"lin"];
        for (int c = 0; c < 3; c++) samples[i * 3 + c] = [arr[c] floatValue];
    }
    NegCal cal;
    if (negFitGamma(samples, n, t0, &cal) == 0) {
        for (int c = 0; c < 3; c++) _gamma[c] = cal.gamma[c];
        _gamma[1] = 1.0;
        for (int c = 0; c < 3; c++) _offset[c] = cal.offset[c];
        _lRef = cal.lRef;
        _slGammaR.slider.doubleValue = _gamma[0];
        _slGammaB.slider.doubleValue = _gamma[2];
        _slGammaR.value.stringValue = [NSString stringWithFormat:@"%.3f", _gamma[0]];
        _slGammaB.value.stringValue = [NSString stringWithFormat:@"%.3f", _gamma[2]];

        double residual = negNeutralResidual(samples, n, t0, _gamma, _offset);
        BOOL good = cal.sigmaRatio < 0.06 && residual < 0.15;
        _lblFit.stringValue = [NSString stringWithFormat:
            @"γ = %.4f : 1 : %.4f　σ₂/σ₁ = %.2f%%　残差 %.3f 档\n%@",
            _gamma[0], _gamma[2], cal.sigmaRatio * 100, residual,
            good ? @"这批点足够中性。把标定存下来，同型号同链路长期复用。"
                 : @"偏大：这些点不够中性。换个位置重点，或先回头检查零点。"];
        _lblFit.textColor = good ? C_OK() : C_WARN();
        [self setStatus:@"γ 已解出。零点仍然每帧重定，γ 不用。"];
    } else {
        [self setStatus:@"解算失败：这批点退化（可能亮度全挤在一起）。"];
    }
    free(samples);
    [self renderViews];
}

// ── 标定的存取与说明 ───────────────────────────────────────────────────────
- (void)howToCalibrate:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = @"怎么标定 γ";
    a.informativeText =
        @"1. 打开「拍过色卡」的那一格负片。\n"
        @"2. 先定零点（点片基，或用自动）。\n"
        @"3. 按「点中性灰」，在卡上那条中性灰阶上依次点 2～6 块，亮度要拉开。\n"
        @"4. 按「解算 γ」。σ₂/σ₁ 小于 6%、残差小于 0.15 档就算过。\n"
        @"5. 按「存标定」。同型号、同店家的卷，下次直接「载入」就行。\n\n"
        @"为什么只点灰、不点彩色块：灰只约束一件事 —— 三通道的密度斜率之比，干净且可验证。\n"
        @"彩色块还牵涉「颜色像不像」，那是另一笔投入（透射靶 + 光谱数据 + DCP 配置）。\n"
        @"本项目解决的是中性与线性，不是颜色。";
    [a runModal];
}

- (void)saveCal:(id)s {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = @"neglab-calibration.json";
    p.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"json"] ];
    if ([p runModal] != NSModalResponseOK) return;
    double t0[3];
    [self curT0:t0];
    NSDictionary *d = @{
        @"app": @"NegLab", @"version": @"1.0",
        @"gamma": @[ @(_gamma[0]), @(1.0), @(_gamma[2]) ],
        @"offset": @[ @(_offset[0]), @(_offset[1]), @(_offset[2]) ],
        @"L_base": @(_lRef),
        @"zeropoint_used": @[ @(t0[0]), @(t0[1]), @(t0[2]) ],
        @"source": _currentPath.lastPathComponent ?: @"",
        @"note": @"γ 管一个「胶片型号 × 扫描或翻拍链路」，不用每卷重解。"
                 @"offset 只在与其同时解出的那个零点下才有效；换了零点请重点灰解一次。",
    };
    NSError *e = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                  options:NSJSONWritingPrettyPrinted error:&e];
    if (!data || ![data writeToURL:p.URL atomically:YES])
        [self setStatus:[NSString stringWithFormat:@"存不了：%@", e.localizedDescription]];
    else
        [self setStatus:[NSString stringWithFormat:@"已存 %@", p.URL.lastPathComponent]];
}

- (void)loadCal:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[ [UTType typeWithFilenameExtension:@"json"] ];
    if ([p runModal] != NSModalResponseOK) return;
    [self loadCalFromPath:p.URL];
}

// 载入标定。命令行第二参数也走这里（方便批量：open -a NegLab.app --args 照片.tif 标定.json）
- (void)loadCalFromPath:(NSURL *)url {
    NSData *d = [NSData dataWithContentsOfURL:url];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSArray *g = j[@"gamma"];
    if (!g) { [self setStatus:@"这个 json 里没有 gamma 字段。"]; return; }
    NSArray *o = j[@"offset"];
    _gamma[0] = [g[0] doubleValue];
    _gamma[1] = 1.0;
    _gamma[2] = [g[2] doubleValue];
    for (int c = 0; c < 3; c++) _offset[c] = o ? [o[c] doubleValue] : 0.0;
    _lRef = [j[@"L_base"] doubleValue];
    // 标定文件里记着解它时用的零点。有的话就存进锁定值，方便同批套用。
    NSArray *zp = j[@"zeropoint_used"];
    if (zp.count == 3) {
        for (int c = 0; c < 3; c++) _lockedT0[c] = [zp[c] doubleValue];
        _hasLockedT0 = YES;
        _chkLock.state = NSControlStateValueOn;
    }
    _slGammaR.slider.doubleValue = _gamma[0];
    _slGammaB.slider.doubleValue = _gamma[2];
    _slGammaR.value.stringValue = [NSString stringWithFormat:@"%.3f", _gamma[0]];
    _slGammaB.value.stringValue = [NSString stringWithFormat:@"%.3f", _gamma[2]];
    _lblFit.stringValue = [NSString stringWithFormat:
        @"γ = %.4f : 1 : %.4f（来自 %@）\n换了零点就请重新点灰解一次。",
        _gamma[0], _gamma[2], url.lastPathComponent];
    _lblFit.textColor = C_MUT();
    [self setStatus:@"标定已载入。"];
    [self renderViews];
}

- (void)clearAll:(id)s {
    [_greys removeAllObjects];
    [_canvas.marks removeAllObjects];
    _haveBase = NO;
    _mode = 0;
    _canvas.picking = NO;
    _offset[0] = _offset[1] = _offset[2] = 0;
    _lRef = 0;
    _segZero.selectedSegment = 0;
    _lblFit.stringValue = @"取样点已清空。γ 的滑杆值留着，可以手动调。";
    _lblFit.textColor = C_MUT();
    [self renderViews];
}

// ── 渲染 ───────────────────────────────────────────────────────────────────
// 显示映射：把 99.9 百分位当白点。反相后的 0 就是片基（正片里应为黑），
// 所以白点只能取画面自己最亮处；取 100% 会被单个高光点毁掉，99.9 是常用的折中。
// 导出与预览用同一个百分位，免得「所见非所得」。
static const double DISP_PCT = 99.9;

// 数字放大机的滤色片。单位 CC（1 CC = 0.01 密度），刻度用真放大机头的 Y/M/C。
// 滤色片吸收哪一段，就减哪一层曝光：Y→蓝层、M→绿层、C→红层。
// 方向与暗房一致：加 Y 偏蓝、加 M 偏绿、加 C 偏红。
// 数学上等价于把 o_c 换成 o_c + γ_c·d_c，所以 NegMath 不必改签名。
- (void)effOffset:(double *)o {
    double d[3] = { _slC.slider.doubleValue / 100.0,
                    _slM.slider.doubleValue / 100.0,
                    _slY.slider.doubleValue / 100.0 };
    for (int c = 0; c < 3; c++) o[c] = _offset[c] + _gamma[c] * d[c];
}

- (void)renderViews {
    if (!_proxy.rgb) { [self refreshEnabled]; return; }
    size_t n = _proxy.w * _proxy.h;
    float *o = malloc(sizeof(float) * n * 3);
    if (!o) return;

    // 「原始负片」只跟像素有关，与任何滑杆无关 —— 只在真的要看它时才算。
    // 拖滑杆时视图通常在「结果」上，这一支白白占了将近一半的开销。
    if (_segView.selectedSegment == 0) {
        memcpy(o, _proxy.rgb, sizeof(float) * n * 3);
        float hiO = negGreenPercentile(o, _proxy.w, _proxy.h, DISP_PCT);
        _imgOriginal = [self imageFromRGBA:negRGBA8(o, _proxy.w, _proxy.h,
                                                    hiO > 1e-6f ? hiO : 1e-6f)];
    }

    double t0[3];
    [self curT0:t0];
    memcpy(o, _proxy.rgb, sizeof(float) * n * 3);
    double off2[3]; [self effOffset:off2];
    negInvert(o, n, t0, _gamma, off2, _lRef, NEG_PI_CLIP_DEFAULT, _paper);
    // ★ 曝光必须作用在**白点之后**。白点取的是画面自己的百分位，
    //   在它之前乘一个整体系数会被下一次归一化精确抵消 —— 这就是「曝光调不动」的根因。
    //   物理上也对：曝光是印片机的曝光，作用在相纸上，不作用在负片上。
    float gain = pow(2.0, _slExposure.slider.doubleValue);
    float hiR = negGreenPercentile(o, _proxy.w, _proxy.h, DISP_PCT) / gain;
    _imgResult = [self imageFromRGBA:negRGBA8(o, _proxy.w, _proxy.h,
                                              hiR > 1e-6f ? hiR : 1e-6f)];
    free(o);

    _canvas.shown = _imgResult;   // 「原始负片」已删，恒显示结果
    [self readoutsWithT0:t0];
    [self refreshEnabled];
}

- (NSImage *)imageFromRGBA:(unsigned char *)rgba {
    if (!rgba) return nil;
    size_t w = _proxy.w, h = _proxy.h;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(rgba);
    if (!cg) return nil;
    NSImage *im = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize((CGFloat)w, (CGFloat)h)];
    CGImageRelease(cg);
    return im;
}

- (void)readoutsWithT0:(const double *)t0 {
    if (!_proxy.rgb) return;
    NSString *src = _hasLockedT0 ? @"锁定值"
                  : (_haveBase ? @"手动点选" : @"画面最亮 0.05%");
    _lblT0.stringValue = [NSString stringWithFormat:@"T0 = %.4f  %.4f  %.4f　%@",
                          t0[0], t0[1], t0[2], src];

    // 输入体检：抽样统计唯一取值数 + 撞密度上限的像素比例
    size_t n = _proxy.w * _proxy.h;
    size_t step = n / 150000 + 1;
    size_t m = 0;
    for (size_t i = 0; i < n; i += step) m++;
    int uni[3] = {0, 0, 0};
    float *tmp = malloc(sizeof(float) * m);
    if (tmp) {
        for (int c = 0; c < 3; c++) {
            size_t k = 0;
            for (size_t i = 0; i < n && k < m; i += step) tmp[k++] = _proxy.rgb[i * 3 + c];
            qsort(tmp, k, sizeof(float), cmpFloatAsc);
            for (size_t i = 0; i < k; i++) if (!i || tmp[i] != tmp[i - 1]) uni[c]++;
        }
        free(tmp);
    }
    double loT = pow(10.0, -NEG_PI_CLIP_DEFAULT);
    long capped = 0;
    for (size_t i = 0; i < n; i++)
        for (int c = 0; c < 3; c++) {
            double T = (double)_proxy.rgb[i * 3 + c] / (t0[c] > 1e-9 ? t0[c] : 1e-9);
            if (T <= loT) { capped++; break; }
        }
    int u = MIN(uni[0], MIN(uni[1], uni[2]));
    double pct = 100.0 * (double)capped / (double)n;
    NSString *verdict;
    NSColor *col = C_OK();
    if (u < 100) {
        verdict = [NSString stringWithFormat:
            @"某通道只有约 %d 个不同取值 —— 已被量化抠死，任何算法都只能猜。"
            @"让店家重扫成 16-bit。", u];
        col = C_WARN();
    } else if (pct > 10) {
        verdict = [NSString stringWithFormat:
            @"%.1f%% 的像素撞到密度上限 %.1f，高光或暗部会整片塌掉。",
            pct, NEG_PI_CLIP_DEFAULT];
        col = C_WARN();
    } else {
        verdict = [NSString stringWithFormat:@"输入尚可。撞密度上限 %.1f%%。", pct];
    }
    _lblHealth.stringValue = verdict;
    _lblHealth.textColor = col;
}

// ── 状态与步骤 ─────────────────────────────────────────────────────────────
- (void)setStatus:(NSString *)s {
    _lblStatus.stringValue = s ?: @"";
    _lblStatus.toolTip = s;
}

// 卡片标题兼作步骤指示：走到哪一步就把那张卡的标题染成强调色，已完成的转为常规色。
// 上一版是在侧栏顶上加一行「① 打开 ✓ ② 定零点 → ③ 解 γ → ④ 导出」，中文挤成两行；
// 现在把状态放回它本来该在的位置 —— 卡片自己身上。
- (void)refreshEnabled {
    BOOL has = (_proxy.rgb != NULL);
    _btnGrey.enabled = has;
    _btnUndo.enabled = (_greys.count > 0);
    _btnClearCal.enabled = has;
    _btnGrey.title = [NSString stringWithFormat:@"点中性灰（%lu 块）", (unsigned long)_greys.count];

    int step = 0;
    if (has) step = 1;
    if (has && (_haveBase || _segZero.selectedSegment == 0)) step = 2;
    if (_greys.count >= 2 && fabs(_gamma[0] - 1.0) > 1e-9) step = 3;

    NSArray<NegCard *> *cards = @[ _cardZero, _cardGamma, _cardOut ];
    for (NSUInteger i = 0; i < cards.count; i++) {
        int cardStep = (int)i + 1;
        NSColor *c = (cardStep == step) ? C_ACCENT()
                                       : (cardStep < step ? C_MUT() : C_FAINT());
        cards[i].titleLabel.textColor = c;
    }
}

// ── 导出 ───────────────────────────────────────────────────────────────────
- (void)exportDoc:(id)s {
    if (!_full.rgb) { [self setStatus:@"先打开一张负片。"]; return; }
    NSString *base = _currentPath.lastPathComponent.stringByDeletingPathExtension ?: @"negative";
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = [base stringByAppendingString:@"_positive.tif"];

    NSPopUpButton *fmt = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 268, 25)];
    [fmt addItemsWithTitles:@[ @"16-bit 线性 TIFF（留给自己调色）",
                               @"8-bit JPEG（直接看）",
                               @"8-bit PNG（直接看）" ]];
    NSStackView *acc = hstack(@[ mkLabel1(@"格式", F_BODY(), C_INK()), fmt ], 10);
    acc.frame = NSMakeRect(0, 0, 340, 44);
    acc.edgeInsets = NSEdgeInsetsMake(8, 16, 8, 16);
    p.accessoryView = acc;
    if ([p runModal] != NSModalResponseOK) return;

    NSInteger k = fmt.indexOfSelectedItem;
    NSString *ext = (k == 1) ? @"jpg" : (k == 2 ? @"png" : @"tif");
    NSURL *url = [[p.URL URLByDeletingPathExtension] URLByAppendingPathExtension:ext];

    size_t n = _full.w * _full.h;
    float *o = malloc(sizeof(float) * n * 3);
    if (!o) { [self setStatus:@"内存不够。"]; return; }
    double t0[3];
    [self curT0:t0];
    memcpy(o, _full.rgb, sizeof(float) * n * 3);
    double off2[3]; [self effOffset:off2];
    negInvert(o, n, t0, _gamma, off2, _lRef, NEG_PI_CLIP_DEFAULT, _paper);
    double gain = pow(2.0, _slExposure.slider.doubleValue);

    char err[256] = {0};
    int r;
    if (k == 0) {
        float hi = negGreenPercentile(o, _full.w, _full.h, DISP_PCT) / (float)gain;
        r = negSaveLinearTIFF(url.path.UTF8String, o, _full.w, _full.h,
                              hi > 1e-6f ? hi : 1e-6f, err, sizeof(err));
    } else {
        float hi = negGreenPercentile(o, _full.w, _full.h, DISP_PCT) / (float)gain;
        r = negSaveDisplay8(url.path.UTF8String, o, _full.w, _full.h,
                            hi > 1e-6f ? hi : 1e-6f, err, sizeof(err));
    }
    free(o);
    [self setStatus:(r == 0)
        ? [NSString stringWithFormat:@"已导出 %@", url.lastPathComponent]
        : [NSString stringWithFormat:@"导出失败：%s", err]];
}

// ── 使用说明 ───────────────────────────────────────────────────────────────
- (void)showGuide:(id)s {
    if (!_guide) {
        _guide = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 580)
                                             styleMask:(NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable)
                                               backing:NSBackingStoreBuffered defer:NO];
        _guide.releasedWhenClosed = NO;
        _guide.title = @"NegLab 使用说明";
        _guide.backgroundColor = NSColor.windowBackgroundColor;

        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 620, 540)];
        tv.editable = NO;
        tv.drawsBackground = NO;
        tv.textContainerInset = NSMakeSize(20, 18);
        tv.verticallyResizable = YES;
        tv.horizontallyResizable = NO;
        tv.autoresizingMask = NSViewWidthSizable;
        tv.textContainer.widthTracksTextView = YES;
        [tv.textStorage setAttributedString:[self guideText]];

        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 660, 550)];
        sv.hasVerticalScroller = YES;
        sv.drawsBackground = NO;
        sv.documentView = tv;
        sv.translatesAutoresizingMaskIntoConstraints = NO;
        [_guide.contentView addSubview:sv];
        [NSLayoutConstraint activateConstraints:@[
            [sv.leadingAnchor constraintEqualToAnchor:_guide.contentView.leadingAnchor],
            [sv.trailingAnchor constraintEqualToAnchor:_guide.contentView.trailingAnchor],
            [sv.topAnchor constraintEqualToAnchor:_guide.contentView.topAnchor],
            [sv.bottomAnchor constraintEqualToAnchor:_guide.contentView.bottomAnchor],
        ]];
        [_guide center];
    }
    [_guide makeKeyAndOrderFront:nil];
}

- (NSAttributedString *)guideText {
    NSMutableAttributedString *m = [NSMutableAttributedString new];
    // 每段自己补一个换行 —— paragraphSpacing 只加间距，不换行。
    void (^add)(NSString *, CGFloat, NSColor *, BOOL, CGFloat) =
      ^(NSString *s, CGFloat size, NSColor *c, BOOL bold, CGFloat after) {
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.paragraphSpacing = after;
        ps.lineSpacing = size * 0.38;
        [m appendAttributedString:[[NSAttributedString alloc]
            initWithString:[s stringByAppendingString:@"\n"]
                attributes:@{
                    NSFontAttributeName: bold ? [NSFont systemFontOfSize:size
                                                              weight:NSFontWeightSemibold]
                                              : [NSFont systemFontOfSize:size],
                    NSForegroundColorAttributeName: c,
                    NSParagraphStyleAttributeName: ps }]];
    };

    add(@"NegLab 使用说明", 19, C_INK(), YES, 6);
    add(@"一句话：先把参数定下来（零点、逐通道密度斜率、偏移），再谈反相用什么方法。"
        @"方法与方法之间的差别只有 0.1～0.3 档，而参数错了能差 5～20 档。",
        12.5, C_MUT(), NO, 18);

    add(@"第 1 步　打开", 15, C_INK(), YES, 5);
    add(@"把负片拖进窗口，或按 ⌘O。能读两类：\n"
        @"· 店家扫的扫描件。16-bit 的按「线性」解释，8-bit 的先反解 sRGB。\n"
        @"· 你自己翻拍的相机 raw。用系统自带解码器，并尽量关掉相机内置的对比度、"
        @"饱和度、高光恢复 —— 那些都是按通道施加的，会把密度斜率拧弯。",
        12.5, C_INK(), NO, 16);

    add(@"第 2 步　定零点", 15, C_INK(), YES, 5);
    add(@"零点 = 这一帧「密度为零」的那个透过率，负片上指未曝光的片基。\n"
        @"· 画面里有片基（没裁画幅）：按「在图上点片基」，点最亮、最干净的那条边。\n"
        @"· 没有片基（Noritsu、哈苏 X5 等掩膜机型常见）：在胶卷开头盖着镜头盖空拍一格，"
        @"那一格就是纯片基。让店家关掉全部自动项后扫出来，打开它点片基，"
        @"再勾上「锁住，供同一批的其余帧共用」。\n"
        @"· 最省事：「自动」，取画面最亮的那 0.05%。黑白边多的画面够准，有强光就会偏。\n"
        @"零点错了，后面用什么算法都救不回来。宁可多点一次。",
        12.5, C_INK(), NO, 16);

    add(@"第 3 步　解 γ（一个型号做一次）", 15, C_INK(), YES, 5);
    add(@"γ 是逐通道密度斜率之比，它管的是「胶片型号 × 洗扫链路」，不用每卷重做。\n\n"
        @"1. 按「点中性灰」，然后在负片上点你确定是中性的灰 —— 至少两块，亮度要拉开。\n"
        @"　 拍过色卡最好，直接点卡上那条灰阶；没拍就找画面里的白墙、水泥地、阴天天空。\n"
        @"　 每一块都点在正中央，别压在边缘上。\n"
        @"2. 按「解算 γ」。界面会给出 σ₂/σ₁：小于 6% 说明这批点确实够中性。\n"
        @"3. 按「存标定」。下次遇到同型号、同店家的卷，直接「载入」即可。\n\n"
        @"为什么只点灰、不点彩色块：灰只约束「三通道斜率之比」这一件事，干净且可验证。"
        @"彩色块还牵扯「颜色像不像」，那是另一笔投入（透射靶 + 光谱数据 + DCP 配置）。"
        @"本项目解决的是中性与线性，不是颜色。",
        12.5, C_INK(), NO, 16);

    add(@"第 4 步　微调与导出", 15, C_INK(), YES, 5);
    add(@"曝光和黑点只改明暗，不改中性，可以放心调。\n"
        @"导出两种：\n"
        @"· 16-bit 线性 TIFF：没套传输函数，留给 Photoshop 或达芬奇接着调。\n"
        @"· 8-bit JPEG / PNG：套好 sRGB 传输函数，能直接看、直接发。",
        12.5, C_INK(), NO, 16);

    add(@"两件容易搞混的事", 15, C_INK(), YES, 5);
    add(@"· 密度不是透过率。反相的本质是 D = −log₁₀(T)，不是 1−T。用 1−T 出来的正片，"
        @"灰阶会被压扁、暗部发闷。\n"
        @"· 零点每帧定，γ 一次定。把 γ 当成白平衡、每张都调，就是把一次性的东西"
        @"当成了每帧的东西，越调越乱。",
        12.5, C_INK(), NO, 16);

    add(@"一句话的诚实声明", 15, C_INK(), YES, 5);
    add(@"负片里没有标准答案。上面每一步的结果都以「你自己点的那几块中性灰」为准。"
        @"这个工具保证的是数学没错、参数可复核，它不能保证你的灰真的中性。",
        12.5, C_MUT(), NO, 4);
    return m;
}
@end

// ═══════════════════════════════════════════════ 入口

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1) gLaunchPath = [NSString stringWithUTF8String:argv[1]];
        if (argc > 2) gLaunchCalib = [NSString stringWithUTF8String:argv[2]];
        NSApplication *app = NSApplication.sharedApplication;
        NegApp *d = [NegApp new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
