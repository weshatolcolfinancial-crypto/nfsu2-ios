/*
 * ios_import.m -- bring the user's own extracted disc into the app.
 *
 * Runs before the title boots, when NFSU2_GAME_DIR (Documents/game) has no
 * default.xbe: a plain screen asks for the folder holding the extracted
 * Xbox disc (default.xbe, NFSUNDER/, ...) through the system folder picker,
 * copies it with a progress bar into <game>.import, checks that default.xbe
 * is the NTSC-U build the lifted code was made from, and only then moves it
 * into place. Copying through Finder or the Files app into Documents/game
 * still works and skips all this. NFSU2_IMPORT_FROM=<folder> starts the
 * same import from that folder without the picker (the Simulator can read
 * the Mac's disc folder: tests).
 *
 * Main thread only for UIKit; the copy runs on a background queue. The
 * caller's main() turns the run loop here until the game is in place.
 */
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "ios_scene.h"

/* The XBE the lifted code in gen/ comes from (docs/IOS_PORT_LOG.md). */
#define XBE_SIZE 4038656ull
#define XBE_SHA1 "428b5a70b9400f19cc5be7679db6c72a6f80a1c9"
#define COPY_CHUNK (4u << 20)

static NSString *xbe_sha1(NSString *path)
{
    unsigned char md[CC_SHA1_DIGEST_LENGTH];
    NSMutableString *hex = [NSMutableString string];
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    char buf[1 << 16];
    size_t n;
    CC_SHA1_CTX c;

    if (!f)
        return nil;
    /* Identifies a known file; nothing here relies on SHA-1 for security. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1_Init(&c);
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        CC_SHA1_Update(&c, buf, (CC_LONG)n);
    CC_SHA1_Final(md, &c);
#pragma clang diagnostic pop
    fclose(f);
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", md[i]];
    return hex;
}

static NSString *find_xbe_in_dir(NSFileManager *fm, NSString *dirPath)
{
    BOOL isDir = NO;
    if (!dirPath || ![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir)
        return nil;
    NSString *direct = [dirPath stringByAppendingPathComponent:@"default.xbe"];
    if ([fm fileExistsAtPath:direct])
        return direct;
    direct = [dirPath stringByAppendingPathComponent:@"DEFAULT.XBE"];
    if ([fm fileExistsAtPath:direct])
        return direct;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    for (NSString *name in entries) {
        if ([name.lowercaseString isEqualToString:@"default.xbe"])
            return [dirPath stringByAppendingPathComponent:name];
    }
    return nil;
}

static void ensure_canonical_xbe(NSFileManager *fm, NSString *dirPath, NSString *xbePath)
{
    NSString *canonical = [dirPath stringByAppendingPathComponent:@"default.xbe"];
    if (![xbePath isEqualToString:canonical] && ![fm fileExistsAtPath:canonical]) {
        [fm moveItemAtPath:xbePath toPath:canonical error:nil];
    }
}

/* Automatically search Documents/ and its subdirectories for default.xbe.
 * Returns the directory containing default.xbe if found, or nil. */
static NSString *auto_detect_game_directory(NSString *configuredGameDir)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *xbe;

    /* 1. Check configured game directory (Documents/game) */
    if ((xbe = find_xbe_in_dir(fm, configuredGameDir))) {
        ensure_canonical_xbe(fm, configuredGameDir, xbe);
        return configuredGameDir;
    }

    /* 2. Check parent Documents/ folder directly */
    NSString *docsDir = [configuredGameDir stringByDeletingLastPathComponent];
    if ((xbe = find_xbe_in_dir(fm, docsDir))) {
        ensure_canonical_xbe(fm, docsDir, xbe);
        return docsDir;
    }

    /* 3. Check immediate subdirectories of Documents/ (e.g. Documents/NFSU2, Documents/extracted) */
    NSArray<NSString *> *subdirs = [fm contentsOfDirectoryAtPath:docsDir error:nil];
    for (NSString *name in subdirs) {
        if ([name isEqualToString:@"game"])
            continue;
        NSString *subPath = [docsDir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:subPath isDirectory:&isDir] && isDir) {
            if ((xbe = find_xbe_in_dir(fm, subPath))) {
                ensure_canonical_xbe(fm, subPath, xbe);
                return subPath;
            }
            /* 4. Check 1 more level deep (e.g. Documents/NFSU2/game/default.xbe) */
            NSArray<NSString *> *subSub = [fm contentsOfDirectoryAtPath:subPath error:nil];
            for (NSString *subName in subSub) {
                NSString *deepPath = [subPath stringByAppendingPathComponent:subName];
                if ([fm fileExistsAtPath:deepPath isDirectory:&isDir] && isDir) {
                    if ((xbe = find_xbe_in_dir(fm, deepPath))) {
                        ensure_canonical_xbe(fm, deepPath, xbe);
                        return deepPath;
                    }
                }
            }
        }
    }

    return nil;
}

