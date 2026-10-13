//
//  CEFRenderProcess.h
//  CEFWebView
//
//  Private: shared between the browser process (CEFWrapper.mm) and renderer processes
//  (CEFRenderProcess.mm). Both are compiled into the app and into the helper.
//

#pragma once

#include "include/cef_render_process_handler.h"

namespace cefwebview {

// Process messages between the browser and renderer processes.

/// Renderer → browser. Args: name (string), body JSON (string, empty for undefined), is main frame (bool).
inline constexpr char kPostMessage[] = "CEFWebView.postMessage";

/// Browser → renderer. Args: request id (int), script (string).
inline constexpr char kEvaluate[] = "CEFWebView.evaluate";

/// Renderer → browser. Args: request id (int), succeeded (bool), result JSON or error message (string;
/// empty result JSON means undefined).
inline constexpr char kEvaluateResult[] = "CEFWebView.evaluateResult";

/// Handles kEvaluate and installs `window.cefWebView` in every frame.
CefRefPtr<CefRenderProcessHandler> CreateRenderProcessHandler();

}  // namespace cefwebview
