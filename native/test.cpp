#include "TabGeometry.hpp"
#include <cassert>
#include <iostream>
using namespace OmaSpaces;
int main() {
    assert(plainTabDrag(0));
    assert(plainTabDrag(2 | 16)); // Caps and Num lock
    for (unsigned modifier : {1U, 4U, 8U, 64U}) assert(!plainTabDrag(modifier));
    assert(!dragThresholdReached(5, 0));
    assert(!dragThresholdReached(0, -5));
    assert(dragThresholdReached(6, 0));
    assert(dragThresholdReached(-6, 0));
    assert(dragThresholdReached(5, 4));
    const Rect bar{1920, 20, 1000, 30};
    auto hit = [&](double x, double y) { return tabAt(bar, 3, false, 2, 2, true, x, y); };
    assert(!hit(1919, 30));
    assert(!hit(1920, 20)); // upper padding
    assert(!hit(1920, 49)); // lower padding
    assert(hit(1920, 22)->index == 0);
    assert(hit(2251, 30)->index == 0);
    assert(!hit(2253, 30)); // gap, never a neighbour
    assert(hit(2255, 30)->index == 1);
    assert(hit(2919, 30)->index == 2);
    assert(!hit(2920, 30)); // right edge excluded
    assert(!tabAt(bar, 0, false, 2, 2, true, 2000, 30));
    assert(!tabAt({0, 0, 1, 20}, 10, false, 2, 2, true, 0, 5));
    const Rect stack{-400, 100, 400, 68}; // 3 rows of 20 + gaps 2 + upper gap 2
    assert(tabAt(stack, 3, true, 2, 2, true, -300, 102)->index == 0);
    assert(!tabAt(stack, 3, true, 2, 2, true, -300, 122));
    assert(tabAt(stack, 3, true, 2, 2, true, -300, 124)->index == 1);
    assert(tabAt(stack, 3, true, 2, 2, true, -300, 146)->index == 2);
    for (int i = 0; i < 3; ++i) {
        auto rect = tabRect(bar,3,i,false,2,2,true);
        assert(hit(rect.x+rect.w/2,rect.y+rect.h/2)->index == i);
        auto stackedRect = tabRect(stack,3,i,true,2,2,true);
        assert(tabAt(stack,3,true,2,2,true,stackedRect.x+10,stackedRect.y+3)->index == i);
    }
    std::cout << "Tab geometry: horizontal/stacked ordering, gaps, monitor offsets and boundaries passed\n";
}
