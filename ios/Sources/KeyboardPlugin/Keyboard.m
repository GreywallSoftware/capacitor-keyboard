/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "Keyboard.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <Capacitor/Capacitor.h>
#import <Capacitor/Capacitor-Swift.h>
#import <Capacitor/CAPBridgedPlugin.h>
#import <Capacitor/CAPBridgedJSTypes.h>

typedef enum : NSUInteger {
  ResizeNone,
  ResizeNative,
  ResizeBody,
  ResizeIonic,
} ResizePolicy;


@interface KeyboardPlugin () <UIScrollViewDelegate>

@property (readwrite, assign, nonatomic) BOOL disableScroll;
@property (readwrite, assign, nonatomic) BOOL hideFormAccessoryBar;
@property (readwrite, assign, nonatomic) BOOL keyboardIsVisible;
@property (nonatomic, readwrite) ResizePolicy keyboardResizes;
@property (readwrite, assign, nonatomic) NSString* keyboardStyle;
@property (nonatomic, readwrite) int paddingBottom;
@property (nonatomic, readwrite) NSTimeInterval pendingAnimationDuration;
@property (nonatomic, readwrite) UIViewAnimationOptions pendingAnimationOptions;
@property (nonatomic, strong) UIView *resizeSnapshot;

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
// suppressing warnings of the type: "Class 'KeyboardPlugin' does not conform to protocol 'CAPBridgedPlugin'"
// protocol conformance for this class is implemented by a macro and clang isn't detecting that
@implementation KeyboardPlugin

NSTimer *hideTimer;
NSString* UIClassString;
NSString* WKClassString;
NSString* UITraitsClassString;
double stageManagerOffset;

#pragma mark - Helpers

- (UIWindow *)currentKeyWindow {
  UIWindow *window = nil;
  if ([[[UIApplication sharedApplication] delegate] respondsToSelector:@selector(window)]) {
    window = [[[UIApplication sharedApplication] delegate] window];
  }
  if (!window) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"self isKindOfClass: %@", UIWindowScene.class];
    UIScene *scene = [UIApplication.sharedApplication.connectedScenes.allObjects filteredArrayUsingPredicate:predicate].firstObject;
    window = [[(UIWindowScene*)scene windows] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isKeyWindow == YES"]].firstObject;
  }
  return window;
}

- (void)forceBackdropColor:(UIColor *)color {
  UIWindow *w = [self currentKeyWindow];
  if (w) {
    dispatch_async(dispatch_get_main_queue(), ^{
      w.backgroundColor = color;
    });
  }
}

- (BOOL)isIPad {
  return ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);
}

- (BOOL)shouldIgnoreResizeForHeight:(double)height {
  if (![self isIPad]) return NO;
  if (height <= 0.0) return NO;
  CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
  return (height / screenHeight) < 0.20;
}

#pragma mark - Lifecycle

