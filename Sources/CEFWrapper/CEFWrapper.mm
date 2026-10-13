//
//  CEFWrapper.mm
//  CEFWebView
//
//  Objective-C++ wrapper for the CEF C++ API.
//

#import "include/CEFWrapper.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#include <cstring>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_load_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

NSNotificationName const CEFHelperSpawnedNotification = @"CEFHelperSpawned";

// ─── CEF App: command-line switches applied in every process ───────────────────
//
// macOS often fails to spawn the GPU process (error 1003) under the default app
// configuration (Hardened Runtime / Mach limits), then Chromium aborts with
// "GPU process isn't usable". Disabling GPU forces software rendering and avoids
// that subprocess. Pass the same CefApp to CefExecuteProcess and CefInitialize.

namespace {

/// Helper processes are shared by every browser, so this is a process-wide notification.
static void PostHelperSpawned(const char* helperType) {
    NSString* type = [NSString stringWithUTF8String:helperType];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CEFHelperSpawnedNotification
                                                            object:nil
                                                          userInfo:@{@"type": type}];
    });
}

// ─── External message pump ───────────────────────────────────────────────────
//
// Mirrors CEF's MainMessageLoopExternalPumpMac: run work when CEF schedules it, and also on a
// ~30 Hz fallback timer. Scheduled callbacks alone can be coalesced or missed, which stalls the
// browser process (requests sent, never answered, blank page stuck on "Loading...").

static bool g_cefPumpActive = false;
static bool g_cefInMessageLoopWork = false;
static NSTimer* g_cefPumpTimer = nil;

static void PerformCEFMessageLoopWork() {
    // CefDoMessageLoopWork can re-enter via nested run loops (menus, modal panels); skip those.
    if (!g_cefPumpActive || g_cefInMessageLoopWork) {
        return;
    }
    g_cefInMessageLoopWork = true;
    CefDoMessageLoopWork();
    g_cefInMessageLoopWork = false;
}

static void StartCEFMessagePumpTimer() {
    g_cefPumpActive = true;
    if (g_cefPumpTimer) {
        return;
    }
    g_cefPumpTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0
                                            repeats:YES
                                              block:^(NSTimer*) { PerformCEFMessageLoopWork(); }];
    // Common modes so the pump keeps running during window resizing and menu tracking.
    [[NSRunLoop mainRunLoop] addTimer:g_cefPumpTimer forMode:NSRunLoopCommonModes];
}

static void StopCEFMessagePumpTimer() {
    g_cefPumpActive = false;
    [g_cefPumpTimer invalidate];
    g_cefPumpTimer = nil;
}

class CEFWebViewApp final : public CefApp, public CefBrowserProcessHandler {
public:
    CEFWebViewApp() = default;

    void OnBeforeCommandLineProcessing(const CefString& process_type,
                                       CefRefPtr<CefCommandLine> command_line) override {
        // Disable GPU to avoid process launch failures under Hardened Runtime / Mach limits
        command_line->AppendSwitch("disable-gpu");
        // Do NOT disable gpu-compositing — it can break renderer rendering
        command_line->AppendSwitch("disable-gpu-sandbox");
        // QUIC / HTTP3 can complicate loads on some networks
        command_line->AppendSwitch("disable-quic");
        // Skip the "Chromium Safe Storage" keychain item. Its ACL is tied to the code signature, so
        // every rebuild (especially ad-hoc) re-prompts for keychain access. Cookies are stored
        // unencrypted in the cache dir instead — fine for this demo app, not for a shipping browser.
        command_line->AppendSwitch("use-mock-keychain");
    }

    /// Called before each child process is launched (GPU, utility, renderer, etc.).
    /// Maps Chromium subprocess types to our Swift UI helper indicators.
    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line) override {
        if (!command_line.get()) {
            return;
        }
        CefString typeStr = command_line->GetSwitchValue("type");
        std::string type = typeStr.ToString();
        if (type.empty()) {
            return;
        }
        if (type == "gpu-process") {
            PostHelperSpawned("gpu");
        } else if (type == "utility") {
            CefString sub = command_line->GetSwitchValue("utility-sub-type");
            std::string subStr = sub.ToString();
            if (subStr.find("NetworkService") != std::string::npos) {
                PostHelperSpawned("network");
            } else if (subStr.find("Storage") != std::string::npos) {
                PostHelperSpawned("storage");
            }
        } else if (type == "renderer") {
            PostHelperSpawned("renderer");
        }
        NSLog(@"🔧 OnBeforeChildProcessLaunch: type=%s utility-sub-type=%s",
              type.c_str(),
              command_line->GetSwitchValue("utility-sub-type").ToString().c_str());
    }

    /// Required when using external_message_pump + CefDoMessageLoopWork; without this, renderer IPC
    /// is not serviced promptly and navigations fail with ERR_ABORTED / blank views.
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        // Disabled this log message because it spams the logs
        // NSLog(@"⏰ OnScheduleMessagePumpWork: delay_ms=%lld", delay_ms);
        if (delay_ms <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PerformCEFMessageLoopWork();
            });
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                PerformCEFMessageLoopWork();
            });
        }
    }

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

