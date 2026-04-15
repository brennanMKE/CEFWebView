//
//  CEFWrapper.mm
//  CEFWebView
//
//  Objective-C++ wrapper for the CEF C++ API.
//

#import "include/CEFWrapper.h"

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_load_handler.h"
#include "include/cef_display_handler.h"
#include "include/wrapper/cef_library_loader.h"

// ─── C++ Client Class ───────────────────────────────────────────────────────────
//
// Inherits from CefClient, CefLoadHandler, and CefDisplayHandler.
// Implements the virtual methods for load state and title tracking.
// IMPLEMENT_REFCOUNTING macro handles all ref-counting automatically.

class ChromiumClient : public CefClient,
                       public CefLoadHandler,
                       public CefDisplayHandler {
public:
    // CefClient overrides
    CefRefPtr<CefLoadHandler> GetLoadHandler() override {
        return this;
    }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override {
        return this;
    }

    // CefLoadHandler overrides
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading, bool canGoBack, bool canGoForward) override {
        _isLoading = isLoading;
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
        NSLog(@"📊 OnLoadingStateChange: isLoading=%d canGoBack=%d canGoForward=%d",
              isLoading, canGoBack, canGoForward);
    }

    void OnLoadStart(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     TransitionType transition_type) override {
        NSLog(@"⬇️ OnLoadStart: url=%s isMain=%s",
              frame->GetURL().ToString().c_str(),
              frame->IsMain() ? "YES" : "NO");
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   int httpStatusCode) override {
        NSLog(@"✅ OnLoadEnd: url=%s status=%d isMain=%s",
              frame->GetURL().ToString().c_str(),
              httpStatusCode,
              frame->IsMain() ? "YES" : "NO");
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode,
                     const CefString& errorText,
                     const CefString& failedUrl) override {
        NSLog(@"❌ OnLoadError: url=%s error=%d text=%s",
              failedUrl.ToString().c_str(),
              errorCode,
              errorText.ToString().c_str());
    }

    // CefDisplayHandler overrides
    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override {
        NSString* titleCopy = [NSString stringWithUTF8String:title.ToString().c_str()];
        NSLog(@"📄 OnTitleChange: %@", titleCopy);
        dispatch_async(dispatch_get_main_queue(), ^{
            _currentTitle = titleCopy;
        });
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        NSString* urlCopy = [NSString stringWithUTF8String:url.ToString().c_str()];
        NSLog(@"🔗 OnAddressChange: %@", urlCopy);
        dispatch_async(dispatch_get_main_queue(), ^{
            _currentURL = urlCopy;
        });
    }

    // State accessors (called from Objective-C methods below)
    bool IsLoading() const { return _isLoading; }
    bool CanGoBack() const { return _canGoBack; }
    bool CanGoForward() const { return _canGoForward; }
    NSString* GetTitle() const { return _currentTitle; }
    NSString* GetURL() const { return _currentURL; }

private:
    std::atomic<bool> _isLoading{false};
    std::atomic<bool> _canGoBack{false};
    std::atomic<bool> _canGoForward{false};
    NSString* __strong _currentTitle = nil;
    NSString* __strong _currentURL = nil;

    IMPLEMENT_REFCOUNTING(ChromiumClient);
};

// ─── Global State ───────────────────────────────────────────────────────────────

static BOOL g_cefInitialized = NO;
static CefRefPtr<CefBrowser> g_browser;
static CefRefPtr<ChromiumClient> g_client;

// ─── CEFWrapper Implementation ───────────────────────────────────────────────────

@implementation CEFWrapper

+ (int)executeSubprocessWithArgc:(int)argc argv:(char **)argv {
    CefMainArgs args(argc, argv);
    return CefExecuteProcess(args, nullptr, nullptr);
}

+ (BOOL)initializeCEFWithError:(NSError **)error {
    if (g_cefInitialized) {
        NSLog(@"✓ CEF already initialized");
        return YES;
    }

    // The CEF C++ API uses stubs — all function pointers are null until the
    // framework is explicitly loaded via dlopen. LoadInMain() finds the framework
    // in the app bundle's Frameworks directory and populates the stubs.
    static CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInMain()) {
        NSLog(@"❌ Failed to load Chromium Embedded Framework");
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                        code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to load Chromium Embedded Framework"}];
        }
        return NO;
    }
    NSLog(@"✓ Chromium Embedded Framework loaded");

    CefMainArgs args;
    CefSettings settings;
    settings.no_sandbox = 1;
    settings.external_message_pump = 1;
    // Leave browser_subprocess_path empty — this tells CEF to use the main app executable
    // for all subprocess roles (renderer, GPU, utility, network). CefExecuteProcess() at
    // app startup will detect subprocess roles and handle them accordingly.

    // Enable verbose CEF logging to debug page rendering issues
    settings.log_severity = LOGSEVERITY_VERBOSE;
    NSString* cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (cacheDir) {
        NSString* logPath = [cacheDir stringByAppendingPathComponent:@"com.chromium.webview/debug.log"];
        CefString(&settings.log_file).FromString([logPath UTF8String]);
        NSLog(@"🔧 CEF debug log: %@", logPath);
    }

    // Set cache path to avoid singleton behavior warnings
    if (cacheDir) {
        cacheDir = [cacheDir stringByAppendingPathComponent:@"com.chromium.webview"];
        CefString(&settings.root_cache_path).FromString([cacheDir UTF8String]);
    }

    NSLog(@"🔧 Calling CefInitialize with cache dir: %@", cacheDir);
    if (!CefInitialize(args, settings, nullptr, nullptr)) {
        NSLog(@"❌ CefInitialize failed");
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"CefInitialize failed"}];
        }
        return NO;
    }

    NSLog(@"✓ CefInitialize succeeded");
    g_cefInitialized = YES;
    return YES;
}

