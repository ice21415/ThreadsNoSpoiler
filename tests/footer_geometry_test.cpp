#include "../TSBFooterGeometry.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

int main() {
    for (double width : {320.0, 375.0, 393.0, 768.0}) {
        for (double height : {28.0, 44.0, 60.0}) {
            TSBFooterRect footer = {0, 0, width, height};
            TSBFooterRect share = {width - 112, 0, 44, height};
            TSBFooterRect native[] = {{8, 0, 44, height}, {64, 0, 44, height},
                                     {120, 0, 44, height}, share};
            TSBFooterRect badge;
            assert(TSBFindFooterBadge(footer, share, native, 4, &badge));
            assert(TSBFooterContains(footer, badge));
            assert(badge.x >= share.x + share.width + 6);
            assert(badge.x + badge.width == width - 8);
            for (auto item : native) assert(!TSBFooterIntersects(item, badge));
            assert(footer.width == width && footer.height == height);
        }
    }
    TSBFooterRect narrow = {0, 0, 320, 44};
    TSBFooterRect share = {240, 0, 38, 44};
    TSBFooterRect badge;
    assert(TSBFindFooterBadge(narrow, share, &share, 1, &badge));
    assert(badge.width == 26);
    TSBFooterRect occupied[] = {share, {286, 0, 30, 44}};
    assert(!TSBFindFooterBadge(narrow, share, occupied, 2, &badge));
    TSBFooterRect movedShare;
    assert(TSBFindFooterBadgeMovingShare(narrow, share, nullptr, 0, &movedShare, &badge));
    assert(badge.x + badge.width == 312);
    assert(movedShare.x + movedShare.width + 6 == badge.x);
    assert(!TSBFooterIntersects(movedShare, badge));
    TSBFooterRect priorControl = {movedShare.x - 20, 0, 30, 44};
    assert(!TSBFindFooterBadgeMovingShare(narrow, share, &priorControl, 1, &movedShare, &badge));
    // Unordered visible cells, adjacent posts, other sections and missing footer.
    TSBFeedRow rows[] = {{0, 12, false, true}, {0, 8, true, false},
                        {0, 5, false, true}, {1, 5, false, true}, {0, 1, true, false}};
    assert(TSBFindFooterRow(0, 3, rows, 5) == 2);
    assert(TSBFindFooterRow(0, 9, rows, 5) == 0);
    assert(TSBFindFooterRow(1, 3, rows, 5) == 3);
    assert(TSBFindFooterRow(0, 6, rows, 5) == -1); // next header blocks another post's footer
    assert(TSBFindFooterRow(0, 20, rows, 5) == -1);
    assert(TSBFindFooterRow(2, 0, rows, 5) == -1);
    assert(TSBFindFooterRow(0, 5, rows, 5) == 2);
    // No visible header required for a long post whose source cell is still bound.
    TSBFeedRow footerOnly[] = {{0, 50, false, true}};
    assert(TSBFindFooterRow(0, 49, footerOnly, 1) == 0);
    std::puts("PASS: trailing share placement, fixed native bounds, narrow space, collisions and post/section matching");
}
