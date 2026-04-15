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

/// Objective-C wrapper exposing CEF functionality to Swift
@interface CEFWrapper : NSObject

/// Initialize CEF framework
/// Must be called on the main thread, once at app startup
+ (BOOL)initializeCEFWithError:(NSError **)error;

/// Create a browser in windowed mode within a parent view
/// @param parentView The parent NSView to embed the browser in
/// @param urlString The initial URL to load (e.g., "https://google.com")
/// @return The NSView containing the CEF browser, or nil on error
+ (nullable NSView *)createBrowserInView:(NSView *)parentView
                                    url:(NSString *)urlString;

/// Reload the current page in the browser
+ (void)reloadBrowser;

/// Close the current browser (call before view teardown)
+ (void)closeBrowser;

/// Navigate back
+ (void)goBack;

/// Navigate forward
+ (void)goForward;

/// Load a new URL
+ (void)loadURL:(NSString *)urlString;

/// Process pending CEF messages (call regularly from message pump)
+ (void)doMessageLoopWork;

/// Shutdown CEF gracefully
+ (void)shutdown;

/// Check if a page is currently loading
+ (BOOL)isLoading;

/// Check if the browser can navigate back
+ (BOOL)canGoBack;

/// Check if the browser can navigate forward
+ (BOOL)canGoForward;

/// Get the current page title
+ (nullable NSString *)currentTitle;

/// Get the current page URL (updated on every navigation)
+ (nullable NSString *)currentURL;

@end

NS_ASSUME_NONNULL_END

#endif /* CEFWrapper_h */
