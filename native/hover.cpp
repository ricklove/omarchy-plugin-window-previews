#define WLR_USE_UNSTABLE
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Group.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <json-c/json.h>
#include <chrono>
#include <sstream>
#include <stdexcept>
#include "TabGeometry.hpp"

namespace {
// json-c is installed on this desktop. These objects are only
// created when publishing a completed dwell or answering diagnostics.
struct Json {
    std::unique_ptr<json_object, decltype(&json_object_put)> value{json_object_new_object(), json_object_put};
    void add(const char* key, const std::string& v) { json_object_object_add(value.get(), key, json_object_new_string_len(v.data(), int(v.size()))); }
    void add(const char* key, const char* v) { add(key, std::string(v)); }
    void add(const char* key, bool v) { json_object_object_add(value.get(), key, json_object_new_boolean(v)); }
    void add(const char* key, double v) { json_object_object_add(value.get(), key, json_object_new_double(v)); }
    void add(const char* key, uint64_t v) { json_object_object_add(value.get(), key, json_object_new_uint64(v)); }
    void add(const char* key, int v) { json_object_object_add(value.get(), key, json_object_new_int(v)); }
    void add(const char* key, const Json& v) { json_object_object_add(value.get(), key, json_object_get(v.value.get())); }
    bool contains(const char* key) const { json_object* out; return json_object_object_get_ex(value.get(), key, &out); }
    std::string dump() const { return json_object_to_json_string_ext(value.get(), JSON_C_TO_STRING_PLAIN); }
};
} // namespace
using Clock = std::chrono::steady_clock;
using namespace Desktop::View;

namespace {
constexpr int HOVER_DELAY_MS = 250;
struct Hit {
    PHLWINDOWREF owner, target;
    OmaSpaces::Rect tab;
    bool same(const Hit& other) const {
        return owner == other.owner && target == other.target && tab == other.tab;
    }
};

class HoverDetector {
  public:
    explicit HoverDetector(HANDLE handle) : handle(handle) {
        // All config handles and listeners are allocated once, never per motion.
        listeners.push_back(Event::bus()->m_events.input.mouse.move.listen(
            [this](const Vector2D& pos, Event::SCallbackInfo&) { motion(pos); }));
        listeners.push_back(Event::bus()->m_events.input.mouse.button.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.input.mouse.axis.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.window.close.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.workspace.active.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.workspace.specialActive.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.monitor.layoutChanged.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.config.preReload.listen([this] { clear(); }));
        listeners.push_back(g_pSessionLockManager->m_events.lock.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.layer.opened.listen([this](PHLLS layer) {
            if (layer->m_namespace != "omarchy-omaspaces-tab-preview") clear();
        }));
        // Only while dwelling/showing: catch moved/resized/reordered groups even
        // when the pointer is stationary. No render work is requested here.
        listeners.push_back(Event::bus()->m_events.render.pre.listen([this](PHLMONITOR monitor) {
            auto owner = current.owner.lock();
            if (owner && owner->m_monitor == monitor) update(Pointer::mgr()->position());
        }));
        command = HyprlandAPI::registerHyprCtlCommand(handle, SHyprCtlCommand{
            .name = "omaspaceshover", .exact = false,
            .fn = [this](eHyprCtlOutputFormat, std::string request) { return control(request); }});
        if (!command) throw std::runtime_error("omaspaces-hover: command registration failed");
        dwellTimer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop,
            [](void* data) { static_cast<HoverDetector*>(data)->publish(); return 0; }, this);
        if (!dwellTimer) {
            HyprlandAPI::unregisterHyprCtlCommand(handle, command);
            throw std::runtime_error("omaspaces-hover: timer allocation failed");
        }
    }
    ~HoverDetector() {
        listeners.clear();
        clear();
        if (dwellTimer) wl_event_source_remove(dwellTimer);
        if (command) HyprlandAPI::unregisterHyprCtlCommand(handle, command);
    }

