#include <cstdlib>
#include "TextService.h"

#include "DisplayAttributes.h"
#include "LangBarButton.h"

#include <algorithm>
#include <cstring>
#include <new>

namespace araso {

namespace {

/// How far back the field is read: InputSession reads up to 256 UTF-16 units before the word.
constexpr LONG kLookBehind = 256;

/// TF_E_SYNCHRONOUS: the app holds its document just now and can't grant an edit session at once.
constexpr HRESULT kNotNow = static_cast<HRESULT>(0x80040209L);

UINT PendingMessage() {
    static UINT message = RegisterWindowMessageW(kPendingMessage);
    return message;
}

/// The key-by-key log for the typing test (`ARASO_LOG`): what happened, never which key or what text.
bool Verbose() {
    static const bool verbose = std::getenv("ARASO_LOG") != nullptr;
    return verbose;
}

bool IsModifier(WPARAM vk) {
    switch (vk) {
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
    case VK_MENU: case VK_LMENU: case VK_RMENU:
    case VK_LWIN: case VK_RWIN:
        return true;
    default:
        return false;
    }
}

/// Screen pixels, whatever the app's DPI awareness: an app that isn't DPI aware reports its text in
/// scaled coordinates, and the host (per-monitor aware) places its windows in physical ones.
RECT Physical(HWND window, RECT rect) {
    if (!window) return rect;
    POINT topLeft = {rect.left, rect.top}, bottomRight = {rect.right, rect.bottom};
    if (LogicalToPhysicalPointForPerMonitorDPI(window, &topLeft) &&
        LogicalToPhysicalPointForPerMonitorDPI(window, &bottomRight)) {
        rect = {topLeft.x, topLeft.y, bottomRight.x, bottomRight.y};
    }
    return rect;
}

Json RectJson(const RECT &rect) {
    Json out = Json::array();
    out.push(static_cast<int>(rect.left));
    out.push(static_cast<int>(rect.top));
    out.push(static_cast<int>(rect.right));
    out.push(static_cast<int>(rect.bottom));
    return out;
}

std::string Span(const Json &pair) {
    if (!pair.isArray() || pair.size() != 2) return "-";
    return std::to_string(pair[0].asInt()) + "+" + std::to_string(pair[1].asInt());
}

/// What a request saw of the field and what came back, for the typing test's log (`ARASO_LOG`):
/// positions and lengths, never the text.
void LogExchange(const Json &request, const Json &reply, bool floats) {
    const Json &context = request["context"];
    std::string line = request["op"].asString() + ": field from " + std::to_string(context["start"].asInt()) + ", " +
                       std::to_string(Wide(context["text"].asString()).size()) + " units, selection " +
                       Span(context["selection"]) + ", marked " + Span(context["marked"]);
    if (context["unreadable"].asBool()) line += ", unreadable";
    if (floats) line += ", kept here";
    line += "; ";
    line += reply["handled"].asBool() ? "handled" : "passed";
    if (reply["replay"].asBool()) line += ", replay";
    for (const Json &op : reply["ops"].items()) {
        line += ", " + op["kind"].asString() + " " + std::to_string(Wide(op["text"].asString()).size());
        if (op["replace"].isArray()) line += " at " + Span(op["replace"]);
    }
    Log("%s", line.c_str());
}

template <typename T> void SafeRelease(T *&pointer) {
    if (pointer) {
        pointer->Release();
        pointer = nullptr;
    }
}

}  // namespace

// MARK: - EditSession

STDMETHODIMP EditSession::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
        *object = static_cast<ITfEditSession *>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

// MARK: - TextService

TextService::TextService() { DllAddRef(); }
TextService::~TextService() { DllRelease(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void **object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfTextInputProcessor)) {
        *object = static_cast<ITfTextInputProcessor *>(this);
    } else if (IsEqualIID(riid, kIID_ITfTextInputProcessorEx)) {
        *object = static_cast<ITfTextInputProcessorEx *>(this);
    } else if (IsEqualIID(riid, IID_ITfThreadMgrEventSink)) {
        *object = static_cast<ITfThreadMgrEventSink *>(this);
    } else if (IsEqualIID(riid, IID_ITfKeyEventSink)) {
        *object = static_cast<ITfKeyEventSink *>(this);
    } else if (IsEqualIID(riid, IID_ITfCompositionSink)) {
        *object = static_cast<ITfCompositionSink *>(this);
    } else if (IsEqualIID(riid, kIID_ITfDisplayAttributeProvider)) {
        *object = static_cast<ITfDisplayAttributeProvider *>(this);
    }
    if (!*object) return E_NOINTERFACE;
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) TextService::Release() {
    LONG count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
}

