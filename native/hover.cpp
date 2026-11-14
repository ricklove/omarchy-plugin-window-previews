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
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <json-c/json.h>
#include <chrono>
#include <sstream>
#include <array>
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
struct TabRecord {
    PHLWINDOWREF owner, target;
    uintptr_t group;
    OmaSpaces::Rect bar, tab;
    double width, height;
    bool front;
};
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
        listeners.push_back(Event::bus()->m_events.config.preReload.listen([this] { clear(); setNativeTextHidden(false); }));
        listeners.push_back(Event::bus()->m_events.config.props_refreshed.listen([this] {
            if (nativeTextHidden) {
                for (size_t i = 0; i < textColors.size(); ++i) {
                    auto* value = textColors[i]->ptr();
                    if (*value != 0) { originalTextColors[i] = *value; *value = 0; }
                }
            }
        }));
        listeners.push_back(g_pSessionLockManager->m_events.lock.listen([this] { clear(); }));
        listeners.push_back(Event::bus()->m_events.layer.opened.listen([this](PHLLS layer) {
            if (layer->m_namespace != "omarchy-omaspaces-tab-preview" &&
                layer->m_namespace != "omarchy-omaspaces-tab-snapshots") clear();
        }));
        // Only while dwelling/showing: catch moved/resized/reordered groups even
        // when the pointer is stationary. No render work is requested here.
        listeners.push_back(Event::bus()->m_events.render.pre.listen([this](PHLMONITOR monitor) {
            auto owner = current.owner.lock();
            if (owner && owner->m_monitor == monitor) update(Pointer::mgr()->position());
            syncTabs(false);
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
        setNativeTextHidden(false);
        g_pEventManager->postEvent({"omaspacestabs", "begin"});
        g_pEventManager->postEvent({"omaspacestabs", "end"});
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
    CConfigValue<Config::INTEGER> indicatorHeight{"group:groupbar:indicator_height"};
    CConfigValue<Config::INTEGER> textActive{"group:groupbar:text_color"};
    CConfigValue<Config::INTEGER> textInactive{"group:groupbar:text_color_inactive"};
    CConfigValue<Config::INTEGER> textLockedActive{"group:groupbar:text_color_locked_active"};
    CConfigValue<Config::INTEGER> textLockedInactive{"group:groupbar:text_color_locked_inactive"};
    std::array<CConfigValue<Config::INTEGER>*, 4> textColors{&textActive, &textInactive, &textLockedActive, &textLockedInactive};
    std::array<Config::INTEGER, 4> originalTextColors{};
    bool customLabelsRequested = false, nativeTextHidden = false;
    std::vector<CBox> labelBars;
    Hit current;
    bool snapshotsEnabled = false;
    bool tabsPaused = false;
    uint64_t tabsHash = 0;
    Clock::time_point tabsChecked{};
    std::vector<TabRecord> tabScratch;
    size_t visibleTabCount = 0;
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
    void setNativeTextHidden(bool hide) {
        if (hide == nativeTextHidden) return;
        for (size_t i = 0; i < textColors.size(); ++i) {
            auto* value = textColors[i]->ptr();
            if (hide) { originalTextColors[i] = *value; *value = 0; }
            else if (*value == 0) *value = originalTextColors[i];
        }
        nativeTextHidden = hide;
        g_pEventManager->postEvent({"omaspaceslabels", hide ? "custom" : "native"});
        // Title textures are rebuilt by the native groupbar on its next draw.
        for (const auto& weak : Desktop::View::groups()) {
            auto group = weak.lock();
            if (!group || !group->current()) continue;
            if (auto* deco = group->current()->getDecorationByType(DECORATION_GROUPBAR)) deco->damageEntire();
        }
    }
    void updateLabelVisibility() {
        bool ready = customLabelsRequested && !labelBars.empty() && !g_pInputManager->isLocked();
        for (const auto& box : labelBars) {
            if (!ready) break;
            bool found = false;
            for (const auto& layer : Desktop::layerState()->layers()) {
                if (layer->m_namespace != "omarchy-omaspaces-tab-snapshots" || !layer->aliveAndVisible() ||
                    layer->alpha().value() < 0.9f) continue;
                auto surface = layer->wlSurface() ? layer->wlSurface()->resource() : nullptr;
                if (!surface || !surface->m_current.texture) continue;
                auto position = layer->position(IGeometric::GEOMETRIC_CURRENT);
                auto size = layer->size(IGeometric::GEOMETRIC_CURRENT);
                if (std::abs(position.x - box.x) <= 2 && position.y <= box.y + 2 &&
                    position.y >= box.y - 50 && std::abs(size.x - box.w) <= 2 &&
                    position.y + size.y >= box.y + box.h - 2 && size.y <= box.h + 50) { found = true; break; }
            }
            if (!found) ready = false;
        }
        setNativeTextHidden(ready);
    }
    static void hashMix(uint64_t& hash, uint64_t value) { hash = (hash ^ value) * 1099511628211ULL; }
    static void hashRect(uint64_t& hash, const CBox& box) {
        for (double value : {box.x, box.y, box.w, box.h}) hashMix(hash, uint64_t(int64_t(std::round(value))));
    }
    bool exposed(PHLWINDOW owner, const OmaSpaces::Rect& rect) const {
        const auto mon = owner->m_monitor.lock();
        if (!mon || rect.w < 4 || rect.h < 4) return false;
        const auto picker = Desktop::viewState()->hitTest();
        // Hide an occluded tab rather than drawing over a window above it.
        for (const auto& point : std::array<Vector2D, 5>{{
                {rect.x + 2, rect.y + 2}, {rect.x + rect.w - 2, rect.y + 2},
                {rect.x + 2, rect.y + rect.h - 2}, {rect.x + rect.w - 2, rect.y + rect.h - 2},
                {rect.x + rect.w / 2, rect.y + rect.h / 2}}}) {
            Vector2D local;
            PHLLS layer;
            if (picker.layerPopupSurfaceAt(point, mon, &local, &layer)) return false;
            for (int level : {3, 2})
                if (picker.layerSurfaceAt(point, &mon->m_layerSurfaceLayers[level], &local, &layer)) return false;
            if (picker.windowAt(point, RESERVED_EXTENTS | INPUT_EXTENTS | ALLOW_FLOATING) != owner || owner->hasPopupAt(point)) return false;
        }
        return true;
    }
    void syncTabs(bool force) {
        if (!snapshotsEnabled) return;
        // The strip is an external surface, so hide it during native drags
        // instead of allowing an IPC-updated thumbnail to trail the window.
        if (g_layoutManager->dragController()->target()) {
            if (!tabsPaused) g_pEventManager->postEvent({"omaspacestabs", "paused"});
            tabsPaused = true;
            setNativeTextHidden(false);
            return;
        }
        if (tabsPaused) { tabsPaused = false; force = true; }
        auto now = Clock::now();
        if (!force && now - tabsChecked < std::chrono::milliseconds(100)) return;
        tabsChecked = now;
        updateLabelVisibility();
        uint64_t hash = 1469598103934665603ULL;
        hashMix(hash, uint64_t(*groupbarEnabled)); hashMix(hash, uint64_t(*stacked));
        hashMix(hash, uint64_t(*indicatorHeight));
        tabScratch.clear(); // Capacity is retained, not allocated each frame.
        if (*groupbarEnabled && !g_pInputManager->isLocked()) {
            for (const auto& weak : Desktop::View::groups()) {
                auto group = weak.lock();
                if (!group || (*disableOnly && group->size() == 1)) continue;
                auto owner = group->current();
                if (!owner || !owner->aliveAndVisible() || !owner->m_ruleApplicator->decorate().valueOrDefault() ||
                    Fullscreen::controller()->getFullscreenModes(owner).internal == Fullscreen::FSMODE_FULLSCREEN) continue;
                auto box = groupBarBox(owner);
                if (!box || box->w <= 0 || box->h <= 0) continue;
                const auto key = reinterpret_cast<uintptr_t>(group.get());
                hashMix(hash, key); hashRect(hash, *box);
                for (size_t i = 0; i < group->size() && tabScratch.size() < 128; ++i) {
                    auto target = group->fromIndex(i);
                    if (!target || !target->m_isMapped) continue;
                    auto rect = OmaSpaces::tabRect({box->x, box->y, box->w, box->h}, int(group->size()), int(i),
                        bool(*stacked), double(*innerGap), double(*outerGap), bool(*keepUpperGap));
                    auto size = target->size(IGeometric::GEOMETRIC_CURRENT);
                    tabScratch.push_back({owner, target, key, {box->x, box->y, box->w, box->h}, rect, size.x, size.y, target == owner});
                    hashMix(hash, reinterpret_cast<uintptr_t>(target.get()));
                    hashMix(hash, target == owner); hashRect(hash, {rect.x, rect.y, rect.w, rect.h});
                }
            }
        }
        // Position and z-order changes can occlude an otherwise unchanged bar.
        for (const auto& window : Desktop::windowState()->windows()) {
            if (!window->aliveAndVisible()) continue;
            hashMix(hash, reinterpret_cast<uintptr_t>(window.get()));
            hashRect(hash, window->getFullWindowBoundingBox());
        }
        for (const auto& layer : Desktop::layerState()->layers()) {
            if (!layer->aliveAndVisible() || layer->m_namespace == "omarchy-omaspaces-tab-snapshots") continue;
            hashMix(hash, reinterpret_cast<uintptr_t>(layer.get()));
            hashRect(hash, layer->m_geometry);
        }
        hashMix(hash, g_pInputManager->isLocked());
        if (!force && hash == tabsHash) return;
        tabsHash = hash;
        visibleTabCount = 0;
        labelBars.clear();
        std::vector<uintptr_t> labelGroups;
        // Each packet is small enough for Hyprland's 1024-byte IPC limit.
        g_pEventManager->postEvent({"omaspacestabs", "begin"});
        for (const auto& tab : tabScratch) {
            auto owner = tab.owner.lock(), target = tab.target.lock();
            if (!owner || !target || !exposed(owner, tab.tab)) continue;
            if (std::ranges::find(labelGroups, tab.group) == labelGroups.end()) {
                labelGroups.push_back(tab.group);
                labelBars.push_back({tab.bar.x, tab.bar.y, tab.bar.w, tab.bar.h});
            }
            auto data = payload({owner, target, tab.tab});
            auto monitor = owner->m_monitor.lock();
            if (!monitor) continue;
            data.add("id", std::format("0x{:x}", tab.group));
            data.add("topReserved", monitor->m_reservedArea.top());
            Json bar;
            bar.add("x", tab.bar.x); bar.add("y", tab.bar.y); bar.add("w", tab.bar.w); bar.add("h", tab.bar.h);
            data.add("bar", bar); data.add("front", tab.front); data.add("indicator", int(*indicatorHeight));
            // QML reads the live title directly, avoiding long titles in IPC.
            data.add("title", "");
            ++visibleTabCount;
            g_pEventManager->postEvent({"omaspacestabs", data.dump()});
        }
        g_pEventManager->postEvent({"omaspacestabs", "end"});
        updateLabelVisibility();
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
        if (action == "tabs" || action == "tabs-labels") {
            customLabelsRequested = action == "tabs-labels";
            if (!customLabelsRequested) setNativeTextHidden(false);
            snapshotsEnabled = true; syncTabs(true);
            g_pEventManager->postEvent({"omaspaceslabels", nativeTextHidden ? "custom" : "native"});
        }
        else if (action == "snapshots-off") {
            snapshotsEnabled = false; visibleTabCount = 0; tabsHash = 0;
            customLabelsRequested = false; labelBars.clear(); setNativeTextHidden(false);
            g_pEventManager->postEvent({"omaspacestabs", "begin"});
            g_pEventManager->postEvent({"omaspacestabs", "end"});
        }
        else if (action == "enable") { enabled = true; clear(); }
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
        result.add("snapshotsEnabled", snapshotsEnabled); result.add("visibleTabs", uint64_t(visibleTabCount));
        result.add("tabsPaused", tabsPaused); result.add("nativeTextHidden", nativeTextHidden);
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
    return {"omaspaces-hover", "Group tab hover and still-thumbnail bridge for OmaSpaces", "Rick / OmaSpaces", "0.2.0"};
}
APICALL EXPORT void PLUGIN_EXIT() { detector.reset(); }
