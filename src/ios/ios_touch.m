/*
 * ios_touch.m -- on-screen controls for playing without a game controller.
 *
 * A transparent UIView over SDL's Metal view draws the controls and feeds a
 * virtual SDL game controller (SDL_JoystickAttachVirtualEx). The title reads
 * it through the ordinary SDL controller path (xinput_device.c), exactly as
 * it reads a DualSense, so nothing below the host knows about touch.
 *
 * Optimized for modern iPhones:
 *   - Ergonomic racing layout: Gas (RT) and Brake (LT) pedals at bottom-right,
 *     Action buttons A (Handbrake), X (NOS), B (Look Back), Y (Camera) placed
 *     conveniently for one-thumb rolling/tapping.
 *   - Floating analog stick on left half with smooth recentering.
 *   - Compact D-Pad at top-left.
 *   - Frosted-glass aesthetics with iconic Xbox colors and glowing feedback.
 *   - Modern haptics using UIImpactFeedbackGenerator (heavy for pedals, medium
 *     for action buttons).
 *   - Dynamic screen mode switcher (16:9 Fit, Fullscreen Stretch, Zoom).
 *   - Full safe-area awareness for Dynamic Island, notch, and home bar.
 */
#import <UIKit/UIKit.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "ios_scene.h"

enum CtlKind { CTL_BUTTON, CTL_TRIGGER, CTL_SPECIAL };

typedef struct {
    enum CtlKind kind;
    int          target;        /* SDL_GameControllerButton, _Axis, or special ID */
    const char  *label;
    const char  *sublabel;     /* subtitle badge, e.g. "RT", "LT" */
    int          round;         /* 1: circle, 0: rounded rect / capsule */
    uint32_t     colorHex;      /* primary accent color RGB */
} CtlDef;

enum {
    CTL_A = 0,
    CTL_B,
    CTL_X,
    CTL_Y,
    CTL_WHITE,
    CTL_BLACK,
    CTL_BACK,
    CTL_START,
    CTL_DPAD_UP,
    CTL_DPAD_DOWN,
    CTL_DPAD_LEFT,
    CTL_DPAD_RIGHT,
    CTL_BRAKE,
    CTL_GAS,
    CTL_SCREEN_MODE,
    NCTL
};

static const CtlDef k_ctls[NCTL] = {
    [CTL_A]           = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_A,             "E-BRAKE", "A",   0, 0x2ECC71 }, /* Handbrake / Accept */
    [CTL_B]           = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_B,             "LOOK",    "B",   0, 0xE74C3C }, /* Look Back / Cancel */
    [CTL_X]           = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_X,             "⚡ NOS",  "X",   0, 0x00E5FF }, /* Nitrous Oxide Boost */
    [CTL_Y]           = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_Y,             "CAM",     "Y",   0, 0xF1C40F }, /* Camera View / Reset */
    [CTL_WHITE]       = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_LEFTSHOULDER,  "🎵 MUSIC","LB",  0, 0xEEEEEE }, /* EA Trax Music Track (White/LB) */
    [CTL_BLACK]       = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, "🗺 MAP",  "RB",  0, 0x4A90E2 }, /* In-Game GPS Map (Black/RB) */
    [CTL_BACK]        = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_BACK,          "BACK ⧏", "",    0, 0xBDC3C7 }, /* Menu / Map */
    [CTL_START]       = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_START,         "START ⧐","",    0, 0xBDC3C7 }, /* Menu Pause */
    [CTL_DPAD_UP]     = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_DPAD_UP,       "▲",       "",    0, 0x85C1E9 }, /* D-Pad */
    [CTL_DPAD_DOWN]   = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_DPAD_DOWN,     "▼",       "",    0, 0x85C1E9 }, /* D-Pad */
    [CTL_DPAD_LEFT]   = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_DPAD_LEFT,     "◀",       "",    0, 0x85C1E9 }, /* D-Pad */
    [CTL_DPAD_RIGHT]  = { CTL_BUTTON,  SDL_CONTROLLER_BUTTON_DPAD_RIGHT,    "▶",       "",    0, 0x85C1E9 }, /* D-Pad */
    [CTL_BRAKE]       = { CTL_TRIGGER, SDL_CONTROLLER_AXIS_TRIGGERLEFT,     "BRAKE",   "LT",  0, 0xFF3D00 }, /* Cherry Red */
    [CTL_GAS]         = { CTL_TRIGGER, SDL_CONTROLLER_AXIS_TRIGGERRIGHT,    "GAS",     "RT",  0, 0x00E676 }, /* Electric Green */
    [CTL_SCREEN_MODE] = { CTL_SPECIAL, 1001,                                "⛶ FULL",  "",    0, 0x00E5FF }, /* Aspect Mode */
};