/* The picked folder, or a folder right inside it, that holds default.xbe.
 * Also handles if the user directly picked default.xbe or a file inside the disc. */
static NSURL *disc_root(NSURL *picked)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    NSURL *candidate = picked;

    if (![fm fileExistsAtPath:picked.path isDirectory:&isDir] || !isDir) {
        candidate = [picked URLByDeletingLastPathComponent];
    }

    /* 1. Check if candidate or any of its ancestors holds default.xbe */
    NSURL *up = candidate;
    for (int i = 0; i < 4 && up && ![up.path isEqualToString:@"/"]; i++) {
        if (find_xbe_in_dir(fm, up.path))
            return up;
        up = [up URLByDeletingLastPathComponent];
    }

    /* 2. Check immediate subdirectories of candidate */
    NSArray<NSURL *> *kids = [fm contentsOfDirectoryAtURL:candidate
                               includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                                                  options:0
                                                    error:nil];
    for (NSURL *k in kids) {
        NSNumber *kDir = nil;
        [k getResourceValue:&kDir forKey:NSURLIsDirectoryKey error:nil];
        if (kDir.boolValue && find_xbe_in_dir(fm, k.path))
            return k;
    }
    return nil;
}

static BOOL copy_file(NSString *from, NSString *to, char *buf,
                      void (^progress)(uint64_t), NSString **err)
{
    FILE *in = fopen(from.fileSystemRepresentation, "rb");
    FILE *out = in ? fopen(to.fileSystemRepresentation, "wb") : NULL;
    size_t n;
    BOOL ok = YES;

    if (!in || !out) {
        NSError *copyErr = nil;
        if ([NSFileManager.defaultManager copyItemAtPath:from toPath:to error:&copyErr]) {
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:to error:nil];
            if (progress && attrs)
                progress(attrs.fileSize);
            if (in) fclose(in);
            if (out) fclose(out);
            return YES;
        }
        *err = [NSString stringWithFormat:@"%@: %s%@", from.lastPathComponent, strerror(errno),
                errno == ENOENT ? @" (if it is in iCloud, download it in Files first)" : @""];
        if (in)
            fclose(in);
        return NO;
    }
    while ((n = fread(buf, 1, COPY_CHUNK, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            *err = [NSString stringWithFormat:@"writing %@: %s", to.lastPathComponent, strerror(errno)];
            ok = NO;
            break;
        }
        progress(n);
    }
    if (ok && ferror(in)) {
        *err = [NSString stringWithFormat:@"reading %@: %s", from.lastPathComponent, strerror(errno)];
        ok = NO;
    }
    fclose(in);
    if (fclose(out) != 0 && ok) {
        *err = [NSString stringWithFormat:@"writing %@: %s", to.lastPathComponent, strerror(errno)];
        ok = NO;
    }
    return ok;
}

@interface NFSImportController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *gameDir;
@property (nonatomic) BOOL done;
- (void)importFrom:(NSURL *)picked;
@end