STDMETHODIMP TextService::Activate(ITfThreadMgr *threadMgr, TfClientId clientId) {
    return ActivateEx(threadMgr, clientId, 0);
}

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr *threadMgr, TfClientId clientId, DWORD) {
    threadMgr_ = threadMgr;
    threadMgr_->AddRef();
    clientId_ = clientId;
    app_ = ProcessName();

    ITfSource *source = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void **>(&source)))) {
        source->AdviseSink(IID_ITfThreadMgrEventSink, static_cast<ITfThreadMgrEventSink *>(this), &threadMgrSinkCookie_);
        source->Release();
    }
    ITfKeystrokeMgr *keystrokes = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keystrokes)))) {
        keySinkAdvised_ = SUCCEEDED(keystrokes->AdviseKeyEventSink(clientId_, static_cast<ITfKeyEventSink *>(this), TRUE));
        keystrokes->Release();
    }
    RegisterAttributes();
    CreateMessageWindow();

    button_ = new (std::nothrow) LangBarButton(this);
    if (button_) {
        ITfLangBarItemMgr *items = nullptr;
        if (SUCCEEDED(threadMgr_->QueryInterface(kIID_ITfLangBarItemMgr, reinterpret_cast<void **>(&items)))) {
            items->AddItem(button_);
            items->Release();
        }
    }
    // The keyboard is "open": Araso has no off mode of its own (pause is per text field).
    ITfCompartmentMgr *compartments = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void **>(&compartments)))) {
        ITfCompartment *open = nullptr;
        if (SUCCEEDED(compartments->GetCompartment(kGuidCompartmentKeyboardOpenClose, &open))) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_I4;
            value.lVal = TRUE;
            open->SetValue(clientId_, &value);
            open->Release();
        }
        compartments->Release();
    }
    host_.Attach(app_, window_);
    Log("activated in %s", Utf8(app_).c_str());
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    if (composition_ && compositionContext_) CommitIn(compositionContext_, "blur");
    else if (!floating_.empty() && floatingContext_) CommitIn(floatingContext_, "blur");
    host_.Detach();
    if (button_) {
        ITfLangBarItemMgr *items = nullptr;
        if (threadMgr_ && SUCCEEDED(threadMgr_->QueryInterface(kIID_ITfLangBarItemMgr, reinterpret_cast<void **>(&items)))) {
            items->RemoveItem(button_);
            items->Release();
        }
        button_->Release();
        button_ = nullptr;
    }
    if (threadMgr_) {
        ITfKeystrokeMgr *keystrokes = nullptr;
        if (keySinkAdvised_ && SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keystrokes)))) {
            keystrokes->UnadviseKeyEventSink(clientId_);
            keystrokes->Release();
        }
        keySinkAdvised_ = false;
        ITfSource *source = nullptr;
        if (threadMgrSinkCookie_ != TF_INVALID_COOKIE &&
            SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void **>(&source)))) {
            source->UnadviseSink(threadMgrSinkCookie_);
            source->Release();
        }
        threadMgrSinkCookie_ = TF_INVALID_COOKIE;
    }
    SafeRelease(composition_);
    SafeRelease(compositionContext_);
    ClearFloating();
    DestroyMessageWindow();
    SafeRelease(threadMgr_);
    clientId_ = TF_CLIENTID_NULL;
    return S_OK;
}

// MARK: Focus

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr *focus, ITfDocumentMgr *previous) {
    if (focus == previous) return S_OK; // the same field again
    Log("focus moved in %s (%s)", Utf8(app_).c_str(), composition_ ? "while composing" : "idle");
    // What was being typed in the last field goes in there, as shown.
    if (composition_ && compositionContext_) CommitIn(compositionContext_, "blur");
    else if (!floating_.empty() && floatingContext_) CommitIn(floatingContext_, "blur");
    if (!focus) return S_OK;
    Json request = Json::object();
    request.set("op", "focus");
    request.set("app", Utf8(app_));
    Json response;
    host_.Request(request, response, 300);
    return S_OK;
}

STDMETHODIMP TextService::OnSetFocus(BOOL) { return S_OK; }

/// Commits what is being typed in `context` (an asynchronous edit session: focus is moving).
void TextService::CommitIn(ITfContext *context, const char *op) {
    std::string name = op;
    context->AddRef();
    HRESULT hr = Edit(context, false, [this, context, name](TfEditCookie cookie) {
        Json request = Json::object();
        request.set("op", name);
        bool masked = false;
        request.set("context", Snapshot(cookie, context, masked));
        bool handled = false;
        if (!Exchange(cookie, context, request, handled)) EndComposition(cookie);
        // Whatever the host did, nothing stays composed in a field that lost the focus.
        if (composition_) EndComposition(cookie);
        if (floatingContext_ == context) ClearFloating();
        context->Release();
        return S_OK;
    });
    if (FAILED(hr)) context->Release();
}

ITfContext *TextService::FocusedContext() {
    if (!threadMgr_) return nullptr;
    ITfDocumentMgr *document = nullptr;
    if (FAILED(threadMgr_->GetFocus(&document)) || !document) return nullptr;
    ITfContext *context = nullptr;
    document->GetTop(&context);
    document->Release();
    return context;
}

// MARK: Keys

/// Whether the key may go to the host at all. Modifiers do (their taps switch and pause); the
/// host decides the rest (`HostTakes`).
bool TextService::Takes(WPARAM vk, bool down) const {
    if (!threadMgr_) return false;
    if (vk == VK_CAPITAL || vk == VK_NUMLOCK || vk == VK_SCROLL || vk == VK_PROCESSKEY || vk == VK_PACKET) return false;
    // A key going up matters only for a modifier's tap.
    if (!down) return IsModifier(vk);
    return true;
}