- (UIColor *)colorFromCssColorString:(NSString *)cssColor {
    NSString *trimmed = [cssColor stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([trimmed isEqualToString:@"transparent"]) {
        return [UIColor clearColor];
    }

    if ([trimmed hasPrefix:@"rgb"]) {
        NSRange parenRange = [trimmed rangeOfString:@"("];
        NSString *clean = parenRange.location != NSNotFound ? [trimmed substringFromIndex:parenRange.location + 1] : trimmed;
        clean = [clean stringByReplacingOccurrencesOfString:@")" withString:@""];
        NSArray *parts = [clean componentsSeparatedByString:@","];
        if (parts.count >= 3) {
            CGFloat r = [parts[0] floatValue] / 255.0;
            CGFloat g = [parts[1] floatValue] / 255.0;
            CGFloat b = [parts[2] floatValue] / 255.0;
            CGFloat a = parts.count >= 4 ? [parts[3] floatValue] : 1.0;
            return [UIColor colorWithRed:r green:g blue:b alpha:a];
        }
    }

    if ([trimmed hasPrefix:@"#"]) {
        unsigned rgbValue = 0;
        NSScanner *scanner = [NSScanner scannerWithString:trimmed];
        [scanner setScanLocation:1];
        if ([scanner scanHexInt:&rgbValue]) {
            CGFloat r = ((rgbValue & 0xFF0000) >> 16) / 255.0;
            CGFloat g = ((rgbValue & 0x00FF00) >> 8) / 255.0;
            CGFloat b = (rgbValue & 0x0000FF) / 255.0;
            return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
        }
    }

    return [UIColor whiteColor]; // fallback
}

- (void)updateBackdropColor {
  NSString *mode = [[self getConfig] getString:@"autoBackdropColor": @"off"];

  if ([mode isEqualToString:@"auto"]) {
    if (self.bridge.config.backgroundColor) {
      [self forceBackdropColor:self.bridge.config.backgroundColor];
    } else {
      [self updateBackdropColorFromDOM];
    }
  } else if ([mode isEqualToString:@"dom"]) {
    [self updateBackdropColorFromDOM];
  }
}

- (void)updateBackdropColorFromDOM {
    if (!self.webView) return;
    [self.webView evaluateJavaScript:@"window.getComputedStyle(document.body).backgroundColor" completionHandler:^(id result, NSError *error) {
        if (result && [result isKindOfClass:[NSString class]]) {
            UIColor *color = [self colorFromCssColorString:(NSString *)result];
            if (color) {
                [self forceBackdropColor:color];
            }
        }
    }];
}

- (void)load
{
  self.disableScroll = !self.bridge.config.scrollingEnabled;

  UIClassString = [@[@"UI", @"Web", @"Browser", @"View"] componentsJoinedByString:@""];
  WKClassString = [@[@"WK", @"Content", @"View"] componentsJoinedByString:@""];
  UITraitsClassString = [@[@"UI", @"Text", @"Input", @"Traits"] componentsJoinedByString:@""];

  PluginConfig * config = [self getConfig];
  NSString * style = [config getString:@"style": nil];
  [self changeKeyboardStyle:style.uppercaseString];

  self.keyboardResizes = ResizeNative;
  NSString * resizeMode = [config getString:@"resize": nil];

  if ([resizeMode isEqualToString:@"none"]) {
    self.keyboardResizes = ResizeNone;
    NSLog(@"KeyboardPlugin: no resize");
  } else if ([resizeMode isEqualToString:@"ionic"]) {
    self.keyboardResizes = ResizeIonic;
    NSLog(@"KeyboardPlugin: resize mode - ionic");
  } else if ([resizeMode isEqualToString:@"body"]) {
    self.keyboardResizes = ResizeBody;
    NSLog(@"KeyboardPlugin: resize mode - body");
  }

  if (self.keyboardResizes == ResizeNative) {
    NSLog(@"KeyboardPlugin: resize mode - native");
    // Startup marker for the local capacitor-keyboard#79 fix. If this line is
    // absent from the Xcode console, the build is running stock 8.0.5 and the
    // animated resize is NOT compiled in.
    NSLog(@"KeyboardPlugin: VEOCI PATCH ACTIVE - animated resize (issue #79)");
  }

  self.hideFormAccessoryBar = YES;
  
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  
  [nc addObserver:self selector:@selector(onKeyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];
  [nc addObserver:self selector:@selector(onKeyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
  [nc addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
  [nc addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
  
  [nc removeObserver:self.webView name:UIKeyboardWillHideNotification object:nil];
  [nc removeObserver:self.webView name:UIKeyboardWillShowNotification object:nil];
  [nc removeObserver:self.webView name:UIKeyboardWillChangeFrameNotification object:nil];
  [nc removeObserver:self.webView name:UIKeyboardDidChangeFrameNotification object:nil];

  [self updateBackdropColor];
}

#pragma mark Keyboard events

- (void)resetScrollView
{
  UIScrollView *scrollView = [self.webView scrollView];
  [scrollView setContentInset:UIEdgeInsetsZero];
}

- (void)onKeyboardWillHide:(NSNotification *)notification
{
  [self setKeyboardHeight:0 withAnimationFromNotification:notification];
  [self resetScrollView];
  hideTimer = [NSTimer scheduledTimerWithTimeInterval:0 repeats:NO block:^(NSTimer * _Nonnull timer) {
    [self.bridge triggerWindowJSEventWithEventName:@"keyboardWillHide"];
    [self notifyListeners:@"keyboardWillHide" data:nil];
  }];
  [[NSRunLoop currentRunLoop] addTimer:hideTimer forMode:NSRunLoopCommonModes];
}

- (void)onKeyboardWillShow:(NSNotification *)notification
{
  if (hideTimer != nil) {
    [hideTimer invalidate];
  }

  // Force DOM color whenever keyboard shows
  [self updateBackdropColor];

  CGRect rect = [[notification.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];

  double height = rect.size.height;
    
  if ([self isIPad]) {
    if (stageManagerOffset > 0) {
      height = stageManagerOffset;
    } else {
      CGRect webViewAbsolute = [self.webView convertRect:self.webView.frame toCoordinateSpace:self.webView.window.screen.coordinateSpace];
      height = (webViewAbsolute.size.height + webViewAbsolute.origin.y) - (UIScreen.mainScreen.bounds.size.height - rect.size.height);
      if (height < 0) {
        height = 0;
      }
        
      stageManagerOffset = height;
    }
  }

  BOOL ignored = [self shouldIgnoreResizeForHeight:height];
  if (ignored) {
    NSLog(@"KeyboardPlugin: Ignoring QuickType Bar (%.1f) -> treat as 0.", height);
    height = 0.0;
  }

  [self setKeyboardHeight:(int)height withAnimationFromNotification:notification];
  [self resetScrollView];

  NSString * data = [NSString stringWithFormat:@"{ 'keyboardHeight': %d }", (int)height];
  [self.bridge triggerWindowJSEventWithEventName:@"keyboardWillShow" data:data];
  NSDictionary * kbData = @{@"keyboardHeight": [NSNumber numberWithDouble:height]};
  [self notifyListeners:@"keyboardWillShow" data:kbData];
}

- (void)onKeyboardDidShow:(NSNotification *)notification
{
  CGRect rect = [[notification.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
  double height = rect.size.height;

  if ([self isIPad]) {
    if (stageManagerOffset > 0) {
      height = stageManagerOffset;
    } else {
      CGRect webViewAbsolute = [self.webView convertRect:self.webView.frame toCoordinateSpace:self.webView.window.screen.coordinateSpace];
      height = (webViewAbsolute.size.height + webViewAbsolute.origin.y) - (UIScreen.mainScreen.bounds.size.height - rect.size.height);
      if (height < 0) {
        height = 0;
      }
    }
  }

  BOOL ignored = [self shouldIgnoreResizeForHeight:height];
  if (ignored) {
    NSLog(@"KeyboardPlugin: (didShow) Ignoring QuickType Bar (%.1f) -> report 0.", height);
    height = 0.0;
  }

  [self resetScrollView];

  NSString * data = [NSString stringWithFormat:@"{ 'keyboardHeight': %d }", (int)height];
  [self.bridge triggerWindowJSEventWithEventName:@"keyboardDidShow" data:data];
  NSDictionary * kbData = @{@"keyboardHeight": [NSNumber numberWithDouble:height]};
  [self notifyListeners:@"keyboardDidShow" data:kbData];
}

- (void)onKeyboardDidHide:(NSNotification *)notification
{
  [self.bridge triggerWindowJSEventWithEventName:@"keyboardDidHide"];
  [self notifyListeners:@"keyboardDidHide" data:nil];
  [self resetScrollView];

  stageManagerOffset = 0;
}

/**
 Resize the web surface on the keyboard's OWN animation, instead of snapping the
 frame after the keyboard has already finished moving.

 Upstream (through 8.0.5 and 9.0.0-next.1) does
 `setKeyboardHeight:delay:(keyboardDuration + 0.2)`, which lands an unanimated
 `-setFrame:` roughly 200ms after the keyboard is fully up. That late, instant
 frame change is the visible jump — see ionic-team/capacitor-keyboard#79.

 UIKit reports the in-flight animation's duration and curve on the notification,
 so joining it is exact rather than an approximation.
 */
- (void)setKeyboardHeight:(int)height withAnimationFromNotification:(NSNotification *)notification
{
  // Only ResizeNative moves a UIView frame, which is the only thing UIView
  // animation can interpolate. ResizeBody/ResizeIonic drive layout through a JS
  // eval and keep the original delayed path.
  if (self.keyboardResizes != ResizeNative) {
    [self setKeyboardHeight:height delay:0.01];
    return;
  }

  if (self.paddingBottom == height) {
    return;
  }
  self.paddingBottom = height;

  NSNumber *durationValue = [notification.userInfo valueForKey:UIKeyboardAnimationDurationUserInfoKey];
  NSNumber *curveValue = [notification.userInfo valueForKey:UIKeyboardAnimationCurveUserInfoKey];

  self.pendingAnimationDuration = durationValue ? [durationValue doubleValue] : 0.0;
  // UIKit packs the keyboard's private curve into UIViewAnimationOptions by
  // shifting it left 16 bits. This is what puts the web surface on exactly the
  // keyboard's curve rather than a default ease-in-out.
  // No UIViewAnimationOptionLayoutSubviews: WKWebView lays out its own scroll
  // view and content view, and forcing a layout pass on them every animation
  // frame is not needed to move the frame.
  self.pendingAnimationOptions = (UIViewAnimationOptions)([curveValue integerValue] << 16)
    | UIViewAnimationOptionBeginFromCurrentState;

  // afterDelay:0 defers to the next run loop turn rather than running inline.
  // That is load-bearing: moving focus between two fields whose keyboards differ
  // emits willHide and willShow in the SAME turn, and the cancel below then drops
  // the hide so the surface never bounces to full height and back. It is the same
  // coalescing the upstream `delay:0.01` provided, kept intact.
  SEL action = @selector(_animateFrameUpdate);
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:action object:nil];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_updateFrame) object:nil];
  [self performSelector:action withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];
}

/**
 Cover the web surface with a still image of itself for the length of the resize.

 WKWebView renders out of process: changing its frame is synchronous, but the
 relayout and repaint at the new size arrive later over IPC. In between, the
 compositor has regions it must draw and no tile for, so it falls back to the
 layer's base colour and a band flashes. No choice of background colour removes
 that — it only changes the band's colour — because the band is missing CONTENT,
 not a missing colour.

 Holding a snapshot over the top means nothing unpainted is ever on screen. It
 stays opaque for the whole resize and only cross-dissolves afterwards, once
 WebKit has shipped tiles for the new size — fading in step with the resize
 leaves it partly transparent while tiles are still missing, and the band shows
 through.

 Installed on the shrink only. See `_animateFrameUpdate`.
 */
- (void)_installResizeSnapshot
{
  [self _removeResizeSnapshot];

  UIView *host = self.webView.superview;
  if (host == nil || self.webView.bounds.size.height <= 0.0) {
    return;
  }

  // afterScreenUpdates:NO — snapshot what is already on screen. YES would force a
  // synchronous render pass and defeat the point.
  UIView *snapshot = [self.webView snapshotViewAfterScreenUpdates:NO];
  if (snapshot == nil) {
    return;
  }

  snapshot.frame = self.webView.frame;
  // The webview shrinks underneath; the snapshot must keep its original size so
  // it continues to cover the area being vacated.
  snapshot.autoresizingMask = UIViewAutoresizingNone;
  snapshot.userInteractionEnabled = NO;
  [host insertSubview:snapshot aboveSubview:self.webView];
  self.resizeSnapshot = snapshot;
}

- (void)_removeResizeSnapshot
{
  [self.resizeSnapshot removeFromSuperview];
  self.resizeSnapshot = nil;
}

- (void)_animateFrameUpdate
{
  // Hardware keyboard attach/detach and some Stage Manager transitions report a
  // zero duration: there is no animation to join, so resize outright.
  if (self.pendingAnimationDuration <= 0.0) {
    [self _updateFrame];
    return;
  }

  // Only the shrink needs covering. Growing back, the snapshot is shorter than
  // the final frame by construction, so it cannot cover the band being revealed
  // — it can only hold a stale image over content that has already relaid out,
  // which is the COCKPIT bar and message rows showing twice mid-screen. The
  // revealed band needs no cover either: the keyboard descends over it.
  if (self.paddingBottom > 0) {
    [self _installResizeSnapshot];
  }

  [UIView animateWithDuration:self.pendingAnimationDuration
                        delay:0.0
                      options:self.pendingAnimationOptions
                   animations:^{
                     [self _updateFrame];
                   }
                   completion:^(BOOL finished) {
                     // Cross-dissolve AFTER the resize, not across it. Fading in
                     // step with the frame change leaves the snapshot partly
                     // transparent while WebKit is still shipping tiles for the
                     // new size, so an unpainted band shows through at partial
                     // alpha. It reads as a white flash wherever the page is not
                     // white — i.e. the header strip under the status bar.
                     // Holding alpha at 1 until the resize is done means nothing
                     // unpainted is ever on screen; by here WebKit has had the
                     // whole keyboard animation to paint, so the dissolve reveals
                     // finished content.
                     [UIView animateWithDuration:0.1
                                      animations:^{
                                        self.resizeSnapshot.alpha = 0.0;
                                      }
                                      completion:^(BOOL done) {
                                        [self _removeResizeSnapshot];
                                      }];
                   }];
}

- (void)setKeyboardHeight:(int)height delay:(NSTimeInterval)delay
{
  if (self.paddingBottom == height) {
    return;
  }

  self.paddingBottom = height;

  __weak KeyboardPlugin* weakSelf = self;
  SEL action = @selector(_updateFrame);
  [NSObject cancelPreviousPerformRequestsWithTarget:weakSelf selector:action object:nil];
  if (delay == 0) {
    [self _updateFrame];
  } else {
    [weakSelf performSelector:action withObject:nil afterDelay:delay inModes:@[NSRunLoopCommonModes]];
  }
}

- (void)resizeElement:(NSString *)element withPaddingBottom:(int)paddingBottom withScreenHeight:(int)screenHeight
{
    int height = -1;
    if (paddingBottom > 0) {
        height = screenHeight - paddingBottom;
    }
    
    [self.bridge evalWithJs: [NSString stringWithFormat:@"(function() { var el = %@; var height = %d; if (el) { el.style.height = height > -1 ? height + 'px' : null; } })()", element, height]];
}

- (void)_updateFrame
{
  CGRect f, wf = CGRectZero;
  UIWindow *window = [self currentKeyWindow];

  if (window) {
    f = [window bounds];
  }
  if (self.webView != nil) {
    wf = self.webView.frame;
  }
  switch (self.keyboardResizes) {
    case ResizeBody:
    {
      [self resizeElement:@"document.body" withPaddingBottom:_paddingBottom withScreenHeight:(int)f.size.height];
      break;
    }
    case ResizeIonic:
    {
      [self resizeElement:@"document.querySelector('ion-app')" withPaddingBottom:_paddingBottom withScreenHeight:(int)f.size.height];
      break;
    }
    case ResizeNative:
    {
      [self.webView setFrame:CGRectMake(wf.origin.x, wf.origin.y, f.size.width - wf.origin.x, f.size.height - wf.origin.y - self.paddingBottom)];
      break;
    }
    default:
      break;
  }
  [self resetScrollView];
}


#pragma mark HideFormAccessoryBar

static IMP UIOriginalImp;
static IMP WKOriginalImp;

- (void)setHideFormAccessoryBar:(BOOL)hideFormAccessoryBar
{
  if (hideFormAccessoryBar == _hideFormAccessoryBar) {
    return;
  }
  Method UIMethod = class_getInstanceMethod(NSClassFromString(UIClassString), @selector(inputAccessoryView));
  Method WKMethod = class_getInstanceMethod(NSClassFromString(WKClassString), @selector(inputAccessoryView));
  if (hideFormAccessoryBar) {
    UIOriginalImp = method_getImplementation(UIMethod);
    WKOriginalImp = method_getImplementation(WKMethod);
    IMP newImp = imp_implementationWithBlock(^(id _s) {
      return nil;
    });
    method_setImplementation(UIMethod, newImp);
    method_setImplementation(WKMethod, newImp);
  } else {
    method_setImplementation(UIMethod, UIOriginalImp);
    method_setImplementation(WKMethod, WKOriginalImp);
  }
  _hideFormAccessoryBar = hideFormAccessoryBar;
}

#pragma mark scroll

- (void)setDisableScroll:(BOOL)disableScroll {
  if (disableScroll == _disableScroll) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (disableScroll) {
      self.webView.scrollView.scrollEnabled = NO;
      self.webView.scrollView.delegate = self;
    }
    else {
      self.webView.scrollView.scrollEnabled = YES;
      self.webView.scrollView.delegate = nil;
    }
  });
  _disableScroll = disableScroll;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  [scrollView setContentOffset: CGPointZero];
}

#pragma mark Plugin interface

- (void)setAccessoryBarVisible:(CAPPluginCall *)call
{
  BOOL value = [call getBool:@"isVisible" defaultValue:FALSE];

  NSLog(@"Accessory bar visible change %d", value);
  self.hideFormAccessoryBar = !value;
  [call resolve];
}

- (void)hide:(CAPPluginCall *)call
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.webView endEditing:YES];
  });
  [call resolve];
}