@implementation NFSImportController {
    UILabel        *_status;
    UIButton       *_autoDetectBtn;
    UIButton       *_pickFileBtn;
    UIButton       *_pickFolderBtn;
    UIProgressView *_bar;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad
{
    UILabel *title = [UILabel new], *body = [UILabel new];
    UIStackView *stack, *btnStack;

    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.09 alpha:1.0];

    title.text = @"Need for Speed: Underground 2";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    body.text = @"Game files not detected yet.\n\n"
                @"Recommended (Easiest — No picker needed):\n"
                @"1. Open the Files app on your device\n"
                @"2. Go to: On My iPhone (or iPad) ➔ NFSU2 ➔ game\n"
                @"   (or paste directly into the NFSU2 folder)\n"
                @"3. Return here — files will auto-detect!\n\n"
                @"Or select default.xbe with the picker below:";
    body.numberOfLines = 0;
    body.textAlignment = NSTextAlignmentLeft;
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = [UIColor colorWithWhite:0.85 alpha:1];

    UIButtonConfiguration *cfgAuto = [UIButtonConfiguration filledButtonConfiguration];
    cfgAuto.title = @"Auto-Detect / Refresh Game Files";
    cfgAuto.baseBackgroundColor = [UIColor colorWithRed:0.18 green:0.55 blue:0.34 alpha:1.0];
    cfgAuto.baseForegroundColor = UIColor.whiteColor;
    _autoDetectBtn = [UIButton buttonWithConfiguration:cfgAuto primaryAction:
                      [UIAction actionWithHandler:^(UIAction *a) { [self checkAutoDetectManual]; }]];

    UIButtonConfiguration *cfgFile = [UIButtonConfiguration tintedButtonConfiguration];
    cfgFile.title = @"Pick default.xbe File…";
    _pickFileBtn = [UIButton buttonWithConfiguration:cfgFile primaryAction:
                    [UIAction actionWithHandler:^(UIAction *a) { [self pickFile]; }]];

    UIButtonConfiguration *cfgFolder = [UIButtonConfiguration grayButtonConfiguration];
    cfgFolder.title = @"Pick Game Folder…";
    _pickFolderBtn = [UIButton buttonWithConfiguration:cfgFolder primaryAction:
                      [UIAction actionWithHandler:^(UIAction *a) { [self pickFolder]; }]];

    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _bar.hidden = YES;

    _status = [UILabel new];
    _status.numberOfLines = 0;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _status.font = [UIFont systemFontOfSize:13];

    btnStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _autoDetectBtn, _pickFileBtn, _pickFolderBtn ]];
    btnStack.axis = UILayoutConstraintAxisVertical;
    btnStack.spacing = 10;
    btnStack.alignment = UIStackViewAlignmentFill;

    stack = [[UIStackView alloc] initWithArrangedSubviews:@[ title, body, btnStack, _bar, _status ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:580],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-32],
        [body.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [btnStack.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_bar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(onAppBecameActive)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
}

- (void)onAppBecameActive
{
    [self checkAutoDetectSilent];
}

- (BOOL)checkAutoDetectSilent
{
    NSString *detected = auto_detect_game_directory(self.gameDir);
    if (detected) {
        fprintf(stderr, "[ios] auto-detected game files in %s\n", detected.fileSystemRepresentation);
        setenv("NFSU2_GAME_DIR", detected.fileSystemRepresentation, 1);
        _status.text = [NSString stringWithFormat:@"Found game in %@! Starting…", detected.lastPathComponent];
        _bar.hidden = YES;
        self.done = YES;
        return YES;
    }
    return NO;
}

- (void)checkAutoDetectManual
{
    if (![self checkAutoDetectSilent]) {
        _status.text = @"default.xbe not found in Documents or Documents/game yet.\nCheck that your extracted disc files are copied into the NFSU2 folder in Files.";
    }
}

- (void)pickFile
{
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem, UTTypeData ]];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    if (p.popoverPresentationController) {
        p.popoverPresentationController.sourceView = _pickFileBtn;
        p.popoverPresentationController.sourceRect = _pickFileBtn.bounds;
        p.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:p animated:YES completion:nil];
}