/// Whether this text service keeps the key from the app, as the host answers (`test`). TSF holds
/// it to the answer: a key kept goes nowhere else, and one not kept never reaches OnKeyDown. So it
/// is asked once per key: OnTestKeyDown may come more than once for one key (a peek, then the real
/// thing) and OnKeyDown follows it; they all get the first answer.
bool TextService::HostTakes(WPARAM wParam, LPARAM lParam, bool up) {
    if (asked_.Is(wParam, lParam)) return asked_.taken;
    Json request = Json::object();
    request.set("op", "test");
    request.set("key", KeyJson(wParam, lParam));
    if (up) request.set("up", true);
    Json response;
    bool answered = host_.Request(request, response, 500);
    bool taken = answered && response["reply"]["handled"].asBool();
    if (Verbose() && !answered) Log("test: no answer from the host");
    asked_ = {true, wParam, lParam, GetTickCount(), taken};
    return taken;
}

/// A modifier went down: the host hears of it (a tap starts; Ctrl puts a held word in), and the
/// app gets it as well. Once per press: neither a second test nor the key repeating counts.
void TextService::SeeModifier(ITfContext *context, WPARAM wParam, LPARAM lParam) {
    if (!context || seen_.Is(wParam, lParam) || (lParam & (1 << 30))) return;
    seen_ = {true, wParam, lParam, GetTickCount(), true};
    Json key = KeyJson(wParam, lParam);
    context->AddRef();
    HRESULT hr = Edit(context, false, [this, context, key](TfEditCookie cookie) {
        bool masked = false;
        Json request = Json::object();
        request.set("op", "key");
        request.set("key", key);
        request.set("context", Snapshot(cookie, context, masked));
        bool handled = false;
        Exchange(cookie, context, request, handled);
        context->Release();
        return S_OK;
    });
    if (FAILED(hr)) context->Release();
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    *eaten = FALSE;
    if (!Takes(wParam, true) || replayed_.Is(wParam, 0)) return S_OK;
    if (IsModifier(wParam)) {
        SeeModifier(context, wParam, lParam);
        return S_OK;
    }
    *eaten = HostTakes(wParam, lParam, false) ? TRUE : FALSE;
    if (Verbose()) Log("test down: %s, composing %d", *eaten ? "kept" : "passed", composition_ ? 1 : 0);
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    *eaten = FALSE;
    if (!Takes(wParam, true)) return S_OK;
    if (replayed_.Is(wParam, 0)) {
        replayed_.valid = false; // the app's now
        return S_OK;
    }
    if (IsModifier(wParam)) {
        SeeModifier(context, wParam, lParam); // an app that didn't test the key first
        return S_OK;
    }
    bool taken = HostTakes(wParam, lParam, false);
    asked_.valid = false; // the key is done with: the next press asks again
    if (!taken) return S_OK;
    HandleKey(context, wParam, lParam, "key", eaten);
    // Kept, so it can't reach the app any more unless sent again; its up is kept as well.
    *eaten = TRUE;
    keptDown_[wParam & 0xFF] = !replayed_.Is(wParam, 0);
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext *, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    if (keptDown_[wParam & 0xFF]) {
        *eaten = TRUE;
        return S_OK;
    }
    *eaten = Takes(wParam, false) && HostTakes(wParam, lParam, true) ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
    *eaten = FALSE;
    if (keptDown_[wParam & 0xFF]) {
        keptDown_[wParam & 0xFF] = false;
        *eaten = TRUE;
        if (Verbose()) Log("up kept, composing %d", composition_ ? 1 : 0);
        return S_OK;
    }
    if (!Takes(wParam, false)) return S_OK;
    bool taken = HostTakes(wParam, lParam, true);
    asked_.valid = false;
    if (!taken) return S_OK;
    HandleKey(context, wParam, lParam, "keyUp", eaten);
    *eaten = TRUE;
    return S_OK;
}

/// A kept key the session passed on and the host couldn't type (Return, Tab, a shortcut ending a
/// word): sent again, after the word went in, and let through when it comes back.
void TextService::Replay(WPARAM wParam, LPARAM lParam) {
    INPUT input = {};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = static_cast<WORD>(wParam);
    input.ki.wScan = static_cast<WORD>((lParam >> 16) & 0xFF);
    input.ki.dwFlags = ((lParam >> 24) & 1) ? KEYEVENTF_EXTENDEDKEY : 0;
    // The key comes back with a repeat count of 1 and no previous state: match it by key only.
    replayed_ = {true, wParam, 0, GetTickCount(), true};
    SendInput(1, &input, sizeof input);
}

Json TextService::KeyJson(WPARAM wParam, LPARAM lParam) const {
    Json key = Json::object();
    key.set("vk", static_cast<int>(wParam));
    int scan = static_cast<int>((lParam >> 16) & 0xFF);
    if (scan == 0) {
        // WPF hands TSF keys without their scan codes: the US keyboard's for the key.
        scan = static_cast<int>(MapVirtualKeyW(static_cast<UINT>(wParam), MAPVK_VK_TO_VSC) & 0xFF);
        if (Verbose()) Log("a key without its scan code");
    }
    key.set("scan", scan);
    key.set("extended", ((lParam >> 24) & 1) != 0);
    key.set("shift", GetKeyState(VK_SHIFT) < 0);
    key.set("ctrl", GetKeyState(VK_CONTROL) < 0);
    key.set("alt", GetKeyState(VK_MENU) < 0);
    key.set("win", GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0);
    key.set("capsLock", (GetKeyState(VK_CAPITAL) & 1) != 0);
    return key;
}