- (void)show:(CAPPluginCall *)call
{
  [call unimplemented];
}

- (void)setStyle:(CAPPluginCall *)call
{
  self.keyboardStyle = [call getString:@"style" defaultValue:@"LIGHT"];
  [self changeKeyboardStyle:self.keyboardStyle]; 
  [call resolve];
}

- (void)setResizeMode:(CAPPluginCall *)call
{
  NSString * mode = [call getString:@"mode" defaultValue:@"none"];
  if ([mode isEqualToString:@"ionic"]) {
    self.keyboardResizes = ResizeIonic;
  } else if ([mode isEqualToString:@"body"]) {
    self.keyboardResizes = ResizeBody;
  } else if ([mode isEqualToString:@"native"]) {
    self.keyboardResizes = ResizeNative;
  } else {
    self.keyboardResizes = ResizeNone;
  }
  [call resolve];
}

- (void)getResizeMode:(CAPPluginCall *)call
{
    NSString *mode;
    
    if (self.keyboardResizes == ResizeIonic) {
        mode = @"ionic";
    } else if(self.keyboardResizes == ResizeBody) {
        mode = @"body";
    } else if (self.keyboardResizes == ResizeNative) {
        mode = @"native";
    } else {
        mode = @"none";
    }
    
    NSDictionary *response = [NSDictionary dictionaryWithObject:mode forKey:@"mode"];
    [call resolve: response];
}

