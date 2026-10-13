//
//  CEFRenderProcess.mm
//  CEFWebView
//
//  Runs in renderer processes: the page-facing half of JavaScript evaluation and script messages.
//

#include "CEFRenderProcess.h"

#include "include/cef_process_message.h"
#include "include/cef_v8.h"

namespace cefwebview {
namespace {

/// JSON text for `value`, empty for undefined (and for values JSON has no form of, like functions).
/// Returns false with `error` set if JSON.stringify throws (cyclic objects, BigInt).
bool Stringify(CefRefPtr<CefV8Context> context, CefRefPtr<CefV8Value> value, CefString& json, CefString& error) {
    json.clear();
    if (!value || value->IsUndefined() || value->IsFunction()) {
        return true;
    }
    CefRefPtr<CefV8Value> JSON = context->GetGlobal()->GetValue("JSON");
    CefRefPtr<CefV8Value> stringify = JSON ? JSON->GetValue("stringify") : nullptr;
    if (!stringify || !stringify->IsFunction()) {
        error = "JSON.stringify is not available";
        return false;
    }
    CefRefPtr<CefV8Value> result = stringify->ExecuteFunction(JSON, {value});
    if (!result) {
        error = stringify->HasException() ? stringify->GetException()->GetMessage() : "JSON.stringify failed";
        stringify->ClearException();
        return false;
    }
    if (result->IsString()) {
        json = result->GetStringValue();
    }
    return true;
}

/// Readable text for a thrown value or rejection reason.
CefString ErrorMessage(CefRefPtr<CefV8Value> reason) {
    if (reason && reason->IsString()) {
        return reason->GetStringValue();
    }
    if (reason && reason->IsObject()) {
        CefRefPtr<CefV8Value> message = reason->GetValue("message");
        if (message && message->IsString()) {
            return message->GetStringValue();
        }
    }
    return "JavaScript promise was rejected";
}

void SendResult(CefRefPtr<CefFrame> frame, int requestID, bool succeeded, const CefString& payload) {
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kEvaluateResult);
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    args->SetInt(0, requestID);
    args->SetBool(1, succeeded);
    args->SetString(2, payload);
    frame->SendProcessMessage(PID_BROWSER, message);
}

void SendValue(CefRefPtr<CefV8Context> context, CefRefPtr<CefFrame> frame, int requestID,
               CefRefPtr<CefV8Value> value) {
    CefString json;
    CefString error;
    if (Stringify(context, value, json, error)) {
        SendResult(frame, requestID, true, json);
    } else {
        SendResult(frame, requestID, false, error);
    }
}

/// `then` callbacks for a promise returned by an evaluated script.
class PromiseSettler final : public CefV8Handler {
public:
    PromiseSettler(CefRefPtr<CefFrame> frame, int requestID) : frame_(frame), requestID_(requestID) {}

    bool Execute(const CefString& name, CefRefPtr<CefV8Value> object, const CefV8ValueList& arguments,
                 CefRefPtr<CefV8Value>& retval, CefString& exception) override {
        if (settled_) {
            return true;
        }
        settled_ = true;
        CefRefPtr<CefV8Value> value = arguments.empty() ? CefV8Value::CreateUndefined() : arguments[0];
        if (name == "resolve") {
            SendValue(CefV8Context::GetCurrentContext(), frame_, requestID_, value);
        } else {
            SendResult(frame_, requestID_, false, ErrorMessage(value));
        }
        return true;
    }

private:
    CefRefPtr<CefFrame> frame_;
    int requestID_;
    bool settled_ = false;

    IMPLEMENT_REFCOUNTING(PromiseSettler);
};

/// `window.cefWebView.postMessage(name, body)` for one frame.
class PostMessageHandler final : public CefV8Handler {
public:
    explicit PostMessageHandler(CefRefPtr<CefFrame> frame) : frame_(frame) {}

    bool Execute(const CefString& name, CefRefPtr<CefV8Value> object, const CefV8ValueList& arguments,
                 CefRefPtr<CefV8Value>& retval, CefString& exception) override {
        if (arguments.empty() || !arguments[0]->IsString()) {
            exception = "cefWebView.postMessage(name, body): name must be a string";
            return true;
        }
        CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
        CefString json;
        CefString error;
        CefRefPtr<CefV8Value> body = arguments.size() > 1 ? arguments[1] : CefV8Value::CreateUndefined();
        if (!Stringify(context, body, json, error)) {
            exception = error;
            return true;
        }
        if (!frame_->IsValid()) {
            exception = "cefWebView.postMessage: the frame is detached";
            return true;
        }
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPostMessage);
        CefRefPtr<CefListValue> args = message->GetArgumentList();
        args->SetString(0, arguments[0]->GetStringValue());
        args->SetString(1, json);
        args->SetBool(2, frame_->IsMain());
        frame_->SendProcessMessage(PID_BROWSER, message);
        retval = CefV8Value::CreateUndefined();
        return true;
    }

private:
    CefRefPtr<CefFrame> frame_;

    IMPLEMENT_REFCOUNTING(PostMessageHandler);
};

class RenderProcessHandler final : public CefRenderProcessHandler {
public:
    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        CefRefPtr<CefV8Value> api = CefV8Value::CreateObject(nullptr, nullptr);
        api->SetValue("postMessage", CefV8Value::CreateFunction("postMessage", new PostMessageHandler(frame)),
                      V8_PROPERTY_ATTRIBUTE_READONLY);
        context->GetGlobal()->SetValue("cefWebView", api, V8_PROPERTY_ATTRIBUTE_READONLY);
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  CefProcessId sourceProcess, CefRefPtr<CefProcessMessage> message) override {
        if (message->GetName() != kEvaluate) {
            return false;
        }
        CefRefPtr<CefListValue> args = message->GetArgumentList();
        const int requestID = args->GetInt(0);
        CefRefPtr<CefV8Context> context = frame->GetV8Context();
        if (!context || !context->Enter()) {
            SendResult(frame, requestID, false, "The page has no JavaScript context");
            return true;
        }
        CefRefPtr<CefV8Value> value;
        CefRefPtr<CefV8Exception> exception;
        if (!context->Eval(args->GetString(1), CefString(), 0, value, exception)) {
            SendResult(frame, requestID, false, exception ? exception->GetMessage() : "Evaluation failed");
        } else if (value->IsPromise()) {
            CefRefPtr<CefV8Handler> settler = new PromiseSettler(frame, requestID);
            CefRefPtr<CefV8Value> then = value->GetValue("then");
            then->ExecuteFunction(value, {CefV8Value::CreateFunction("resolve", settler),
                                          CefV8Value::CreateFunction("reject", settler)});
        } else {
            SendValue(context, frame, requestID, value);
        }
        context->Exit();
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(RenderProcessHandler);
};

}  // namespace

CefRefPtr<CefRenderProcessHandler> CreateRenderProcessHandler() {
    return new RenderProcessHandler();
}

}  // namespace cefwebview