/// A kept key (`HostTakes`), in a synchronous edit session. A password field's keys go in as typed
/// (the host sees `masked` and types them), as when paused (MaskedField on macOS).
void TextService::HandleKey(ITfContext *context, WPARAM wParam, LPARAM lParam, const char *op, BOOL *eaten) {
    Json key = KeyJson(wParam, lParam);
    std::string name = op;
    // The key's exchange with the host, in an edit session; whether the app should get it after all.
    auto exchange = [this, context, key, name](TfEditCookie cookie, bool &handled, bool &replay) {
        bool masked = false;
        Json request = Json::object();
        request.set("op", name);
        request.set("key", key);
        request.set("claimed", true);
        request.set("context", Snapshot(cookie, context, masked));
        request.set("rects", Rects(cookie, context));
        bool sent = Exchange(cookie, context, request, handled, &replay);
        // Nothing reached the host: the app gets the key after all.
        if (!sent) replay = name == "key";
        return sent;
    };
    bool handled = false;
    bool replay = false;
    HRESULT hr = Edit(context, true, [&](TfEditCookie cookie) {
        exchange(cookie, handled, replay);
        return S_OK;
    });
    if (hr == kNotNow) {
        // The app is busy with its document (Chrome, as a field comes and goes): the key waits its
        // turn. Sent to the app as typed instead, it went in before the word being typed, or not
        // at all (#gksrmf came out ksrmf in Lexical).
        context->AddRef();
        HRESULT queued = Edit(context, false, [this, context, exchange, wParam, lParam, name](TfEditCookie cookie) {
            bool handledLater = false, replayLater = false;
            exchange(cookie, handledLater, replayLater);
            if (replayLater) Replay(wParam, lParam);
            if (Verbose()) {
                Log("%s, waited for the app: %s%s, composing %d", name.c_str(), handledLater ? "handled" : "passed",
                    replayLater ? ", sent again" : "", composition_ ? 1 : 0);
            }
            context->Release();
            return S_OK;
        });
        if (SUCCEEDED(queued)) {
            *eaten = TRUE;
            return;
        }
        context->Release();
        hr = queued;
    }
    if (FAILED(hr)) {
        Log("no edit session for a key (0x%08lx)", static_cast<unsigned long>(hr));
        replay = name == "key";
    }
    if (replay) Replay(wParam, lParam);
    if (Verbose()) {
        Log("%s: %s%s, composing %d", name.c_str(), handled ? "handled" : "passed", replay ? ", sent again" : "",
            composition_ ? 1 : 0);
    }
    *eaten = handled || replay ? TRUE : FALSE;
}

bool TextService::Exchange(TfEditCookie cookie, ITfContext *context, Json request, bool &handled, bool *replay) {
    Json response;
    if (!host_.Request(request, response)) return false;
    const Json &reply = response["reply"];
    if (Verbose()) LogExchange(request, reply, Floats(context));
    handled = reply["handled"].asBool();
    if (replay) *replay = reply["replay"].asBool();
    ApplyOps(cookie, context, reply["ops"], reply["converting"].asBool());
    // How Try Typing's word was decided: for the settings window, which is in this process (the host
    // only says so to the text service in its own exe), handed over without waiting on anything.
    const Json &trace = response["ui"]["trace"];
    if (trace.isObject()) {
        HWND settings = FindWindowW(kSettingsWindowClass, nullptr);
        DWORD owner = 0;
        if (settings) GetWindowThreadProcessId(settings, &owner);
        if (owner == GetCurrentProcessId()) {
            std::string text = trace.dump();
            // The process heap: the settings window frees it, from another module.
            char *copy = static_cast<char *>(HeapAlloc(GetProcessHeap(), 0, text.size() + 1));
            if (copy) {
                memcpy(copy, text.c_str(), text.size() + 1);
                if (!PostMessageW(settings, RegisterWindowMessageW(kTraceMessage), 0, reinterpret_cast<LPARAM>(copy))) {
                    HeapFree(GetProcessHeap(), 0, copy);
                }
            }
        }
    }
    // Where the word and the caret are now: the host places its windows there, and draws a word
    // kept here (`floating_`) at the caret.
    bool preview = !floating_.empty() && floatingContext_ == context;
    if (response["ui"].isObject() || preview || previewShown_) {
        Json place = Json::object();
        place.set("op", "place");
        place.set("rects", Rects(cookie, context));
        if (preview) place.set("preview", Utf8(floating_));
        previewShown_ = preview;
        Json ignored;
        host_.Request(place, ignored, 200);
    }
    return true;
}