+ (nullable NSView *)createBrowserInView:(NSView *)parentView
                                     url:(NSString *)urlString {
    if (!g_cefInitialized) {
        NSLog(@"❌ CEF not initialized — cannot create browser");
        return nil;
    }

    NSLog(@"🔧 Creating browser for URL: %@", urlString);
    NSLog(@"🖼️ parentView: %@ bounds: %@", parentView, NSStringFromRect(parentView.bounds));

    // Window info — SetAsChild forces Alloy (windowed-child) mode
    CefWindowInfo windowInfo;
    NSRect parentBounds = parentView.bounds;
    NSLog(@"🔧 Calling SetAsChild with parentView=%@ rect=(%d,%d,%d,%d)",
          parentView, (int)parentBounds.origin.x, (int)parentBounds.origin.y,
          (int)parentBounds.size.width, (int)parentBounds.size.height);
    windowInfo.SetAsChild((__bridge void*)parentView,
                          CefRect((int)parentBounds.origin.x, (int)parentBounds.origin.y,
                                  (int)parentBounds.size.width, (int)parentBounds.size.height));

    // Browser settings
    CefBrowserSettings browserSettings;

    // Create the C++ client
    g_client = new ChromiumClient();

    // Create the browser
    CefString url;
    url.FromString([urlString UTF8String]);

    CefRefPtr<CefBrowser> browser =
        CefBrowserHost::CreateBrowserSync(windowInfo, g_client, url, browserSettings, nullptr, nullptr);

    if (!browser) {
        NSLog(@"❌ CreateBrowserSync returned null");
        g_client = nullptr;
        return nil;
    }

    NSLog(@"✓ Browser created: %p", browser.get());
    g_browser = browser;

    // Get the native view that CEF created and is rendering into
    NSView* cefView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    NSLog(@"✅ Browser setup complete: CEF view=%@ frame=%@", cefView, NSStringFromRect(cefView.frame));
    NSLog(@"🌍 Initial URL: %@", urlString);

    // Return the CEF-created view (it's already added to parentView by SetAsChild)
    return cefView;
}

+ (void)reloadBrowser {
    if (g_browser) {
        g_browser->Reload();
    } else {
        NSLog(@"⚠️  No browser");
    }
}

+ (void)closeBrowser {
    if (g_browser) {
        NSLog(@"🛑 Closing browser");
        g_browser->GetHost()->CloseBrowser(true);
        g_browser = nullptr;
        g_client = nullptr;
    }
}

+ (void)goBack {
    if (g_browser) {
        g_browser->GoBack();
    }
}

+ (void)goForward {
    if (g_browser) {
        g_browser->GoForward();
    }
}

+ (void)loadURL:(NSString *)urlString {
    if (!g_browser) {
        NSLog(@"⚠️  No browser instance");
        return;
    }

    CefRefPtr<CefFrame> frame = g_browser->GetMainFrame();
    if (!frame) {
        NSLog(@"⚠️  No main frame");
        return;
    }

    CefString url;
    url.FromString([urlString UTF8String]);
    frame->LoadURL(url);
    NSLog(@"🌐 Loaded URL: %@", urlString);
}

+ (void)doMessageLoopWork {
    if (g_cefInitialized) {
        CefDoMessageLoopWork();
    }
}

+ (void)shutdown {
    if (!g_cefInitialized) return;

    NSLog(@"🛑 Shutting down CEF");

    // Release the browser and client references
    g_browser = nullptr;
    g_client = nullptr;

    CefShutdown();
    g_cefInitialized = NO;
}

+ (BOOL)isLoading {
    return g_client && g_client->IsLoading();
}

+ (BOOL)canGoBack {
    return g_client && g_client->CanGoBack();
}

+ (BOOL)canGoForward {
    return g_client && g_client->CanGoForward();
}

+ (nullable NSString *)currentTitle {
    return g_client ? g_client->GetTitle() : nil;
}

+ (nullable NSString *)currentURL {
    return g_client ? g_client->GetURL() : nil;
}

@end