private:
    IMPLEMENT_REFCOUNTING(CEFWebViewApp);
};

}  // namespace

// ─── NSApplication: CefAppProtocol ──────────────────────────────────────────────
//
// Chromium asks NSApp whether it is inside -sendEvent: (CrAppProtocol) and throws an
// unrecognized-selector exception if it cannot answer, e.g. while closing a browser. CEF apps
// normally subclass NSApplication; SwiftUI owns the application class, so add the protocol with a
// category and wrap -sendEvent: the way CEF's ClientApplication does.

static BOOL g_handlingSendEvent = NO;

@interface NSApplication (CEFAppProtocol) <CefAppProtocol>
@end

@implementation NSApplication (CEFAppProtocol)

- (BOOL)isHandlingSendEvent {
    return g_handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    g_handlingSendEvent = handlingSendEvent;
}

- (void)cef_sendEvent:(NSEvent *)event {
    CefScopedSendingEvent sendingEventScoper;
    [self cef_sendEvent:event];  // Swizzled: calls the original -sendEvent:.
}

@end

static void InstallCEFSendEventHook() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method original = class_getInstanceMethod([NSApplication class], @selector(sendEvent:));
        Method replacement = class_getInstanceMethod([NSApplication class], @selector(cef_sendEvent:));
        method_exchangeImplementations(original, replacement);
    });
}

// ─── Browser registry ───────────────────────────────────────────────────────────
//
// Every browser between OnAfterCreated and OnBeforeClose. CefShutdown must not run while any
// browser is still open, so +shutdown closes these and pumps CEF until the list is empty.

static std::vector<CefRefPtr<CefBrowser>> g_openBrowsers;

static void RunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static NSString* NSStringFromCef(const CefString& value) {
    return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

@interface CEFBrowserHandle ()
- (void)browserDidClose;
@end

// ─── C++ Client Class ───────────────────────────────────────────────────────────
//
// One client per CEFBrowserHandle. Forwards CEF callbacks (UI thread, which is the main thread on
// macOS) to the handle's delegate. Holds the handle weakly; CEF keeps the client alive until the
// browser closes, which may be after the handle is gone.

class ChromiumClient : public CefClient,
                       public CefLifeSpanHandler,
                       public CefLoadHandler,
                       public CefDisplayHandler,
                       public CefRequestHandler {
public:
    explicit ChromiumClient(CEFBrowserHandle* handle) : _handle(handle) {}

    // CefClient overrides
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    // CefLifeSpanHandler overrides
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        g_openBrowsers.push_back(browser);
        NSLog(@"✅ OnAfterCreated: browser id=%d (open browsers: %zu)",
              browser->GetIdentifier(), g_openBrowsers.size());
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        std::erase_if(g_openBrowsers, [&](const CefRefPtr<CefBrowser>& b) { return b->IsSame(browser); });
        NSLog(@"🛑 OnBeforeClose: browser id=%d (open browsers: %zu)",
              browser->GetIdentifier(), g_openBrowsers.size());
        WithHandle(^(CEFBrowserHandle* handle) { [handle browserDidClose]; });
    }

    // CefRequestHandler overrides
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                   TerminationStatus status,
                                   int error_code,
                                   const CefString& error_string) override {
        NSLog(@"💥 OnRenderProcessTerminated: status=%d error=%d %@",
              (int)status, error_code, NSStringFromCef(error_string));
        WithDelegate(^(CEFBrowserHandle* handle, id<CEFBrowserHandleDelegate> delegate) {
            [delegate browserHandle:handle renderProcessTerminatedWithStatus:status];
        });
    }

    // CefLoadHandler overrides
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading, bool canGoBack, bool canGoForward) override {
        WithDelegate(^(CEFBrowserHandle* handle, id<CEFBrowserHandleDelegate> delegate) {
            [delegate browserHandle:handle
                loadingStateChanged:isLoading
                          canGoBack:canGoBack
                       canGoForward:canGoForward];
        });
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode,
                     const CefString& errorText,
                     const CefString& failedUrl) override {
        // Subframe failures (ads, trackers, blocked embeds) are not document load failures.
        // ERR_ABORTED (-3) is normal for redirects and interrupted navigations.
        if (!frame->IsMain() || errorCode == ERR_ABORTED) {
            return;
        }
        NSString* text = NSStringFromCef(errorText);
        NSString* url = NSStringFromCef(failedUrl);
        NSLog(@"❌ OnLoadError (main frame): url=%@ error=%d text=%@", url, (int)errorCode, text);
        WithDelegate(^(CEFBrowserHandle* handle, id<CEFBrowserHandleDelegate> delegate) {
            [delegate browserHandle:handle
                mainFrameLoadFailedWithCode:errorCode
                                  errorText:text
                                  failedURL:url];
        });
    }

    // CefDisplayHandler overrides
    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
        NSString* titleCopy = NSStringFromCef(title);
        WithDelegate(^(CEFBrowserHandle* handle, id<CEFBrowserHandleDelegate> delegate) {
            [delegate browserHandle:handle titleChanged:titleCopy];
        });
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        if (!frame->IsMain()) {
            return;
        }
        NSString* urlCopy = NSStringFromCef(url);
        WithDelegate(^(CEFBrowserHandle* handle, id<CEFBrowserHandleDelegate> delegate) {
            [delegate browserHandle:handle addressChanged:urlCopy];
        });
    }

    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
        WithDelegate(^(CEFBrowserHandle* handle, id<CEFBrowserHandleDelegate> delegate) {
            [delegate browserHandle:handle progressChanged:progress];
        });
    }

