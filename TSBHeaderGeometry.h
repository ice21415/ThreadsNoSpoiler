#pragma once
#include <algorithm>
#include <cmath>

struct TSBHeaderRect { double x, y, width, height; };
struct TSBHeaderPlan {
    TSBHeaderRect content, menu, badge;
    double scale, translateX, translateY;
};

static inline bool TSBHeaderIntersects(TSBHeaderRect a, TSBHeaderRect b) {
    return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 &&
        a.x < b.x + b.width && b.x < a.x + a.width &&
        a.y < b.y + b.height && b.y < a.y + a.height;
}

static inline bool TSBHeaderContains(TSBHeaderRect outer, TSBHeaderRect inner) {
    return inner.width > 0 && inner.height > 0 && inner.x >= outer.x && inner.y >= outer.y &&
        inner.x + inner.width <= outer.x + outer.width + 0.00001 &&
        inner.y + inner.height <= outer.y + outer.height + 0.00001;
}

// Partition the EXISTING header rectangle. No row insertion or scroll offsets.
static inline TSBHeaderPlan TSBCompactHeader(TSBHeaderRect header, TSBHeaderRect envelope,
                                            double desiredBadgeWidth, bool hasMenu) {
    double margin = std::min(2.0, std::min(header.width, header.height) / 12.0);
    double gap = margin;
    double laneWidth = std::min(std::max(30.0, desiredBadgeWidth), header.width * 0.30);
    double usableHeight = header.height - 2 * margin;
    double laneX = header.x + header.width - margin - laneWidth;
    TSBHeaderRect content = {header.x + margin, header.y + margin,
                            laneX - gap - header.x - margin, usableHeight};
    double menuHeight = hasMenu ? std::min(22.0, (usableHeight - gap) / 2.0) : 0.0;
    double badgeHeight = std::min(24.0, usableHeight - menuHeight - (hasMenu ? gap : 0.0));
    double badgeY = hasMenu ? header.y + margin + menuHeight + gap :
        header.y + (header.height - badgeHeight) / 2.0;
    TSBHeaderRect menu = {laneX, header.y + margin, laneWidth, menuHeight};
    TSBHeaderRect badge = {laneX, badgeY, laneWidth, badgeHeight};
    double scale = std::min(1.0, std::min(content.width / envelope.width, content.height / envelope.height));
    return {content, menu, badge, scale,
            content.x - envelope.x * scale,
            content.y + (content.height - envelope.height * scale) / 2.0 - envelope.y * scale};
}

static inline TSBHeaderRect TSBMapHeaderRect(TSBHeaderRect rect, const TSBHeaderPlan &plan) {
    return {rect.x * plan.scale + plan.translateX, rect.y * plan.scale + plan.translateY,
            rect.width * plan.scale, rect.height * plan.scale};
}
