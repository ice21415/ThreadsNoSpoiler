#pragma once
#include <algorithm>
#include <cstddef>

struct TSBFooterRect { double x, y, width, height; };
struct TSBFeedRow { long section, item; bool header, footer; };

// Match within one section and stop at the next post header. Visible rows may
// arrive in any order, and the original post header may have scrolled away.
static inline int TSBFindFooterRow(long section, long item, const TSBFeedRow *rows, size_t count) {
    int first = -1;
    for (size_t i = 0; i < count; ++i) {
        if (rows[i].section != section || rows[i].item < item || (!rows[i].header && !rows[i].footer)) continue;
        if (first < 0 || rows[i].item < rows[first].item) first = (int)i;
    }
    return first >= 0 && rows[first].footer ? first : -1;
}

static inline bool TSBFooterIntersects(TSBFooterRect a, TSBFooterRect b) {
    return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 &&
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

static inline bool TSBFooterContains(TSBFooterRect outer, TSBFooterRect inner) {
    return inner.width > 0 && inner.height > 0 && inner.x >= outer.x && inner.y >= outer.y &&
        inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height;
}

static inline bool TSBFindFooterBadge(TSBFooterRect footer, TSBFooterRect share,
                                     const TSBFooterRect *obstacles, size_t count, TSBFooterRect *result) {
    const double widths[] = {44, 36, 30, 26};
    for (double width : widths) {
        double height = std::min(width >= 36 ? 28.0 : 24.0, footer.height - 4.0);
        TSBFooterRect frame = {footer.x + footer.width - 8.0 - width,
            std::max(footer.y + 2.0, std::min(share.y + (share.height - height) / 2.0,
                     footer.y + footer.height - 2.0 - height)), width, height};
        if (!TSBFooterContains(footer, frame) || frame.x < share.x + share.width + 6.0) continue;
        bool blocked = false;
        TSBFooterRect padded = {frame.x - 2, frame.y - 2, frame.width + 4, frame.height + 4};
        for (size_t i = 0; i < count; ++i)
            if (TSBFooterIntersects(padded, obstacles[i])) { blocked = true; break; }
        if (!blocked) { *result = frame; return true; }
    }
    return false;
}

static inline bool TSBFindFooterBadgeMovingShare(TSBFooterRect footer, TSBFooterRect share,
                                                 const TSBFooterRect *obstacles, size_t count,
                                                 TSBFooterRect *movedShare, TSBFooterRect *result) {
    const double widths[] = {36, 30, 26};
    for (double width : widths) {
        double height = std::min(width >= 36 ? 28.0 : 24.0, footer.height - 4.0);
        TSBFooterRect badge = {footer.x + footer.width - 8.0 - width,
            std::max(footer.y + 2.0, std::min(share.y + (share.height - height) / 2.0,
                     footer.y + footer.height - 2.0 - height)), width, height};
        TSBFooterRect shifted = {badge.x - 6.0 - share.width, share.y, share.width, share.height};
        if (!TSBFooterContains(footer, badge) || !TSBFooterContains(footer, shifted)) continue;
        bool blocked = false;
        TSBFooterRect paddedShare = {shifted.x - 2, shifted.y, shifted.width + 4, shifted.height};
        TSBFooterRect paddedBadge = {badge.x - 2, badge.y - 2, badge.width + 4, badge.height + 4};
        for (size_t i = 0; i < count; ++i) {
            if (TSBFooterIntersects(paddedShare, obstacles[i]) ||
                TSBFooterIntersects(paddedBadge, obstacles[i])) { blocked = true; break; }
        }
        if (!blocked) { *movedShare = shifted; *result = badge; return true; }
    }
    return false;
}
