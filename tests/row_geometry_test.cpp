#include "../TSBRowGeometry.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

static bool intersects(TSBRowRect a, TSBRowRect b) {
    return a.x < b.x + b.width && b.x < a.x + a.width &&
           a.y < b.y + b.height && b.y < a.y + a.height;
}

int main() {
    // All header elements present, followed immediately by full-width text/media.
    // Test phone widths and large text; native elements must not move relative
    // to each other and the action must have its own non-overlapping row.
    for (double width : {160.0, 320.0, 393.0, 768.0}) {
        for (double buttonHeight : {44.0, 72.0, 120.0}) {
            TSBRowRect elements[] = {
                {8, 4, 40, 40},              // avatar
                {56, 4, width - 112, 18},    // ID
                {56, 24, 32, 16},            // date
                {90, 24, 16, 16},            // edited glyph
                {56, 42, width - 80, 18},    // topic text
                {width - 48, 24, 16, 16},    // thread count
                {width - 48, 0, 44, 24}      // menu
            };
            TSBRowGap gaps[] = {{64, buttonHeight + 8}, {400, 52}};
            TSBRowRect badge = {width - 60, TSBRowTop(0, gaps) + 4, 44, buttonHeight};
            TSBRowRect body = TSBShiftRect({0, 64, width, 280}, gaps, 2);
            for (auto element : elements) {
                auto moved = TSBShiftRect(element, gaps, 2);
                assert(moved.y == element.y && moved.height == element.height);
                assert(!intersects(badge, moved));
            }
            assert(!intersects(badge, body));
            assert(body.y == 64 + buttonHeight + 8);
            assert(TSBRowTop(1, gaps) == 400 + buttonHeight + 8);
            auto secondBody = TSBShiftRect({0, 400, width, 100}, gaps, 2);
            assert(secondBody.y == 400 + buttonHeight + 8 + 52);
            auto decoration = TSBShiftRect({0, 0, width, 500}, gaps, 2);
            assert(decoration.y == 0 && decoration.height == 500 + buttonHeight + 8 + 52);
        }
    }
    // Header glyph extends past its cell. Reserve that overflow before the row.
    TSBRowGap overflow[] = {{40, 12 + 44 + 8}};
    TSBRowRect overflowBadge = {0, TSBRowTop(0, overflow) + 12 + 4, 44, 44};
    assert(!intersects(overflowBadge, {0, 32, 44, 20}));
    assert(!intersects(overflowBadge, TSBShiftRect({0, 40, 320, 100}, overflow, 1)));
    // Reload/reset restores native geometry without residual offsets.
    auto reset = TSBShiftRect({0, 400, 320, 100}, nullptr, 0);
    assert(reset.y == 400 && reset.height == 100);
    // Consecutive boundaries and fractional native heights do not overlap.
    TSBRowGap adjacent[] = {{40.5, 52}, {40.5, 80}};
    assert(TSBRowTop(1, adjacent) == 92.5);
    assert(TSBRowOffset(40.5, adjacent, 2) == 132);
    // Scrolling into inserted space must still fetch cells shifted into view.
    TSBRowGap scrolling[] = {{40, 52}, {100, 52}, {160, 52}};
    for (double viewportY = 0; viewportY < 500; viewportY += 7) {
        TSBRowRect viewport = {0, viewportY, 320, 80};
        auto query = TSBNativeQueryRect(viewport, scrolling, 3);
        for (double nativeY = 0; nativeY < 400; nativeY += 20) {
            TSBRowRect native = {0, nativeY, 320, 20};
            auto moved = TSBShiftRect(native, scrolling, 3);
            if (intersects(moved, viewport)) assert(intersects(native, query));
        }
    }
    std::puts("PASS: native components, reserved rows, large text, narrow widths, overflow, reset and cumulative offsets");
}