HRESULT TextService::Edit(ITfContext *context, bool sync, std::function<HRESULT(TfEditCookie)> body) {
    if (!context) return E_INVALIDARG;
    EditSession *session = new (std::nothrow) EditSession(std::move(body));
    if (!session) return E_OUTOFMEMORY;
    HRESULT result = E_FAIL;
    DWORD flags = TF_ES_READWRITE | (sync ? TF_ES_SYNC : TF_ES_ASYNCDONTCARE);
    HRESULT hr = context->RequestEditSession(clientId_, session, flags, &result);
    session->Release();
    return FAILED(hr) ? hr : result;
}

void TextService::FetchPending() {
    ITfContext *context = FocusedContext();
    if (!context) return;
    HRESULT hr = Edit(context, false, [this, context](TfEditCookie cookie) {
        Json request = Json::object();
        request.set("op", "pending");
        bool masked = false;
        request.set("context", Snapshot(cookie, context, masked));
        bool handled = false;
        Exchange(cookie, context, request, handled);
        context->Release();
        return S_OK;
    });
    if (FAILED(hr)) context->Release();
}

// MARK: The field

Json TextService::Snapshot(TfEditCookie cookie, ITfContext *context, bool &masked) {
    masked = false;
    Json out = Json::object();
    Json selectionJson = Json::array();
    selectionJson.push(-1);
    selectionJson.push(0);
    out.set("selection", selectionJson);
    out.set("text", "");
    out.set("start", 0);

    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || fetched == 0) return out;
    ITfRange *selected = selection.range;

    // A password field says so through its input scope.
    ITfReadOnlyProperty *scopes = nullptr;
    if (SUCCEEDED(context->GetAppProperty(kGuidPropInputScope, &scopes)) && scopes) {
        VARIANT value;
        VariantInit(&value);
        if (SUCCEEDED(scopes->GetValue(cookie, selected, &value)) && value.vt == VT_UNKNOWN && value.punkVal) {
            ITfInputScope *scope = nullptr;
            if (SUCCEEDED(value.punkVal->QueryInterface(kIID_ITfInputScope, reinterpret_cast<void **>(&scope)))) {
                InputScope *list = nullptr;
                UINT count = 0;
                if (SUCCEEDED(scope->GetInputScopes(&list, &count)) && list) {
                    for (UINT k = 0; k < count; k++) {
                        if (list[k] == IS_PASSWORD) masked = true;
                    }
                    CoTaskMemFree(list);
                }
                scope->Release();
            }
        }
        VariantClear(&value);
        scopes->Release();
    }
    out.set("masked", masked);

    ITfRangeACP *selectedACP = nullptr;
    LONG selStart = 0, selLength = 0;
    if (FAILED(selected->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&selectedACP))) ||
        FAILED(selectedACP->GetExtent(&selStart, &selLength))) {
        // A field without character positions: the session works without them.
        SafeRelease(selectedACP);
        selected->Release();
        return out;
    }
    selectedACP->Release();
    Json sel = Json::array();
    sel.push(static_cast<int>(selStart));
    sel.push(static_cast<int>(selLength));
    out.set("selection", sel);

    // The composition, and the text from 256 units before it (or the caret) to its end.
    ITfRange *anchor = nullptr;
    LONG compStart = 0, compLength = 0;
    bool composing = false;
    if (composition_ && compositionContext_ == context) {
        ITfRange *range = nullptr;
        if (SUCCEEDED(composition_->GetRange(&range)) && range) {
            ITfRangeACP *acp = nullptr;
            if (SUCCEEDED(range->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp)))) {
                if (SUCCEEDED(acp->GetExtent(&compStart, &compLength)) && compLength > 0) composing = true;
                acp->Release();
            }
            // A copy to move about: the composition's own range must stay where it is.
            if (composing) range->Clone(&anchor);
            range->Release();
        }
    }
    if (composing) {
        Json marked = Json::array();
        marked.push(static_cast<int>(compStart));
        marked.push(static_cast<int>(compLength));
        out.set("marked", marked);
    }
    if (!anchor) selected->Clone(&anchor);
    selected->Release();
    if (!anchor) return out;

    LONG moved = 0;
    anchor->ShiftStart(cookie, -kLookBehind, &moved, nullptr);
    LONG start = (composing ? compStart : selStart) + moved;
    // The selection may run past the composition: read to whichever ends later.
    LONG end = composing ? std::max(compStart + compLength, selStart + selLength) : selStart + selLength;
    LONG want = end - start;
    std::wstring text;
    if (want > 0) {
        ITfRangeACP *acp = nullptr;
        if (SUCCEEDED(anchor->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp)))) {
            acp->SetExtent(start, want);
            acp->Release();
        }
        std::vector<wchar_t> buffer(static_cast<size_t>(want) + 1);
        ULONG got = 0;
        if (SUCCEEDED(anchor->GetText(cookie, 0, buffer.data(), static_cast<ULONG>(want), &got))) {
            text.assign(buffer.data(), got);
        } else {
            out.set("unreadable", true);
        }
    }
    anchor->Release();
    // Text with embedded objects reads shorter than its positions: then the positions don't line up.
    if (static_cast<LONG>(text.size()) != want) out.set("unreadable", true);
    if (!floating_.empty() && floatingContext_ == context && selStart >= start) {
        // The word kept here, as if composed at the caret.
        text = text.substr(0, std::min(text.size(), static_cast<size_t>(selStart - start))) + floating_;
        LONG length = static_cast<LONG>(floating_.size());
        Json marked = Json::array();
        marked.push(static_cast<int>(selStart));
        marked.push(static_cast<int>(length));
        out.set("marked", marked);
        Json caret = Json::array();
        caret.push(static_cast<int>(selStart + length));
        caret.push(0);
        out.set("selection", caret);
    }
    out.set("text", Utf8(text));
    out.set("start", static_cast<int>(start));
    return out;
}

