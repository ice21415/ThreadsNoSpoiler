#pragma once
#include <stddef.h>

// Native coordinates, before any rows are inserted. Sorted by afterY.
struct TSBRowGap { double afterY, height; };
struct TSBRowRect { double x, y, width, height; };

static inline double TSBRowOffset(double y, const TSBRowGap *gaps, size_t count) {
    double offset = 0;
    for (size_t i = 0; i < count; ++i)
        if (gaps[i].afterY <= y) offset += gaps[i].height;
    return offset;
}

static inline TSBRowRect TSBShiftRect(TSBRowRect rect, const TSBRowGap *gaps, size_t count) {
    double bottom = rect.y + rect.height;
    double offset = TSBRowOffset(rect.y, gaps, count);
    // Spanning decorations grow; individual cells keep their native size.
    for (size_t i = 0; i < count; ++i)
        if (gaps[i].afterY > rect.y && gaps[i].afterY < bottom)
            rect.height += gaps[i].height;
    rect.y += offset;
    return rect;
}

static inline double TSBRowTop(size_t index, const TSBRowGap *gaps) {
    double y = gaps[index].afterY;
    for (size_t i = 0; i < index; ++i) y += gaps[i].height;
    return y;
}

static inline TSBRowRect TSBNativeQueryRect(TSBRowRect rect, const TSBRowGap *gaps, size_t count) {
    double total = 0;
    for (size_t i = 0; i < count; ++i) total += gaps[i].height;
    rect.y -= total;
    rect.height += total;
    return rect;
}