- (void)pickFolder
{
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    if (p.popoverPresentationController) {
        p.popoverPresentationController.sourceView = _pickFolderBtn;
        p.popoverPresentationController.sourceRect = _pickFolderBtn.bounds;
        p.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count)
        [self importFrom:urls.firstObject];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker
{
    _autoDetectBtn.enabled = YES;
    _pickFileBtn.enabled = YES;
    _pickFolderBtn.enabled = YES;
    _bar.hidden = YES;
    _status.text = @"Picker cancelled. You can paste files into Files app or tap Auto-Detect.";
}

- (void)fail:(NSString *)why
{
    fprintf(stderr, "[ios] import failed: %s\n", why.UTF8String);
    _status.text = why;
    _bar.hidden = YES;
    _autoDetectBtn.enabled = YES;
    _pickFileBtn.enabled = YES;
    _pickFolderBtn.enabled = YES;
}

- (void)importFrom:(NSURL *)picked
{
    NSString *game = self.gameDir, *tmp = [game stringByAppendingString:@".import"];
    BOOL scoped = [picked startAccessingSecurityScopedResource];
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task;

    _autoDetectBtn.enabled = NO;
    _pickFileBtn.enabled = NO;
    _pickFolderBtn.enabled = NO;
    _bar.hidden = NO;
    _bar.progress = 0;
    _status.text = @"Preparing import…";
    app.idleTimerDisabled = YES;
    task = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL bgScoped = [picked startAccessingSecurityScopedResource];
        NSString *err = [self copyFrom:picked into:tmp game:game];
        if (bgScoped)
            [picked stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (scoped)
                [picked stopAccessingSecurityScopedResource];
            app.idleTimerDisabled = NO;
            if (task != UIBackgroundTaskInvalid)
                [app endBackgroundTask:task];
            if (err) {
                [self fail:err];
            } else {
                fprintf(stderr, "[ios] game imported into %s\n", game.fileSystemRepresentation);
                self.done = YES;
            }
        });
    });
}

/* Background queue. Returns nil when the game is in place, else why not. */
- (NSString *)copyFrom:(NSURL *)picked into:(NSString *)tmp game:(NSString *)game
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *keys = @[ NSURLIsDirectoryKey, NSURLFileSizeKey ];
    NSURL *root = disc_root(picked);
    NSMutableArray<NSURL *> *items = [NSMutableArray array];
    NSDictionary *space;
    NSError *e = nil;
    __block uint64_t done = 0, total = 0, shown = 0;
    NSString *err = nil, *sha;
    char *buf;

    if (!root)
        return @"No default.xbe found. Pick the game folder or default.xbe from your extracted NTSC-U disc.";

    BOOL rootScoped = [root startAccessingSecurityScopedResource];

    for (NSURL *u in [fm enumeratorAtURL:root includingPropertiesForKeys:keys options:0 errorHandler:nil]) {
        NSNumber *dir = nil, *size = nil;
        [u getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [items addObject:u];
        if (!dir.boolValue)
            total += size.unsignedLongLongValue;
    }
    space = [[NSURL fileURLWithPath:game.stringByDeletingLastPathComponent]
             resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey ] error:nil];
    if ([space[NSURLVolumeAvailableCapacityForImportantUsageKey] unsignedLongLongValue] < total + (256ull << 20)) {
        if (rootScoped)
            [root stopAccessingSecurityScopedResource];
        return [NSString stringWithFormat:@"Not enough free space: the game needs %.1f GB.",
                total / 1e9];
    }

    [fm removeItemAtPath:tmp error:nil];
    if (![fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:&e]) {
        if (rootScoped)
            [root stopAccessingSecurityScopedResource];
        return e.localizedDescription;
    }
    buf = malloc(COPY_CHUNK);
    if (!buf) {
        if (rootScoped)
            [root stopAccessingSecurityScopedResource];
        return @"Out of memory.";
    }
    fprintf(stderr, "[ios] importing %s (%llu MB)\n", root.fileSystemRepresentation,
            (unsigned long long)(total >> 20));
    for (NSURL *u in items) {
        NSString *rel = [u.path substringFromIndex:root.path.length];
        NSString *dst = [tmp stringByAppendingPathComponent:rel];
        NSNumber *dir = nil;
        [u getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        if (dir.boolValue) {
            if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&e]) {
                err = e.localizedDescription;
                break;
            }
            continue;
        }
        if (!copy_file(u.path, dst, buf, ^(uint64_t n) {
                done += n;
                if (done - shown >= (32ull << 20) || done == total) {
                    float f = total ? (float)done / (float)total : 1.0f;
                    shown = done;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self->_bar.progress = f;
                        self->_status.text = [NSString stringWithFormat:@"Copying… %.0f%%", f * 100];
                    });
                }
            }, &err))
            break;
    }
    free(buf);

    if (!err) {
        NSString *xbe = find_xbe_in_dir(fm, tmp);
        if (!xbe) {
            err = @"default.xbe was not found after copying.";
        } else {
            NSString *canonicalXbe = [tmp stringByAppendingPathComponent:@"default.xbe"];
            if (![xbe isEqualToString:canonicalXbe]) {
                [fm moveItemAtPath:xbe toPath:canonicalXbe error:nil];
                xbe = canonicalXbe;
            }
            NSDictionary *a = [fm attributesOfItemAtPath:xbe error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ self->_status.text = @"Checking default.xbe…"; });
            sha = xbe_sha1(xbe);
            if (a.fileSize != XBE_SIZE || ![sha isEqualToString:@XBE_SHA1])
                err = [NSString stringWithFormat:@"This default.xbe is not the North American (NTSC-U) "
                       @"release this port is built from (SHA-1 %@).", sha ?: @"unreadable"];
        }
    }
    /* In place: replace what a partial earlier copy left, item by item. */
    if (!err) {
        [fm createDirectoryAtPath:game withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
            NSString *to = [game stringByAppendingPathComponent:name];
            [fm removeItemAtPath:to error:nil];
            if (![fm moveItemAtPath:[tmp stringByAppendingPathComponent:name] toPath:to error:&e]) {
                err = e.localizedDescription;
                break;
            }
        }
    }
    [fm removeItemAtPath:tmp error:nil];
    if (rootScoped)
        [root stopAccessingSecurityScopedResource];
    return err;
}
@end