/// The composition's rectangle on screen, and the caret's.
Json TextService::Rects(TfEditCookie cookie, ITfContext *context) {
    Json out = Json::object();
    ITfContextView *view = nullptr;
    if (FAILED(context->GetActiveView(&view)) || !view) return out;
    HWND window = nullptr;
    view->GetWnd(&window);
    if (composition_ && compositionContext_ == context) {
        ITfRange *range = nullptr;
        if (SUCCEEDED(composition_->GetRange(&range)) && range) {
            RECT rect = {};
            BOOL clipped = FALSE;
            if (SUCCEEDED(view->GetTextExt(cookie, range, &rect, &clipped)) && rect.bottom > rect.top) {
                out.set("word", RectJson(Physical(window, rect)));
            }
            range->Release();
        }
    }
    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (SUCCEEDED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) && fetched) {
        ITfRange *caret = nullptr;
        if (SUCCEEDED(selection.range->Clone(&caret)) && caret) {
            caret->Collapse(cookie, TF_ANCHOR_END);
            RECT rect = {};
            BOOL clipped = FALSE;
            if (SUCCEEDED(view->GetTextExt(cookie, caret, &rect, &clipped)) && rect.bottom > rect.top) {
                out.set("caret", RectJson(Physical(window, rect)));
            }
            caret->Release();
        }
        selection.range->Release();
    }
    view->Release();
    return out;
}

ITfRange *TextService::RangeAt(TfEditCookie cookie, ITfContext *context, LONG start, LONG length) {
    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || !fetched) return nullptr;
    ITfRange *range = nullptr;
    selection.range->Clone(&range);
    selection.range->Release();
    if (!range) return nullptr;
    ITfRangeACP *acp = nullptr;
    if (FAILED(range->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp))) ||
        FAILED(acp->SetExtent(start, length))) {
        SafeRelease(acp);
        range->Release();
        return nullptr;
    }
    acp->Release();
    return range;
}

void TextService::MoveCaretToEnd(TfEditCookie cookie, ITfContext *context, ITfRange *range) {
    ITfRange *caret = nullptr;
    if (FAILED(range->Clone(&caret)) || !caret) return;
    caret->Collapse(cookie, TF_ANCHOR_END);
    TF_SELECTION selection = {};
    selection.range = caret;
    selection.style.ase = TF_AE_NONE;
    selection.style.fInterimChar = FALSE;
    context->SetSelection(cookie, 1, &selection);
    caret->Release();
}

void TextService::EndComposition(TfEditCookie cookie) {
    if (!composition_) return;
    ITfRange *range = nullptr;
    if (compositionContext_ && SUCCEEDED(composition_->GetRange(&range)) && range) {
        ClearAttributes(cookie, compositionContext_, range);
        range->Release();
    }
    composition_->EndComposition(cookie);
    SafeRelease(composition_);
    SafeRelease(compositionContext_);
}

/// The edits, in order: each replaces its range (else the composition, else the selection);
/// `mark` leaves its text composed, `insert` puts it in for good.
void TextService::ApplyOps(TfEditCookie cookie, ITfContext *context, const Json &ops, bool converting) {
    bool floats = Floats(context);
    for (const Json &op : ops.items()) {
        if (floats) {
            ApplyFloating(cookie, context, op);
            continue;
        }
        bool mark = op["kind"].asString() == "mark";
        std::wstring text = Wide(op["text"].asString());
        const Json &replace = op["replace"];
        // A composition left in another field is finished there first.
        if (composition_ && compositionContext_ != context) {
            if (Verbose()) Log("composition in another context: ended");
            EndComposition(cookie);
        }

        ITfRange *target = nullptr;
        if (replace.isArray() && replace.size() == 2) {
            target = RangeAt(cookie, context, replace[0].asInt(), replace[1].asInt());
        }
        if (!target && composition_) composition_->GetRange(&target);
        if (!target) {
            TF_SELECTION selection = {};
            ULONG fetched = 0;
            if (SUCCEEDED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) && fetched) {
                target = selection.range;
            }
        }
        if (!target) continue;

        if (mark) {
            if (!composition_) {
                ITfContextComposition *compose = nullptr;
                if (SUCCEEDED(context->QueryInterface(IID_ITfContextComposition, reinterpret_cast<void **>(&compose)))) {
                    HRESULT started = compose->StartComposition(cookie, target, static_cast<ITfCompositionSink *>(this),
                                                                &composition_);
                    if (SUCCEEDED(started) && composition_) {
                        compositionContext_ = context;
                        compositionContext_->AddRef();
                        compositionStartedAt_ = GetTickCount();
                        if (Verbose()) Log("composition started");
                    } else {
                        Log("no composition (0x%08lx)", static_cast<unsigned long>(started));
                    }
                    compose->Release();
                }
            } else {
                composition_->ShiftStart(cookie, target);
                composition_->ShiftEnd(cookie, target);
            }
            if (composition_) {
                ITfRange *range = nullptr;
                composition_->GetRange(&range);
                if (range) {
                    range->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
                    if (text.empty()) {
                        range->Release();
                        EndComposition(cookie);
                    } else {
                        ApplyAttributes(cookie, context, range, converting, op["clause"]);
                        MoveCaretToEnd(cookie, context, range);
                        range->Release();
                    }
                }
            }
        } else if (composition_) {
            composition_->ShiftStart(cookie, target);
            composition_->ShiftEnd(cookie, target);
            ITfRange *range = nullptr;
            composition_->GetRange(&range);
            if (range) {
                range->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
                ClearAttributes(cookie, context, range);
                MoveCaretToEnd(cookie, context, range);
                range->Release();
            }
            EndComposition(cookie);
        } else if (replace.isArray()) {
            target->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
            MoveCaretToEnd(cookie, context, target);
        } else {
            ITfInsertAtSelection *insert = nullptr;
            if (SUCCEEDED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void **>(&insert)))) {
                ITfRange *inserted = nullptr;
                if (SUCCEEDED(insert->InsertTextAtSelection(cookie, 0, text.c_str(), static_cast<LONG>(text.size()),
                                                            &inserted)) && inserted) {
                    MoveCaretToEnd(cookie, context, inserted);
                    inserted->Release();
                }
                insert->Release();
            }
        }
        target->Release();
    }
}

