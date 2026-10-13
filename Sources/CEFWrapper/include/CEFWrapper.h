//
//  CEFWrapper.h
//  CEFWebView
//
//  Objective-C wrapper for CEF C++ API - provides simple methods for Swift to interact with CEF
//

#ifndef CEFWrapper_h
#define CEFWrapper_h

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when CEF launches a helper process. userInfo: @{@"type": NSString}
/// with "gpu", "network", "storage" or "renderer". Helper processes are shared by all browsers.
extern NSNotificationName const CEFHelperSpawnedNotification;

@class CEFBrowserHandle;

/// Receives events for one browser. Always called on the main thread.
NS_SWIFT_UI_ACTOR
@protocol CEFBrowserHandleDelegate <NSObject>

- (void)browserHandle:(CEFBrowserHandle *)handle
    loadingStateChanged:(BOOL)isLoading
              canGoBack:(BOOL)canGoBack
           canGoForward:(BOOL)canGoForward;

- (void)browserHandle:(CEFBrowserHandle *)handle progressChanged:(double)progress;

- (void)browserHandle:(CEFBrowserHandle *)handle titleChanged:(nullable NSString *)title;

- (void)browserHandle:(CEFBrowserHandle *)handle addressChanged:(NSString *)url;

/// Main-frame load failure (ERR_ABORTED is filtered out).
- (void)browserHandle:(CEFBrowserHandle *)handle
    mainFrameLoadFailedWithCode:(NSInteger)errorCode
                      errorText:(nullable NSString *)errorText
                      failedURL:(nullable NSString *)failedURL;

/// The renderer process serving this browser exited abnormally.
- (void)browserHandle:(CEFBrowserHandle *)handle renderProcessTerminatedWithStatus:(NSInteger)status;

/// The browser has fully closed (CEF OnBeforeClose). No further calls follow.
- (void)browserHandleDidClose:(CEFBrowserHandle *)handle;

@end

/// One CEF browser embedded in an NSView. Main thread only.
NS_SWIFT_UI_ACTOR
@interface CEFBrowserHandle : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Create a windowed browser as a child of `parentView`. Returns nil if CEF is not initialized or creation fails.
- (nullable instancetype)initWithParentView:(NSView *)parentView
                                        url:(NSString *)urlString
                                   delegate:(nullable id<CEFBrowserHandleDelegate>)delegate;

@property (nonatomic, weak, nullable) id<CEFBrowserHandleDelegate> delegate;

/// The NSView CEF renders into (a subview of the parent view). Nil once closed.
@property (nonatomic, readonly, nullable) NSView *browserView;

/// YES from creation until `close` is called.
@property (nonatomic, readonly) BOOL isOpen;

- (void)loadURL:(NSString *)urlString;
- (void)reload;
- (void)goBack;
- (void)goForward;

/// Call after the embedding NSView changes size or layout. Maps to CefBrowserHost::WasResized().
- (void)notifyGeometryChanged;

/// Close the browser. Completion is reported through `browserHandleDidClose:`.
- (void)close;

@end

/// Settings for +initializeCEFWithOptions:error:. The defaults suit a shipping app.
@interface CEFInitializationOptions : NSObject

/// Run helper processes in Chromium's sandbox, so a compromised renderer cannot reach the file
/// system, network or other processes directly. Default YES.
@property (nonatomic) BOOL sandboxEnabled;

/// Hardware-accelerated rendering. Default YES; NO renders in software.
@property (nonatomic) BOOL gpuEnabled;

/// Verbose Chromium logging. Default NO, which logs warnings and errors only.
@property (nonatomic) BOOL verboseLogging;

/// Encrypt cookies with a key in the login keychain. Default NO. Chromium names the keychain item
/// "Chromium Safe Storage" in every CEF app, so macOS asks for the login password whenever an app
/// that did not create the item reads it. Ignored for ad-hoc signed builds, whose signature changes
/// on every build.
@property (nonatomic) BOOL useSystemKeychain;

/// Where the browser profile (cookies, local storage, cache) is stored. Default nil, which uses
/// ~/Library/Application Support/<bundle id>/CEF.
@property (nonatomic, copy, nullable) NSString *profileDirectory;

@end

/// Process-wide CEF lifecycle.
@interface CEFWrapper : NSObject

/// Handle subprocess role detection — call this at the very start of the app, before any CEF initialization
/// Returns the subprocess exit code if this process is a CEF subprocess (renderer, GPU, utility, network)
/// Returns -1 if this is the main browser process and should continue with normal app startup
+ (int)executeSubprocessWithArgc:(int)argc argv:(char * _Nullable * _Nullable)argv;

/// Initialize CEF framework
/// Must be called on the main thread, once at app startup
+ (BOOL)initializeCEFWithOptions:(CEFInitializationOptions *)options error:(NSError **)error;

/// Number of browsers that have been created and not yet fully closed.
+ (NSInteger)openBrowserCount;

/// Close every open browser, wait (pumping CEF) until they finish closing, then shut CEF down.
/// Call once, at app termination.
+ (void)shutdown;

@end

NS_ASSUME_NONNULL_END

#endif /* CEFWrapper_h */