private:
    void WithHandle(void (^block)(CEFBrowserHandle*)) {
        __weak CEFBrowserHandle* weakHandle = _handle;
        RunOnMain(^{
            CEFBrowserHandle* handle = weakHandle;
            if (handle) {
                block(handle);
            }
        });
    }

    void WithDelegate(void (^block)(CEFBrowserHandle*, id<CEFBrowserHandleDelegate>)) {
        WithHandle(^(CEFBrowserHandle* handle) {
            id<CEFBrowserHandleDelegate> delegate = handle.delegate;
            if (delegate) {
                block(handle, delegate);
            }
        });
    }

    __weak CEFBrowserHandle* _handle;

    IMPLEMENT_REFCOUNTING(ChromiumClient);
};


// ─── Global State ───────────────────────────────────────────────────────────────

static BOOL g_cefInitialized = NO;

/// Single loader per process. On macOS, main browser must call LoadInMain(); CEF helper
/// subprocesses (same binary, `--type=...`) must call LoadInHelper() — see cef_library_loader.h.
static CefScopedLibraryLoader g_cefLibraryLoader;

/// CefScopedLibraryLoader does not allow calling LoadInMain/LoadInHelper twice; the second
/// call fails. We load once in executeSubprocessWithArgc, then initializeCEFWithError must skip.
static BOOL g_cefFrameworkDylibLoaded = NO;

static bool CEFIsHelperProcess(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (a && std::strncmp(a, "--type=", 7) == 0) {
            return true;
        }
    }
    return false;
}

/// |isHelperProcess|: YES → LoadInHelper(), NO → LoadInMain(). Ignored if already loaded.
static BOOL EnsureCEFFrameworkLoaded(BOOL isHelperProcess, NSError **error) {
    if (g_cefFrameworkDylibLoaded) {
        return YES;
    }
    const bool ok = isHelperProcess ? g_cefLibraryLoader.LoadInHelper() : g_cefLibraryLoader.LoadInMain();
    if (!ok) {
        NSLog(@"❌ Failed to load Chromium Embedded Framework (%s process)",
              isHelperProcess ? "helper" : "main");
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to load Chromium Embedded Framework"}];
        }
        return NO;
    }
    g_cefFrameworkDylibLoaded = YES;
    return YES;
}

// ─── CEFBrowserHandle Implementation ─────────────────────────────────────────────

@implementation CEFBrowserHandle {
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<ChromiumClient> _client;
    BOOL _closeRequested;
}