// MARK: The word kept here

/// Whether words are kept here rather than composed in the field: in a classic app's context
/// (CUAS marks it transitory), or an app seen ending compositions at once.
bool TextService::Floats(ITfContext *context) {
    if (appEndsCompositions_) return true;
    TF_STATUS status = {};
    return SUCCEEDED(context->GetStatus(&status)) && (status.dwStaticFlags & TF_SS_TRANSITORY);
}

void TextService::ClearFloating() {
    floating_.clear();
    SafeRelease(floatingContext_);
}

void TextService::InsertAtCaret(TfEditCookie cookie, ITfContext *context, const std::wstring &text) {
    if (text.empty()) return;
    ITfInsertAtSelection *insert = nullptr;
    if (FAILED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void **>(&insert)))) return;
    ITfRange *inserted = nullptr;
    if (SUCCEEDED(insert->InsertTextAtSelection(cookie, 0, text.c_str(), static_cast<LONG>(text.size()), &inserted)) &&
        inserted) {
        MoveCaretToEnd(cookie, context, inserted);
        inserted->Release();
    }
    insert->Release();
}

/// One edit where words are kept here: the field holds what went in, `floating_` the word at the
/// caret. Positions are the session's, which sees the word as composed there (`Snapshot`).
void TextService::ApplyFloating(TfEditCookie cookie, ITfContext *context, const Json &op) {
    bool mark = op["kind"].asString() == "mark";
    std::wstring text = Wide(op["text"].asString());
    if (floatingContext_ != context) {
        ClearFloating();
        floatingContext_ = context;
        floatingContext_->AddRef();
    }
    LONG caret = 0, selected = 0;
    TF_SELECTION selection = {};
    ULONG fetched = 0;
    if (SUCCEEDED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) && fetched) {
        ITfRangeACP *acp = nullptr;
        if (SUCCEEDED(selection.range->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void **>(&acp)))) {
            acp->GetExtent(&caret, &selected);
            acp->Release();
        }
        selection.range->Release();
    }
    LONG kept = static_cast<LONG>(floating_.size());
    if (kept) selected = 0;
    LONG at = caret, length = kept ? kept : selected;
    const Json &replace = op["replace"];
    if (replace.isArray() && replace.size() == 2) {
        at = replace[0].asInt();
        length = replace[1].asInt();
    }
    // The part in the field (the word just committed, switched again; a selection typed over).
    LONG fieldEnd = caret + selected;
    if (at < fieldEnd) {
        LONG inField = std::min(at + length, fieldEnd) - at;
        ITfRange *range = RangeAt(cookie, context, at, inField);
        bool whollyInField = at + length <= fieldEnd && !kept;
        if (range) {
            // An edit of what went in already, outside the word: made in the field.
            range->SetText(cookie, 0, whollyInField && !mark ? text.c_str() : L"",
                           whollyInField && !mark ? static_cast<LONG>(text.size()) : 0);
            MoveCaretToEnd(cookie, context, range);
            range->Release();
        }
        if (whollyInField && !mark) return;
        length -= inField;
        at = std::min(at + inField, caret);
        caret = at;
    }
    // The part in the word kept here.
    LONG offset = std::max(0L, std::min(at - caret, kept));
    LONG covered = std::max(0L, std::min(length, kept - offset));
    std::wstring before = floating_.substr(0, static_cast<size_t>(offset));
    std::wstring after = floating_.substr(static_cast<size_t>(offset + covered));
    if (mark) {
        InsertAtCaret(cookie, context, before); // what the new word leaves before it went in
        floating_ = text;
    } else {
        floating_.clear();
        InsertAtCaret(cookie, context, before + text + after);
    }
    if (floating_.empty()) ClearFloating();
}

