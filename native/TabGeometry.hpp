#pragma once
#include <cmath>
#include <optional>

namespace OmaSpaces {
struct Rect {
    double x = 0, y = 0, w = 0, h = 0;
    bool contains(double px, double py) const {
        return w > 0 && h > 0 && px >= x && py >= y && px < x + w && py < y + h;
    }
    bool operator==(const Rect&) const = default;
};
struct TabHit { int index; Rect rect; };

// Match the groupbar's draw geometry, including padding and stacked order.
inline std::optional<TabHit> tabAt(Rect bar, int count, bool stacked,
                                  double innerGap, double outerGap, bool keepUpperGap,
                                  double px, double py) {
    if (count <= 0 || !bar.contains(px, py)) return {};
    const double top = keepUpperGap ? outerGap : 0;
    const double extent = stacked ? (bar.h - top - outerGap * count) / count
                                 : (bar.w - innerGap * (count - 1)) / count;
    const double step = extent + (stacked ? outerGap : innerGap);
    if (extent <= 0 || step <= 0) return {};
    const int index = int(std::floor((stacked ? py - bar.y - top : px - bar.x) / step));
    if (index < 0 || index >= count) return {};
    Rect rect = stacked ? Rect{bar.x, bar.y + top + index * step, bar.w, extent}
                        : Rect{bar.x + index * step, bar.y + top, extent, bar.h - top - outerGap};
    if (!rect.contains(px, py)) return {};
    return TabHit{index, rect};
}
} // namespace OmaSpaces