- (nullable instancetype)initWithParentView:(NSView *)parentView
                                        url:(NSString *)urlString
                                   delegate:(nullable id<CEFBrowserHandleDelegate>)delegate {
    if (!g_cefInitialized) {
        NSLog(@"💥 CRITICAL: CEF not initialized — cannot create browser. "
              @"Call initializeCEFWithError: first and check for errors.");
        return nil;
    }
    if (urlString.length == 0) {
        NSLog(@"💥 CRITICAL: urlString is empty — cannot create browser");
        return nil;
    }

    self = [super init];
    if (!self) {
        return nil;
    }
    _delegate = delegate;
    _client = new ChromiumClient(self);

    // SetAsChild forces Alloy (windowed-child) mode.
    NSRect bounds = parentView.bounds;
    CefWindowInfo windowInfo;
    windowInfo.SetAsChild((__bridge void*)parentView,
                          CefRect((int)bounds.origin.x, (int)bounds.origin.y,
                                  (int)bounds.size.width, (int)bounds.size.height));
    CefBrowserSettings browserSettings;
    CefString url;
    url.FromString(urlString.UTF8String);

    NSLog(@"🔧 Creating browser for URL: %@ bounds: %@", urlString, NSStringFromRect(bounds));
    _browser = CefBrowserHost::CreateBrowserSync(windowInfo, _client, url, browserSettings, nullptr, nullptr);
    if (!_browser) {
        NSLog(@"💥 CRITICAL: CreateBrowserSync returned null. Likely causes: helper process crash, "
              @"dyld framework loading failure, JIT entitlements missing, or invalid code signatures.");
        _client = nullptr;
        return nil;
    }
    NSLog(@"✅ Browser created: id=%d", _browser->GetIdentifier());
    return self;
}

- (void)dealloc {
    // A handle that goes away without -close still owns an open browser; close it so it is not leaked.
    if (_browser && !_closeRequested) {
        _browser->GetHost()->CloseBrowser(true);
    }
}

- (BOOL)isOpen {
    return _browser != nullptr && !_closeRequested;
}