- (void)setScroll:(CAPPluginCall *)call {
  self.disableScroll = [call getBool:@"isDisabled" defaultValue:FALSE];
  [call resolve];
}

- (void)changeKeyboardStyle:(NSString*)style
{
  IMP newImp = nil;
  if ([style isEqualToString:@"DARK"]) {
    newImp = imp_implementationWithBlock(^(id _s) {
      return UIKeyboardAppearanceDark;
    });
  } else if ([style isEqualToString:@"LIGHT"]) {
    newImp = imp_implementationWithBlock(^(id _s) {
      return UIKeyboardAppearanceLight;
    });
  } else {
    newImp = imp_implementationWithBlock(^(id _s) {
      return UIKeyboardAppearanceDefault;
    });
  }
  for (NSString* classString in @[WKClassString, UITraitsClassString]) {
    Class c = NSClassFromString(classString);
    Method m = class_getInstanceMethod(c, @selector(keyboardAppearance));
    if (m != NULL) {
      method_setImplementation(m, newImp);
    } else {
      class_addMethod(c, @selector(keyboardAppearance), newImp, "l@:");
    }
  }
  _keyboardStyle = style;
}

#pragma mark dealloc

- (void)dealloc
{
  [self _removeResizeSnapshot];
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
#pragma clang diagnostic pop
