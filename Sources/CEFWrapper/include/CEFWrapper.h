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

/// What to do with a page's request to open a pop-up or new window.
typedef NS_ENUM(NSInteger, CEFPopupDecision) {
    /// Load the pop-up's URL in this browser instead.
    CEFPopupDecisionLoadInPlace = 0,
    /// Do nothing. The app can open its own window for the URL.
    CEFPopupDecisionBlock = 1,
};

/// Calls back with the JSON text of the result (nil for `undefined`), or an error message.
/// `pageUnavailable` is YES when the script could not finish because the page went away (navigation,
/// renderer crash, close) rather than because it threw.
typedef void (^CEFJavaScriptCompletion)(NSString * _Nullable resultJSON, NSString * _Nullable errorMessage,
                                        BOOL pageUnavailable);

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

/// Asked before every navigation, in any frame. Return NO to cancel it.
- (BOOL)browserHandle:(CEFBrowserHandle *)handle
    shouldNavigateToURL:(NSString *)url
            isMainFrame:(BOOL)isMainFrame
          isUserGesture:(BOOL)isUserGesture
             isRedirect:(BOOL)isRedirect;

/// Asked when a page opens a pop-up or new window (window.open, target=_blank).
- (CEFPopupDecision)browserHandle:(CEFBrowserHandle *)handle
           decidePopupForURL:(NSString *)url
               isUserGesture:(BOOL)isUserGesture;

/// A page called `window.cefWebView.postMessage(name, body)`. `bodyJSON` is nil for `undefined`.
- (void)browserHandle:(CEFBrowserHandle *)handle
    didReceiveScriptMessage:(NSString *)name
                   bodyJSON:(nullable NSString *)bodyJSON
                isMainFrame:(BOOL)isMainFrame;

/// Find-in-page progress for the last `find:` call.
- (void)browserHandle:(CEFBrowserHandle *)handle
    findResultCount:(NSInteger)count
        activeMatch:(NSInteger)activeMatch
        finalUpdate:(BOOL)finalUpdate;

/// A download is about to start. Return the full destination path, or nil to cancel it.
- (nullable NSString *)browserHandle:(CEFBrowserHandle *)handle
    destinationForDownload:(uint32_t)downloadID
                       url:(NSString *)url
             suggestedName:(NSString *)suggestedName
                  mimeType:(NSString *)mimeType;

/// Progress, completion or cancellation of a download that was given a destination.
- (void)browserHandle:(CEFBrowserHandle *)handle
    downloadUpdated:(uint32_t)downloadID
               path:(NSString *)path
      receivedBytes:(int64_t)receivedBytes
         totalBytes:(int64_t)totalBytes
         isComplete:(BOOL)isComplete
         isCanceled:(BOOL)isCanceled;

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
- (void)stopLoading;
- (void)goBack;
- (void)goForward;

/// Run `script` in the main frame. If the result is a promise, waits for it to settle. The result is
/// passed back as JSON text, so it must survive JSON.stringify.
- (void)evaluateJavaScript:(NSString *)script completion:(CEFJavaScriptCompletion)completion;

/// Run `script` in the main frame as if the user had just clicked: pop-ups and other actions that need
/// a user gesture are allowed. Fire and forget. For tests.
- (void)runScriptAsUserGesture:(NSString *)script;

/// Chromium zoom level: 0 is 100%, and each step of 1 scales by 1.2.
@property (nonatomic) double zoomLevel;

/// Highlight matches of `text`. Pass `findNext` YES to move to the next match of the same text.
- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFinding:(BOOL)clearSelection;

/// Cancel a download in progress.
- (void)cancelDownload:(uint32_t)downloadID;

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

/// Web notifications (the Notification and Push APIs) shown through macOS Notification Center.
/// Default NO: pages cannot show notifications, and Chromium does not start its notification
/// service, which otherwise registers the app and its Alerts helper with Notification Center and
/// makes macOS show "Notifications may include alerts, sounds and icon badges" banners.
@property (nonatomic) BOOL systemNotificationsEnabled;

/// Where the browser profile (cookies, local storage, cache) is stored. Default nil, which uses
/// ~/Library/Application Support/<bundle id>/CEF.
@property (nonatomic, copy, nullable) NSString *profileDirectory;

/// User-Agent header and navigator.userAgent. Default nil, which uses Chrome's.
@property (nonatomic, copy, nullable) NSString *userAgent;

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

/// Delete every cookie in the profile. Calls back on the main thread with the number deleted.
+ (void)deleteAllCookiesWithCompletion:(void (^)(NSInteger deletedCount))completion;

/// Close every open browser, wait (pumping CEF) until they finish closing, then shut CEF down.
/// Call once, at app termination.
+ (void)shutdown;

@end

NS_ASSUME_NONNULL_END

#endif /* CEFWrapper_h */