- (nullable NSView *)browserView {
    if (!self.isOpen) {
        return nil;
    }
    return (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
}

- (void)loadURL:(NSString *)urlString {
    if (!self.isOpen) {
        return;
    }
    CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
    if (!frame) {
        NSLog(@"⚠️ [loadURL] No main frame");
        return;
    }
    CefString url;
    url.FromString(urlString.UTF8String);
    frame->LoadURL(url);
}

- (void)reload {
    if (self.isOpen) {
        _browser->Reload();
    }
}

- (void)goBack {
    if (self.isOpen) {
        _browser->GoBack();
    }
}

- (void)goForward {
    if (self.isOpen) {
        _browser->GoForward();
    }
}

- (void)notifyGeometryChanged {
    if (self.isOpen) {
        _browser->GetHost()->WasResized();
    }
}

- (void)close {
    if (!self.isOpen) {
        return;
    }
    _closeRequested = YES;
    NSLog(@"🛑 Closing browser id=%d", _browser->GetIdentifier());
    _browser->GetHost()->CloseBrowser(true);
}

- (void)browserDidClose {
    _browser = nullptr;
    _client = nullptr;
    _closeRequested = YES;
    [self.delegate browserHandleDidClose:self];
}

@end

// ─── CEFWrapper Implementation ───────────────────────────────────────────────────

@implementation CEFWrapper

+ (int)executeSubprocessWithArgc:(int)argc argv:(char **)argv {
    NSMutableString* argDump = [NSMutableString stringWithFormat:@"executeSubprocessWithArgc: argc=%d", argc];
    if (argc > 0 && argv) {
        for (int i = 0; i < argc; i++) {
            const char* a = argv[i];
            NSString* s = a ? [NSString stringWithUTF8String:a] : @"(null)";
            [argDump appendFormat:@"\n  argv[%d] = %@", i, s];
        }
    } else {
        [argDump appendString:@" (argv nil or argc <= 0)"];
    }
    NSLog(@"%@", argDump);

    const BOOL isCEFHelperArgv = CEFIsHelperProcess(argc, argv);
    if (isCEFHelperArgv) {
        NSLog(@"executeSubprocessWithArgc: this process has --type=… — CEF helper role; "
              @"CefExecuteProcess will handle it and this process should exit.");
    } else {
        NSLog(@"executeSubprocessWithArgc: no --type= in argv — this is the main browser binary "
              @"(Xcode often adds -NSDocumentRevisionsDebugMode etc.). "
              @"GPU/utility/renderer helpers are separate OS processes (<App> Helper.app); "
              @"their executeSubprocessWithArgc logs appear under the helper process, "
              @"not the app — include helper processes in Console or log show.");
    }

    // Without loading the framework first, CefExecuteProcess jumps through a null stub (crash at 0x0).
    // Helper subprocesses must use LoadInHelper(), not LoadInMain() — see CEF cef_library_loader.h.
    if (!EnsureCEFFrameworkLoaded(CEFIsHelperProcess(argc, argv) ? YES : NO, nil)) {
        return 1;
    }
    CefMainArgs args(argc, argv);
    CefRefPtr<CefApp> app = new CEFWebViewApp();
    return CefExecuteProcess(args, app, nullptr);
}

+ (BOOL)initializeCEFWithError:(NSError **)error {
    if (g_cefInitialized) {
        NSLog(@"✓ CEF already initialized");
        return YES;
    }

    // Browser process only (helpers never reach initializeCEF). Framework was already loaded
    // in executeSubprocessWithArgc — EnsureCEFFrameworkLoaded skips the second load.
    if (!EnsureCEFFrameworkLoaded(NO, error)) {
        return NO;
    }
    NSLog(@"✓ Chromium Embedded Framework loaded");

    CefMainArgs args;
    CefSettings settings;

    settings.no_sandbox = 1;
    settings.external_message_pump = 1;

    // Enable verbose logging
    settings.log_severity = LOGSEVERITY_VERBOSE;
    CefString(&settings.log_file).FromString("/tmp/cef_debug.log");

    // Also append command-line switches for extra verbosity
    CefRefPtr<CefCommandLine> command_line = CefCommandLine::GetGlobalCommandLine();
    if (command_line.get()) {
        command_line->AppendSwitch("enable-logging");
        command_line->AppendSwitchWithValue("v", "3");  // v=3 for very verbose

        // TEST: Single-process mode to isolate subprocess spawning issues
        // If single-process mode works, the problem is subprocess spawning.
        // If it still fails, the problem is in CEF core or configuration.
        // IMPORTANT: Remove this after testing — single-process is not production-ready.
        // Uncomment the line below to enable:
        // command_line->AppendSwitch("single-process");
    }

#if TARGET_OS_OSX
    // macOS: helpers are installed by Scripts/cef-embed as "<executable> Helper.app" next to the framework.
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSLog(@"🔍 Main bundle path: %@", bundlePath);
    NSString *frameworksDir = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"];
    NSLog(@"🔍 Frameworks dir: %@", frameworksDir);

    // HARD FAIL: CEF framework must exist
    NSString *cefFrameworkPath =
        [frameworksDir stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cefFrameworkPath]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CEF framework not found at %@. This is a critical initialization failure. "
            @"Verify the Chromium Embedded Framework is properly embedded in the app bundle.",
            cefFrameworkPath];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ CEF framework verified at: %@", cefFrameworkPath);

    // HARD FAIL: CEF resources (icudtl.dat, *.pak files) must exist
    NSString *cefResourcesPath = [cefFrameworkPath stringByAppendingPathComponent:@"Resources"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cefResourcesPath]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CEF resources not found at %@. This is a critical initialization failure. "
            @"Without these resources, page navigation will abort with ERR_ABORTED.",
            cefResourcesPath];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ CEF resources verified at: %@", cefResourcesPath);

    // HARD FAIL: the helper executable must exist and be executable. CEF finds the GPU and
    // renderer variants from this path by appending " (GPU)" / " (Renderer)" to the bundle name.
    NSString *executableName = [[[NSBundle mainBundle] executablePath] lastPathComponent];
    NSString *helperName = [executableName stringByAppendingString:@" Helper"];
    NSString *helperExe = [frameworksDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.app/Contents/MacOS/%@", helperName, helperName]];
    NSLog(@"🔍 Checking helper at: %@", helperExe);

    if (![[NSFileManager defaultManager] fileExistsAtPath:helperExe]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CEF helper executable not found at %@. This is a critical initialization failure. "
            @"Add a Run Script build phase that runs CEFWebView's Scripts/cef-embed.",
            helperExe];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ Helper executable exists at: %@", helperExe);

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:helperExe]) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CEF helper at %@ exists but is not executable. This is a critical initialization failure. "
            @"Check that the Scripts/cef-embed build phase ran and signed it.",
            helperExe];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }
    NSLog(@"✅ Helper is executable");