enum { CTL_STICK = -1 };

/* ── Screen Presentation Mode ─────────────────────────────────────── */

static int s_screen_mode = -1;

static NSString *getDocumentsPath(void)
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject;
}

int ios_get_screen_mode(void)
{
    if (s_screen_mode >= 0)
        return s_screen_mode;

    NSString *doc = getDocumentsPath();
    if (doc) {
        NSString *filePath = [doc stringByAppendingPathComponent:@"screen_mode.txt"];
        NSError *err = nil;
        NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&err];
        if (content && content.length > 0) {
            int val = [content intValue];
            if (val >= 0 && val <= 2) {
                s_screen_mode = val;
                return s_screen_mode;
            }
        }
    }

    const char *e = getenv("NFSU2_SCREEN_MODE");
    if (!e) e = getenv("RECOMP_SCREEN_MODE");
    if (e && *e >= '0' && *e <= '2') {
        s_screen_mode = *e - '0';
        return s_screen_mode;
    }

    /* Default to 1 (Fullscreen Stretch / Fill for modern iPhones) */
    s_screen_mode = 1;
    return s_screen_mode;
}

void ios_set_screen_mode(int mode)
{
    if (mode < 0 || mode > 2)
        mode = 0;
    s_screen_mode = mode;
    NSString *doc = getDocumentsPath();
    if (doc) {
        NSString *filePath = [doc stringByAppendingPathComponent:@"screen_mode.txt"];
        NSString *content = [NSString stringWithFormat:@"%d\n", s_screen_mode];
        [content writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

int ios_cycle_screen_mode(void)
{
    int cur = ios_get_screen_mode();
    int next = (cur + 1) % 3;
    ios_set_screen_mode(next);
    return next;
}

/* ── Virtual Game Controller ──────────────────────────────────────── */

static SDL_Joystick *s_vpad;

static void vpad_attach(void)
{
    SDL_VirtualJoystickDesc d;
    int index;

    if (s_vpad)
        return;
    SDL_zero(d);
    d.version  = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    d.type     = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    d.naxes    = SDL_CONTROLLER_AXIS_MAX;
    d.nbuttons = SDL_CONTROLLER_BUTTON_DPAD_RIGHT + 1;
    d.name     = "Touch Controls";
    index = SDL_JoystickAttachVirtualEx(&d);
    s_vpad = index >= 0 ? SDL_JoystickOpen(index) : NULL;
    if (!s_vpad)
        fprintf(stderr, "[ios] touch controller: %s\n", SDL_GetError());
}

static void vpad_detach(void)
{
    SDL_JoystickID id;

    if (!s_vpad)
        return;
    id = SDL_JoystickInstanceID(s_vpad);
    SDL_JoystickClose(s_vpad);
    s_vpad = NULL;
    for (int i = 0; i < SDL_NumJoysticks(); i++)
        if (SDL_JoystickGetDeviceInstanceID(i) == id) {
            SDL_JoystickDetachVirtual(i);
            break;
        }
}

static void vpad_axis(int axis, float v)        /* -1..1 (triggers 0..1) */
{
    Sint16 s;

    if (!s_vpad)
        return;
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    if (axis == SDL_CONTROLLER_AXIS_TRIGGERLEFT || axis == SDL_CONTROLLER_AXIS_TRIGGERRIGHT)
        s = (Sint16)(SDL_JOYSTICK_AXIS_MIN + v * (SDL_JOYSTICK_AXIS_MAX - SDL_JOYSTICK_AXIS_MIN));
    else
        s = (Sint16)(v * SDL_JOYSTICK_AXIS_MAX);
    SDL_JoystickSetVirtualAxis(s_vpad, axis, s);
}

static void vpad_button(int button, int down)
{
    if (s_vpad)
        SDL_JoystickSetVirtualButton(s_vpad, button, down ? SDL_PRESSED : SDL_RELEASED);
}

static UIColor *colorFromHex(uint32_t hex, CGFloat alpha)
{
    CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
    CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
    CGFloat b = (hex & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:alpha];
}

/* ── NFSTouchView Interface ───────────────────────────────────────── */

@interface NFSTouchView : UIView
- (void)releaseAll;
- (void)updateScreenModeLabel;
- (void)showToast:(NSString *)msg;
@end

@implementation NFSTouchView {
    CAShapeLayer *_shape[NCTL];
    CATextLayer  *_text[NCTL];
    CATextLayer  *_subtext[NCTL];
    CGRect        _frame[NCTL];
    int           _held[NCTL];
    CAShapeLayer *_stickBase, *_stickKnob;
    CGPoint       _stickHome, _stickCentre;
    CGFloat       _stickRadius;
    UITouch      *_stickTouch;
    NSMapTable<UITouch *, NSNumber *> *_bound;
    UIImpactFeedbackGenerator *_hapticLight;
    UIImpactFeedbackGenerator *_hapticMedium;
    UIImpactFeedbackGenerator *_hapticHeavy;
    UILabel      *_toastLabel;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _bound = [NSMapTable weakToStrongObjectsMapTable];

    _hapticLight = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _hapticMedium = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    _hapticHeavy = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [_hapticLight prepare];
    [_hapticMedium prepare];
    [_hapticHeavy prepare];

    CGFloat scale = UIScreen.mainScreen.nativeScale;
    if (scale < 1.0) scale = UIScreen.mainScreen.scale;

    for (int i = 0; i < NCTL; i++) {
        _shape[i] = [CAShapeLayer layer];
        _shape[i].strokeColor = colorFromHex(k_ctls[i].colorHex, 0.85).CGColor;
        _shape[i].fillColor = colorFromHex(k_ctls[i].colorHex, 0.20).CGColor;
        _shape[i].lineWidth = 2.0;
        _shape[i].shadowColor = colorFromHex(k_ctls[i].colorHex, 1.0).CGColor;
        _shape[i].shadowOffset = CGSizeZero;
        _shape[i].shadowRadius = 8.0;
        _shape[i].shadowOpacity = 0.0;
        [self.layer addSublayer:_shape[i]];

        _text[i] = [CATextLayer layer];
        _text[i].string = [NSString stringWithUTF8String:k_ctls[i].label];
        _text[i].alignmentMode = kCAAlignmentCenter;
        _text[i].contentsScale = scale;
        _text[i].foregroundColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;

        if (i == CTL_X) {
            _text[i].fontSize = 17;
            _text[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:17 weight:UIFontWeightHeavy];
        } else if (i == CTL_A) {
            _text[i].fontSize = 13;
            _text[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
        } else if (i == CTL_B || i == CTL_Y) {
            _text[i].fontSize = 13;
            _text[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        } else if (i == CTL_GAS || i == CTL_BRAKE) {
            _text[i].fontSize = 16;
            _text[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
        } else if (i >= CTL_DPAD_UP && i <= CTL_DPAD_RIGHT) {
            _text[i].fontSize = 18;
            _text[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        } else {
            _text[i].fontSize = 12;
            _text[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        }
        [self.layer addSublayer:_text[i]];

        if (k_ctls[i].sublabel && strlen(k_ctls[i].sublabel) > 0) {
            _subtext[i] = [CATextLayer layer];
            _subtext[i].string = [NSString stringWithUTF8String:k_ctls[i].sublabel];
            _subtext[i].alignmentMode = kCAAlignmentCenter;
            _subtext[i].contentsScale = scale;
            _subtext[i].foregroundColor = [UIColor colorWithWhite:1.0 alpha:0.80].CGColor;
            _subtext[i].fontSize = 11;
            _subtext[i].font = (__bridge CFTypeRef)[UIFont systemFontOfSize:11 weight:UIFontWeightBold];
            [self.layer addSublayer:_subtext[i]];
        }
    }

    /* Stick base and knob */
    _stickBase = [CAShapeLayer layer];
    _stickBase.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.60].CGColor;
    _stickBase.fillColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    _stickBase.lineWidth = 2.0;
    _stickBase.shadowColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.6].CGColor;
    _stickBase.shadowOffset = CGSizeZero;
    _stickBase.shadowRadius = 6.0;
    _stickBase.shadowOpacity = 0.5;
    [self.layer addSublayer:_stickBase];

    _stickKnob = [CAShapeLayer layer];
    _stickKnob.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.90].CGColor;
    _stickKnob.fillColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    _stickKnob.lineWidth = 2.5;
    _stickKnob.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.8].CGColor;
    _stickKnob.shadowOffset = CGSizeZero;
    _stickKnob.shadowRadius = 8.0;
    _stickKnob.shadowOpacity = 0.6;
    [self.layer addSublayer:_stickKnob];

    return self;
}

- (void)placeControl:(int)i rect:(CGRect)r
{
    _frame[i] = r;
    CGFloat corner = 14;
    if (i == CTL_GAS || i == CTL_BRAKE) corner = 20;
    else if (i == CTL_X || i == CTL_A) corner = 16;
    else if (i == CTL_B || i == CTL_Y) corner = 14;
    else if (i == CTL_WHITE || i == CTL_BLACK || i == CTL_BACK || i == CTL_START || i == CTL_SCREEN_MODE) corner = 14;

    _shape[i].path = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:corner].CGPath;

    if (_subtext[i]) {
        CGFloat th = 18, sh = 12;
        CGFloat totalH = th + sh + 2;
        CGFloat startY = CGRectGetMidY(r) - totalH / 2;
        _text[i].frame = CGRectMake(r.origin.x, startY, r.size.width, th);
        _subtext[i].frame = CGRectMake(r.origin.x, startY + th + 2, r.size.width, sh);
    } else {
        CGFloat lh = r.size.height * 0.55;
        if (lh > 24) lh = 24;
        _text[i].frame = CGRectMake(r.origin.x, CGRectGetMidY(r) - lh / 2, r.size.width, lh);
    }
}

- (void)drawStick
{
    CGFloat r = _stickRadius, k = r * 0.42;

    /* Base with cardinal tick marks (crosshair) */
    UIBezierPath *basePath = [UIBezierPath bezierPathWithOvalInRect:
                              CGRectMake(_stickCentre.x - r, _stickCentre.y - r, 2 * r, 2 * r)];
    CGFloat tickLen = 8;
    [basePath moveToPoint:CGPointMake(_stickCentre.x, _stickCentre.y - r)];
    [basePath addLineToPoint:CGPointMake(_stickCentre.x, _stickCentre.y - r + tickLen)];
    [basePath moveToPoint:CGPointMake(_stickCentre.x, _stickCentre.y + r)];
    [basePath addLineToPoint:CGPointMake(_stickCentre.x, _stickCentre.y + r - tickLen)];
    [basePath moveToPoint:CGPointMake(_stickCentre.x - r, _stickCentre.y)];
    [basePath addLineToPoint:CGPointMake(_stickCentre.x - r + tickLen, _stickCentre.y)];
    [basePath moveToPoint:CGPointMake(_stickCentre.x + r, _stickCentre.y)];
    [basePath addLineToPoint:CGPointMake(_stickCentre.x + r - tickLen, _stickCentre.y)];
    _stickBase.path = basePath.CGPath;

    if (!_stickTouch) {
        _stickKnob.path = [UIBezierPath bezierPathWithOvalInRect:
                           CGRectMake(_stickCentre.x - k, _stickCentre.y - k, 2 * k, 2 * k)].CGPath;
    }
}

- (void)updateScreenModeLabel
{
    int sm = ios_get_screen_mode();
    NSString *txt = @"⛶ FULL";
    if (sm == 0) txt = @"⛶ 16:9";
    else if (sm == 2) txt = @"⛶ ZOOM";
    _text[CTL_SCREEN_MODE].string = txt;
}

- (void)showToast:(NSString *)message
{
    if (!_toastLabel) {
        _toastLabel = [[UILabel alloc] init];
        _toastLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        _toastLabel.textColor = UIColor.whiteColor;
        _toastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _toastLabel.textAlignment = NSTextAlignmentCenter;
        _toastLabel.layer.cornerRadius = 14;
        _toastLabel.layer.masksToBounds = YES;
        _toastLabel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
        _toastLabel.layer.borderWidth = 1.0;
        [self addSubview:_toastLabel];
    }
    _toastLabel.text = message;
    [_toastLabel sizeToFit];
    CGFloat w = _toastLabel.bounds.size.width + 28;
    CGFloat h = 32;
    CGFloat top = self.safeAreaInsets.top + 46;
    _toastLabel.frame = CGRectMake((self.bounds.size.width - w) / 2, top, w, h);
    _toastLabel.alpha = 1.0;
    _toastLabel.hidden = NO;

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:1.4];
}

- (void)hideToast
{
    [UIView animateWithDuration:0.3 animations:^{
        self->_toastLabel.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (finished)
            self->_toastLabel.hidden = YES;
    }];
}

/* Laid out dynamically inside safe area insets for modern landscape iPhones. */
- (void)layoutSubviews
{
    [super layoutSubviews];

    UIEdgeInsets in = self.safeAreaInsets;
    CGFloat safeL = MAX(in.left, 16);
    CGFloat safeR = self.bounds.size.width - MAX(in.right, 16);
    CGFloat safeT = MAX(in.top, 8);
    CGFloat safeB = self.bounds.size.height - MAX(in.bottom, 12);
    CGFloat midX = self.bounds.size.width / 2;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    /* ── Right side: Ergonomic Two-Column Racing Layout ── */
    /* Gas Pedal (bottom-right) */
    CGFloat w_gas = 80, h_gas = 120;
    CGRect r_gas = CGRectMake(safeR - w_gas, safeB - h_gas, w_gas, h_gas);

    /* Brake Pedal (to the left of Gas) */
    CGFloat w_brake = 76, h_brake = 105;
    CGRect r_brake = CGRectMake(safeR - w_gas - 14 - w_brake, safeB - h_brake, w_brake, h_brake);

    /* ⚡ NOS (X) - Prominent, glowing Nitrous Oxide boost button directly above Gas */
    CGFloat h_nos = 52;
    CGRect r_nos = CGRectMake(safeR - w_gas, safeB - h_gas - 12 - h_nos, w_gas, h_nos);

    /* E-BRAKE (A) - Handbrake button directly above Brake */
    CGFloat h_a = 52;
    CGRect r_a = CGRectMake(safeR - w_gas - 14 - w_brake, safeB - h_brake - 12 - h_a, w_brake, h_a);

    /* LOOK BACK (B) - Directly above NOS */
    CGFloat h_b = 44;
    CGRect r_b = CGRectMake(safeR - w_gas, safeB - h_gas - 12 - h_nos - 10 - h_b, w_gas, h_b);

    /* CAMERA (Y) - Directly above E-BRAKE */
    CGFloat h_y = 44;
    CGRect r_y = CGRectMake(safeR - w_gas - 14 - w_brake, safeB - h_brake - 12 - h_a - 10 - h_y, w_brake, h_y);

    /* Shoulder buttons: 🎵 MUSIC (White/LB) & 🗺 MAP (Black/RB) at upper right */
    CGFloat s_w = 78, s_h = 30;
    CGRect r_white = CGRectMake(safeR - s_w * 2 - 10, safeT + 4, s_w, s_h);
    CGRect r_black = CGRectMake(safeR - s_w, safeT + 4, s_w, s_h);

    /* Top center controls: Back, Screen Mode, Start */
    CGFloat top_h = 30;
    CGRect r_back = CGRectMake(midX - 126, safeT + 4, 74, top_h);
    CGRect r_screen = CGRectMake(midX - 44, safeT + 4, 88, top_h);
    CGRect r_start = CGRectMake(midX + 52, safeT + 4, 74, top_h);

    /* Left side: D-pad at upper left */
    CGFloat d = 42;
    CGFloat dx = safeL + 64, dy = safeT + 80;
    CGFloat d_dist = 36;
    CGRect r_dup = CGRectMake(dx - d/2, dy - d_dist - d/2, d, d);
    CGRect r_ddn = CGRectMake(dx - d/2, dy + d_dist - d/2, d, d);
    CGRect r_dl  = CGRectMake(dx - d_dist - d/2, dy - d/2, d, d);
    CGRect r_dr  = CGRectMake(dx + d_dist - d/2, dy - d/2, d, d);

    /* Place all controls */
    [self placeControl:CTL_A rect:r_a];
    [self placeControl:CTL_B rect:r_b];
    [self placeControl:CTL_X rect:r_x];
    [self placeControl:CTL_Y rect:r_y];
    [self placeControl:CTL_WHITE rect:r_white];
    [self placeControl:CTL_BLACK rect:r_black];
    [self placeControl:CTL_BACK rect:r_back];
    [self placeControl:CTL_START rect:r_start];
    [self placeControl:CTL_DPAD_UP rect:r_dup];
    [self placeControl:CTL_DPAD_DOWN rect:r_ddn];
    [self placeControl:CTL_DPAD_LEFT rect:r_dl];
    [self placeControl:CTL_DPAD_RIGHT rect:r_dr];
    [self placeControl:CTL_BRAKE rect:r_brake];
    [self placeControl:CTL_GAS rect:r_gas];
    [self placeControl:CTL_SCREEN_MODE rect:r_screen];

    [self updateScreenModeLabel];

    /* Left analog stick (steering) */
    _stickRadius = 66;
    _stickHome = CGPointMake(safeL + 76, safeB - 76);
    if (!_stickTouch)
        _stickCentre = _stickHome;
    [self drawStick];

    [CATransaction commit];
}

- (int)controlAt:(CGPoint)p
{
    int best = -2;
    CGFloat bestDist = 1e9;
    for (int i = 0; i < NCTL; i++) {
        CGFloat pad = 14;
        if (i == CTL_GAS || i == CTL_BRAKE) pad = 12;
        CGRect hitRect = CGRectInset(_frame[i], -pad, -pad);
        if (CGRectContainsPoint(hitRect, p)) {
            CGPoint center = CGPointMake(CGRectGetMidX(_frame[i]), CGRectGetMidY(_frame[i]));
            CGFloat dx = p.x - center.x, dy = p.y - center.y;
            CGFloat dist = dx * dx + dy * dy;
            if (dist < bestDist) {
                bestDist = dist;
                best = i;
            }
        }
    }
    if (best >= 0)
        return best;

    /* Left steering zone: left 48% of screen, below the top bar */
    UIEdgeInsets in = self.safeAreaInsets;
    if (p.x < self.bounds.size.width * 0.48 && p.y > MAX(in.top, 8) + 38)
        return CTL_STICK;

    return -2;
}

- (void)setHeld:(int)i delta:(int)delta
{
    int was = _held[i] > 0;

    _held[i] += delta;
    if (_held[i] < 0)
        _held[i] = 0;
    if ((_held[i] > 0) == was)
        return;

    if (!was) {
        if (i == CTL_GAS || i == CTL_BRAKE || i == CTL_X)
            [_hapticHeavy impactOccurred];
        else if (i == CTL_A || i == CTL_B || i == CTL_Y ||
                 (i >= CTL_DPAD_UP && i <= CTL_DPAD_RIGHT))
            [_hapticMedium impactOccurred];
        else
            [_hapticLight impactOccurred];
    }

    if (k_ctls[i].kind == CTL_SPECIAL) {
        if (!was && k_ctls[i].target == 1001) {
            int new_mode = ios_cycle_screen_mode();
            [self updateScreenModeLabel];
            const char *msg = "Screen: 16:9 Fit";
            if (new_mode == 1) msg = "Screen: Fullscreen Fill";
            else if (new_mode == 2) msg = "Screen: Zoom (No Bars)";
            [self showToast:[NSString stringWithUTF8String:msg]];
        }
    } else if (k_ctls[i].kind == CTL_TRIGGER) {
        vpad_axis(k_ctls[i].target, was ? 0.0f : 1.0f);
    } else {
        vpad_button(k_ctls[i].target, !was);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    uint32_t color = k_ctls[i].colorHex;
    if (!was) {
        _shape[i].fillColor = colorFromHex(color, 0.65).CGColor;
        _shape[i].strokeColor = colorFromHex(color, 1.0).CGColor;
        _shape[i].lineWidth = 2.5;
        _shape[i].shadowOpacity = 0.85;
    } else {
        _shape[i].fillColor = colorFromHex(color, 0.20).CGColor;
        _shape[i].strokeColor = colorFromHex(color, 0.85).CGColor;
        _shape[i].lineWidth = 2.0;
        _shape[i].shadowOpacity = 0.0;
    }
    [CATransaction commit];
}

- (void)moveStick:(CGPoint)p
{
    CGFloat dx = p.x - _stickCentre.x, dy = p.y - _stickCentre.y;
    CGFloat len = sqrt(dx * dx + dy * dy), r = _stickRadius, k = r * 0.42;

    if (len > r) {
        dx *= r / len;
        dy *= r / len;
    }
    vpad_axis(SDL_CONTROLLER_AXIS_LEFTX, (float)(dx / r));
    vpad_axis(SDL_CONTROLLER_AXIS_LEFTY, (float)(dy / r));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _stickKnob.path = [UIBezierPath bezierPathWithOvalInRect:
                       CGRectMake(_stickCentre.x + dx - k, _stickCentre.y + dy - k, 2 * k, 2 * k)].CGPath;
    [CATransaction commit];
}

- (void)endStick
{
    _stickTouch = nil;
    _stickCentre = _stickHome;
    vpad_axis(SDL_CONTROLLER_AXIS_LEFTX, 0);
    vpad_axis(SDL_CONTROLLER_AXIS_LEFTY, 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self drawStick];
    [CATransaction commit];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        int c = [self controlAt:p];
        if (c >= 0) {
            [_bound setObject:@(c) forKey:t];
            [self setHeld:c delta:+1];
        } else if (c == CTL_STICK && !_stickTouch) {
            CGFloat r = _stickRadius;
            _stickTouch = t;
            _stickCentre = CGPointMake(MAX(p.x, r), MIN(MAX(p.y, r), self.bounds.size.height - r));
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self drawStick];
            [CATransaction commit];
            [self moveStick:p];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        NSNumber *b;
        int c;

        if (t == _stickTouch) {
            [self moveStick:p];
            continue;
        }
        b = [_bound objectForKey:t];
        if (!b)
            continue;
        c = [self controlAt:p];
        if (c >= 0 && c != b.intValue) {
            [self setHeld:b.intValue delta:-1];
            [_bound setObject:@(c) forKey:t];
            [self setHeld:c delta:+1];
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches) {
        NSNumber *b = [_bound objectForKey:t];
        if (t == _stickTouch)
            [self endStick];
        if (b) {
            [self setHeld:b.intValue delta:-1];
            [_bound removeObjectForKey:t];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEnded:touches withEvent:event];
}

- (void)releaseAll
{
    for (int i = 0; i < NCTL; i++)
        if (_held[i])
            [self setHeld:i delta:-_held[i]];
    [_bound removeAllObjects];
    if (_stickTouch)
        [self endStick];
}
@end

static NFSTouchView *s_view;
static int           s_always;          /* NFSU2_TOUCH=2 */

static int physical_controllers(void)
{
    int n = 0;
    for (int i = 0; i < SDL_NumJoysticks(); i++)
        if (!SDL_JoystickIsVirtual(i) && SDL_IsGameController(i))
            n++;
    return n;
}

void ios_touch_controllers_changed(void)
{
    int show;

    if (!s_view)
        return;
    show = s_always || physical_controllers() == 0;
    for (int i = 0; i < SDL_NumJoysticks(); i++)
        fprintf(stderr, "[ios] joystick %d: %s%s%s\n", i,
                SDL_JoystickNameForIndex(i) ? SDL_JoystickNameForIndex(i) : "?",
                SDL_JoystickIsVirtual(i) ? " (virtual)" : "",
                SDL_IsGameController(i) ? "" : " (not a game controller)");
    if (show == !s_view.hidden)
        return;
    if (show) {
        vpad_attach();
    } else {
        [s_view releaseAll];
        vpad_detach();
    }
    s_view.hidden = !show;
    fprintf(stderr, "[ios] touch controls %s\n", show ? "on" : "off (controller connected)");
}

void ios_touch_attach(SDL_Window *window)
{
    SDL_SysWMinfo info;
    const char *e = getenv("NFSU2_TOUCH");
    UIView *root;

    if (e && strcmp(e, "0") == 0)
        return;
    s_always = e && strcmp(e, "2") == 0;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_UIKIT)
        return;
    root = info.info.uikit.window.rootViewController.view;
    if (!root)
        return;
    if (!s_view) {
        s_view = [[NFSTouchView alloc] initWithFrame:root.bounds];
        s_view.hidden = YES;
        [root addSubview:s_view];
    }
    [root bringSubviewToFront:s_view];
    ios_touch_controllers_changed();
}