  private:
    HANDLE handle;
    std::vector<CHyprSignalListener> listeners;
    SP<SHyprCtlCommand> command;
    wl_event_source* dwellTimer = nullptr;
    CConfigValue<Config::INTEGER> groupbarEnabled{"group:groupbar:enabled"};
    CConfigValue<Config::INTEGER> disableOnly{"group:groupbar:disable_when_only"};
    CConfigValue<Config::INTEGER> stacked{"group:groupbar:stacked"};
    CConfigValue<Config::INTEGER> innerGap{"group:groupbar:gaps_in"};
    CConfigValue<Config::INTEGER> outerGap{"group:groupbar:gaps_out"};
    CConfigValue<Config::INTEGER> keepUpperGap{"group:groupbar:keep_upper_gap"};
    Hit current;
    bool enabled = true, published = false, profiling = false;
    uint64_t motions = 0, timedChecks = 0, totalNs = 0, maxNs = 0, messages = 0;

    static std::optional<CBox> groupBarBox(PHLWINDOW owner) {
        auto* deco = owner->getDecorationByType(DECORATION_GROUPBAR);
        if (!deco) return {};
        auto box = g_pDecorationPositioner->getWindowDecorationBox(deco);
        if (owner->m_workspace && !owner->m_pinned) box.translate(owner->m_workspace->m_renderOffset->value());
        box.translate(owner->m_floatingOffset).round();
        return box;
    }
    Hit detect(const Vector2D& pos) const {
        if (!enabled || !*groupbarEnabled || g_pInputManager->isLocked() ||
            g_pInputManager->isConstrained() || g_pInputManager->hasHeldButtons()) return {};
        // Most motion is nowhere near a tab. First test the handful of real
        // groupbar rectangles; only a possible hit pays for occlusion checks.
        bool overBar = false;
        for (const auto& weak : Desktop::View::groups()) {
            const auto group = weak.lock();
            if (!group || (*disableOnly && group->size() == 1)) continue;
            const auto owner = group->current();
            if (!owner || !owner->aliveAndVisible()) continue;
            const auto box = groupBarBox(owner);
            if (box && box->containsPoint(pos)) { overBar = true; break; }
        }
        if (!overBar) return {};
        const auto monitor = State::monitorState()->query().vec(pos).run();
        if (!monitor) return {};
        const auto picker = Desktop::viewState()->hitTest();
        Vector2D local;
        PHLLS layer;
        // Respect menus, layer popups, the overview and other desktop overlays.
        // Our own popup has an empty input region and cannot steal hover.
        if (picker.layerPopupSurfaceAt(pos, monitor, &local, &layer)) return {};
        for (int level : {3, 2})
            if (picker.layerSurfaceAt(pos, &monitor->m_layerSurfaceLayers[level], &local, &layer)) return {};
        const auto owner = picker.windowAt(pos, RESERVED_EXTENTS | INPUT_EXTENTS | ALLOW_FLOATING);
        if (!owner || !owner->m_group || !owner->aliveAndVisible() || owner->hasPopupAt(pos) ||
            Fullscreen::controller()->getFullscreenModes(owner).internal == Fullscreen::FSMODE_FULLSCREEN ||
            !owner->m_ruleApplicator->decorate().valueOrDefault()) return {};
        const auto count = owner->m_group->size();
        if (count == 0 || (*disableOnly && count == 1)) return {};
        const auto box = groupBarBox(owner);
        if (!box) return {};
        auto tab = OmaSpaces::tabAt({box->x, box->y, box->w, box->h}, int(count), bool(*stacked),
                                   double(*innerGap), double(*outerGap), bool(*keepUpperGap), pos.x, pos.y);
        if (!tab) return {};
        auto target = owner->m_group->fromIndex(tab->index);
        if (!target || !target->m_isMapped) return {};
        return {owner, target, tab->rect};
    }
    void motion(const Vector2D& pos) {
        ++motions;
        if (!profiling) { update(pos); return; }
        const auto start = Clock::now();
        update(pos);
        const uint64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - start).count();
        ++timedChecks;
        totalNs += ns;
        maxNs = std::max(maxNs, ns);
    }
    void update(const Vector2D& pos) {
        Hit next = detect(pos);
        if (current.same(next)) return; // Do not restart the dwell within a tab.
        clear();
        current = next;
        if (current.target) wl_event_source_timer_update(dwellTimer, HOVER_DELAY_MS);
    }
    void clear() {
        if (dwellTimer) wl_event_source_timer_update(dwellTimer, 0);
        current = {};
        if (published) send("{}");
        published = false;
    }
    static std::string address(PHLWINDOW w) {
        return w ? std::format("0x{:x}", reinterpret_cast<uintptr_t>(w.get())) : "";
    }
    Json payload(const Hit& hit) const {
        const auto owner = hit.owner.lock(), target = hit.target.lock();
        if (!owner || !target) return Json{};
        const auto monitor = owner->m_monitor.lock();
        if (!monitor) return Json{};
        const auto size = target->size(IGeometric::GEOMETRIC_CURRENT);
        Json result, tab, window;
        tab.add("x", hit.tab.x); tab.add("y", hit.tab.y); tab.add("w", hit.tab.w); tab.add("h", hit.tab.h);
        window.add("w", size.x); window.add("h", size.y);
        result.add("address", address(target)); result.add("monitor", monitor->m_name);
        result.add("tab", tab); result.add("window", window); result.add("title", target->m_title.substr(0, 512));
        return result;
    }
    void publish() {
        // The tab may have moved, disappeared, or become covered during dwell.
        const Hit latest = detect(Pointer::mgr()->position());
        if (!current.same(latest) || !latest.target) { update(Pointer::mgr()->position()); return; }
        auto data = payload(latest);
        if (!data.contains("address")) { clear(); return; }
        published = true;
        send(data.dump());
    }
    void send(const std::string& data) {
        ++messages;
        // Hyprland's existing nonblocking event socket; no process or socket
        // connection is created in the input handler.
        g_pEventManager->postEvent({"omaspaceshover", data});
    }
    std::string control(const std::string& request) {
        std::istringstream args(request);
        std::string commandName, action;
        args >> commandName >> action;
        if (action == "enable") { enabled = true; clear(); }
        else if (action == "disable") { enabled = false; clear(); }
        else if (action == "reset") clear();
        else if (action == "profile") { profiling = true; timedChecks = totalNs = maxNs = 0; }
        else if (action == "unprofile") profiling = false;
        else if (action == "probe") {
            double x, y;
            if (!(args >> x >> y) || !std::isfinite(x) || !std::isfinite(y)) return "error: expected probe x y";
            return payload(detect({x, y})).dump();
        } else if (!action.empty() && action != "status") return "error: unknown omaspaceshover action";
        Json result;
        result.add("enabled", enabled); result.add("pending", bool(current.target) && !published);
        result.add("published", published); result.add("address", address(current.target.lock()));
        result.add("delayMs", HOVER_DELAY_MS); result.add("motionEvents", motions); result.add("messages", messages);
        result.add("profiling", profiling); result.add("profileChecks", timedChecks);
        result.add("averageCheckUs", timedChecks ? double(totalNs) / timedChecks / 1000 : 0);
        result.add("maxCheckUs", double(maxNs) / 1000);
        return result.dump();
    }
};
std::unique_ptr<HoverDetector> detector;
}

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    if (std::string(__hyprland_api_get_hash()) != __hyprland_api_get_client_hash())
        throw std::runtime_error("omaspaces-hover: rebuild against the running Hyprland version");
    detector = std::make_unique<HoverDetector>(handle);
    return {"omaspaces-hover", "Event-driven group tab hover bridge for OmaSpaces", "Rick / OmaSpaces", "0.1.0"};
}
APICALL EXPORT void PLUGIN_EXIT() { detector.reset(); }