/* 1 once <game_dir>/default.xbe exists: at once, or after an import. */
int ios_import_game(const char *game_dir)
{
    NSString *game = [NSString stringWithUTF8String:game_dir];
    UIWindowScene *scene;
    UIWindow *win;
    NFSImportController *vc;

    /* 1. Fast check: auto-detect if default.xbe is already in Documents/game, Documents, or any subfolder */
    NSString *detected = auto_detect_game_directory(game);
    if (detected) {
        fprintf(stderr, "[ios] game files auto-detected in %s\n", detected.fileSystemRepresentation);
        setenv("NFSU2_GAME_DIR", detected.fileSystemRepresentation, 1);
        return 1;
    }

    scene = ios_window_scene();
    if (!scene) {
        fprintf(stderr, "[ios] no window scene for the game import\n");
        return 0;
    }
    fprintf(stderr, "[ios] no default.xbe in %s: showing setup screen\n", game_dir);
    vc = [NFSImportController new];
    vc.gameDir = game;
    win = [[UIWindow alloc] initWithWindowScene:scene];
    win.rootViewController = vc;
    [win makeKeyAndVisible];
    if (getenv("NFSU2_IMPORT_FROM"))
        [vc importFrom:[NSURL fileURLWithPath:@(getenv("NFSU2_IMPORT_FROM")) isDirectory:YES]];
    while (!vc.done)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    win.hidden = YES;
    return 1;
}

/* NFSU2_VERIFY=1: the SHA-1 and size of every disc file under the game
 * folder, in the log ("[verify] <sha1> <bytes> <path>"), to compare with the
 * copy the game came from (shasum on the Mac) -- a transfer that damaged the
 * data files. UDATA and TDATA are the title's own writes and are skipped. */
void ios_verify_game(const char *game_dir)
{
    @autoreleasepool {
        NSString *root = @(game_dir), *rel;
        NSDirectoryEnumerator<NSString *> *e = [NSFileManager.defaultManager enumeratorAtPath:root];
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        unsigned long long total = 0;
        unsigned n = 0, bad = 0;

        while ((rel = [e nextObject])) {
            NSDictionary *a = e.fileAttributes;
            NSString *sha;
            if ([a.fileType isEqualToString:NSFileTypeDirectory]) {
                if ([rel isEqualToString:@"UDATA"] || [rel isEqualToString:@"TDATA"])
                    [e skipDescendants];
                continue;
            }
            if (![a.fileType isEqualToString:NSFileTypeRegular])
                continue;
            sha = xbe_sha1([root stringByAppendingPathComponent:rel]);
            if (!sha)
                bad++;
            fprintf(stderr, "[verify] %s %llu %s\n", sha ? sha.UTF8String : "unreadable",
                    a.fileSize, rel.UTF8String);
            n++;
            total += a.fileSize;
        }
        fprintf(stderr, "[verify] %u files, %llu MB, %u unreadable, %.0f s\n", n, total >> 20, bad,
                CFAbsoluteTimeGetCurrent() - t0);
    }
}
