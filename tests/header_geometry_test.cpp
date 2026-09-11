#include "../TSBHeaderGeometry.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

int main() {
    for (double width : {160.0, 320.0, 393.0, 768.0}) {
        for (double height : {28.0, 44.0, 60.0, 96.0}) {
            for (bool hasMenu : {false, true}) {
                TSBHeaderRect header = {3, 7, width, height};
                // Include native glyphs that extend beyond the content container.
                for (double overflow : {0.0, 12.0}) {
                    TSBHeaderRect envelope = {1, 5, width + 4, height + 4 + overflow};
                    const TSBHeaderRect original = header;
                    auto plan = TSBCompactHeader(header, envelope, 32, hasMenu);
                    assert(header.x == original.x && header.y == original.y &&
                           header.width == original.width && header.height == original.height);
                    assert(TSBHeaderContains(header, plan.badge));
                    auto content = TSBMapHeaderRect(envelope, plan);
                    assert(TSBHeaderContains(header, content));
                    assert(!TSBHeaderIntersects(content, plan.badge));
                    assert(plan.badge.width > 0 && plan.badge.height > 0);
                    assert(plan.scale > 0 && plan.scale <= 1);
                    if (hasMenu) {
                        assert(TSBHeaderContains(header, plan.menu));
                        assert(!TSBHeaderIntersects(content, plan.menu));
                        assert(!TSBHeaderIntersects(plan.menu, plan.badge));
                        assert(plan.badge.y >= plan.menu.y + plan.menu.height);
                    }
                    // Relative layout and aspect ratios of ID, date, edited,
                    // count, topic and native text are preserved by one scale.
                    TSBHeaderRect parts[] = {
                        {4, 8, width / 2, 8}, {4, 18, 24, 8}, {30, 18, 8, 8},
                        {40, 18, 8, 8}, {52, 18, 24, 8}, {80, 18, width / 3, 8}
                    };
                    for (auto part : parts) {
                        auto moved = TSBMapHeaderRect(part, plan);
                        assert(!TSBHeaderIntersects(moved, plan.badge));
                        if (hasMenu) assert(!TSBHeaderIntersects(moved, plan.menu));
                        assert(std::abs(moved.width / moved.height - part.width / part.height) < 1e-8);
                    }
                    // Recompute from restored native geometry: no cumulative shrink.
                    auto again = TSBCompactHeader(header, envelope, 32, hasMenu);
                    assert(again.scale == plan.scale && again.badge.y == plan.badge.y);
                    // Following content starts at its original boundary.
                    TSBHeaderRect body = {3, header.y + header.height, width, 400};
                    assert(!TSBHeaderIntersects(plan.badge, body));
                }
            }
        }
    }
    std::puts("PASS: fixed header dimensions, component separation, menu/badge bounds, overflow, aspect ratios and repeat stability");
}