#endif

    // Set CEF settings using direct method that keeps data alive
    CefString(&settings.browser_subprocess_path).FromString([helperExe UTF8String]);
    NSLog(@"✅ CEF browser_subprocess_path configured: %@", helperExe);

    CefString(&settings.resources_dir_path).FromString([cefResourcesPath UTF8String]);
    CefString(&settings.framework_dir_path).FromString([cefFrameworkPath UTF8String]);
    CefString(&settings.main_bundle_path).FromString([bundlePath UTF8String]);

    NSString *ua = [NSString stringWithFormat:
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        @"Chrome/%d.%d.%d.%d Safari/537.36",
        CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
    CefString(&settings.user_agent).FromString([ua UTF8String]);

    // Enable verbose CEF logging to debug page rendering issues
    settings.log_severity = LOGSEVERITY_VERBOSE;
    NSString* cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (cacheDir) {
        NSString* logPath = [cacheDir stringByAppendingPathComponent:@"com.chromium.webview/debug.log"];
        CefString(&settings.log_file).FromString([logPath UTF8String]);
        NSLog(@"✅ CEF debug log configured at: %@", logPath);
    }

    // Set cache path to avoid singleton behavior warnings
    if (cacheDir) {
        cacheDir = [cacheDir stringByAppendingPathComponent:@"com.chromium.webview"];
        CefString(&settings.root_cache_path).FromString([cacheDir UTF8String]);
        NSLog(@"✅ CEF cache path configured at: %@", cacheDir);
    }

    NSLog(@"🔧 ========================================");
    NSLog(@"🔧 CEF Initialization Settings:");
    NSLog(@"🔧   no_sandbox: %d", settings.no_sandbox);
    NSLog(@"🔧   external_message_pump: %d", settings.external_message_pump);
    NSLog(@"🔧   browser_subprocess_path: %@",
          [NSString stringWithUTF8String:CefString(&settings.browser_subprocess_path).ToString().c_str()]);
    NSLog(@"🔧   resources_dir_path: %@",
          [NSString stringWithUTF8String:CefString(&settings.resources_dir_path).ToString().c_str()]);
    NSLog(@"🔧 ========================================");

    InstallCEFSendEventHook();

    CefRefPtr<CefApp> app = new CEFWebViewApp();
    NSLog(@"🔧 Calling CefInitialize...");
    bool initResult = CefInitialize(args, settings, app, nullptr);
    NSLog(@"🔧 CefInitialize returned: %s", initResult ? "true" : "false");

    if (!initResult) {
        NSString *errorMsg = [NSString stringWithFormat:
            @"CefInitialize failed. This is a critical initialization failure. "
            @"Check the CEF debug log at %@/com.chromium.webview/debug.log for details. "
            @"Common causes: missing/invalid helper executable, resource file (icudtl.dat) not found, "
            @"framework path configuration error, or renderer subprocess initialization failure.",
            cacheDir ?: @"~/Library/Caches"];
        NSLog(@"💥 INITIALIZATION FAILED: %@", errorMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"CEFWrapper"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        return NO;
    }

    NSLog(@"✅ CefInitialize succeeded - CEF is now initialized and ready");
    g_cefInitialized = YES;
    StartCEFMessagePumpTimer();
    return YES;
}

+ (NSInteger)openBrowserCount {
    return (NSInteger)g_openBrowsers.size();
}

+ (void)shutdown {
    if (!g_cefInitialized) return;

    // CefShutdown requires every browser to have closed. Ask the remaining ones to close, then pump
    // CEF until OnBeforeClose has run for each (bounded, so a stuck renderer cannot hang quitting).
    if (!g_openBrowsers.empty()) {
        NSLog(@"🛑 Closing %zu open browser(s) before shutdown", g_openBrowsers.size());
        std::vector<CefRefPtr<CefBrowser>> browsers = g_openBrowsers;
        for (const auto& browser : browsers) {
            browser->GetHost()->CloseBrowser(true);
        }
        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        // Spin the run loop rather than sleeping: closing a windowed browser needs main-queue and
        // run-loop work (scheduled pump callbacks, view teardown), not just CefDoMessageLoopWork.
        while (!g_openBrowsers.empty() && deadline.timeIntervalSinceNow > 0) {
            PerformCEFMessageLoopWork();
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        if (!g_openBrowsers.empty()) {
            NSLog(@"⚠️ %zu browser(s) did not close in time; shutting down anyway", g_openBrowsers.size());
            g_openBrowsers.clear();
        }
    }

    NSLog(@"🛑 Shutting down CEF");
    StopCEFMessagePumpTimer();
    CefShutdown();
    g_cefInitialized = NO;
}

@end
