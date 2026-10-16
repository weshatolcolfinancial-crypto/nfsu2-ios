/*
 * ios_scene.h -- the app's window scene (src/ios/ios_scene.m), for the
 * Objective-C host files. Main thread only.
 */
#ifndef NFSU2_IOS_SCENE_H
#define NFSU2_IOS_SCENE_H

#import <UIKit/UIKit.h>

/* The connected UIWindowScene, waiting up to 2 s for it (turning the main
 * run loop); nil if none connected. */
UIWindowScene *ios_window_scene(void);

/* Screen presentation modes for modern iPhones:
 * 0: Fit (16:9 Letterboxed)
 * 1: Fullscreen Stretch (Edge-to-Edge OLED Fill)
 * 2: Zoom (Aspect Fill without bars) */
int ios_get_screen_mode(void);
void ios_set_screen_mode(int mode);
int ios_cycle_screen_mode(void);

#endif