/// The word being typed underlined; a phrase being converted as its reading (thin), with the clause
/// the candidates are for (`clause`, within the text) thick, as macOS draws its clauses.
void TextService::ApplyAttributes(TfEditCookie cookie, ITfContext *context, ITfRange *range, bool converting,
                                  const Json &clause) {
    ITfProperty *property = nullptr;
    if (FAILED(context->GetProperty(kGuidPropAttribute, &property)) || !property) return;
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    bool clauses = clause.isArray() && clause.size() == 2 && clause[1].asInt() > 0;
    value.lVal = static_cast<LONG>(clauses ? attrConverted_ : converting ? attrTarget_ : attrInput_);
    property->SetValue(cookie, range, &value);
    if (clauses) {
        ITfRange *selected = nullptr;
        if (SUCCEEDED(range->Clone(&selected)) && selected) {
            LONG moved = 0;
            selected->Collapse(cookie, TF_ANCHOR_START);
            selected->ShiftEnd(cookie, clause[0].asInt() + clause[1].asInt(), &moved, nullptr);
            selected->ShiftStart(cookie, clause[0].asInt(), &moved, nullptr);
            value.lVal = static_cast<LONG>(attrTarget_);
            property->SetValue(cookie, selected, &value);
            selected->Release();
        }
    }
    property->Release();
}

void TextService::ClearAttributes(TfEditCookie cookie, ITfContext *context, ITfRange *range) {
    ITfProperty *property = nullptr;
    if (SUCCEEDED(context->GetProperty(kGuidPropAttribute, &property)) && property) {
        property->Clear(cookie, range);
        property->Release();
    }
}

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie cookie, ITfComposition *composition) {
    // The app ended it (a click elsewhere): the text stays as it is, and the session starts afresh.
    if (composition_ && composition == composition_) {
        Log("the app ended the composition in %s", Utf8(app_).c_str());
        // As soon as it started: an app that won't keep one, whatever its context said.
        if (GetTickCount() - compositionStartedAt_ < 100 && !appEndsCompositions_) {
            appEndsCompositions_ = true;
            Log("%s ends compositions at once: words are drawn at the caret", Utf8(app_).c_str());
        }
        ITfRange *range = nullptr;
        if (compositionContext_ && SUCCEEDED(composition_->GetRange(&range)) && range) {
            ClearAttributes(cookie, compositionContext_, range);
            range->Release();
        }
        SafeRelease(composition_);
        SafeRelease(compositionContext_);
        Json request = Json::object();
        request.set("op", "terminated");
        Json response;
        host_.Request(request, response, 200);
    }
    return S_OK;
}

// MARK: Display attributes

void TextService::RegisterAttributes() {
    ITfCategoryMgr *categories = nullptr;
    if (FAILED(CoCreateInstance(kClsidTfCategoryMgr, nullptr, CLSCTX_INPROC_SERVER, kIID_ITfCategoryMgr,
                                reinterpret_cast<void **>(&categories)))) return;
    categories->RegisterGUID(kGuidAttrInput, &attrInput_);
    categories->RegisterGUID(kGuidAttrConverted, &attrConverted_);
    categories->RegisterGUID(kGuidAttrTarget, &attrTarget_);
    categories->Release();
}

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo **enumerator) {
    if (!enumerator) return E_INVALIDARG;
    *enumerator = new (std::nothrow) DisplayAttributeEnum();
    return *enumerator ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo **info) {
    if (!info) return E_INVALIDARG;
    *info = DisplayAttributeInfo::For(guid);
    return *info ? S_OK : E_INVALIDARG;
}

// MARK: Menu

Json TextService::Menu() {
    Json request = Json::object();
    request.set("op", "menu");
    Json response;
    if (!host_.Request(request, response, 1000)) return Json::array();
    return response["reply"]["menu"];
}

void TextService::MenuSelect(const std::string &item) {
    Json request = Json::object();
    request.set("op", "menuSelect");
    request.set("item", item);
    Json response;
    host_.Request(request, response, 1000);
}

// MARK: The message window

bool TextService::CreateMessageWindow() {
    static ATOM atom = 0;
    if (!atom) {
        WNDCLASSEXW cls = {sizeof cls};
        cls.lpfnWndProc = WindowProc;
        cls.hInstance = g_instance;
        cls.lpszClassName = L"ArasoTipMessages";
        atom = RegisterClassExW(&cls);
        if (!atom && GetLastError() == ERROR_CLASS_ALREADY_EXISTS) atom = 1;
    }
    window_ = CreateWindowExW(0, L"ArasoTipMessages", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, g_instance, nullptr);
    if (!window_) return false;
    SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    // The host may run at a lower integrity than an elevated app: let its message through.
    ChangeWindowMessageFilterEx(window_, PendingMessage(), MSGFLT_ALLOW, nullptr);
    return true;
}

void TextService::DestroyMessageWindow() {
    if (window_) {
        SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
        ::DestroyWindow(window_);
    }
    window_ = nullptr;
}

LRESULT CALLBACK TextService::WindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == PendingMessage()) {
        auto *service = reinterpret_cast<TextService *>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (service) service->FetchPending();
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace araso
