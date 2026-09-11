#import "TSBAdaptiveLayout.h"
#import "TSBRowGeometry.h"
#import <objc/runtime.h>
#import <substrate.h>
#include <vector>

@interface TSBReservedRow : NSObject
@property (nonatomic, strong) NSIndexPath *path;
@property (nonatomic, weak) UIButton *badge;
@property (nonatomic) CGFloat height;
@property (nonatomic) CGFloat anchorX;
@property (nonatomic) CGSize desiredSize;
@property (nonatomic) CGFloat headerOverflow;
@end
@implementation TSBReservedRow
@end

static char TSBBadgeRowsKey;
static Class TSBLayoutClass;
static thread_local unsigned TSBNativeDepth;
struct TSBNativeScope {
    TSBNativeScope() { ++TSBNativeDepth; }
    ~TSBNativeScope() { --TSBNativeDepth; }
};
static NSArray *(*TSBOriginalElements)(UICollectionViewLayout *, SEL, CGRect);
static UICollectionViewLayoutAttributes *(*TSBOriginalItem)(UICollectionViewLayout *, SEL, NSIndexPath *);
static UICollectionViewLayoutAttributes *(*TSBOriginalSupplementary)(UICollectionViewLayout *, SEL, NSString *, NSIndexPath *);
static UICollectionViewLayoutAttributes *(*TSBOriginalDecoration)(UICollectionViewLayout *, SEL, NSString *, NSIndexPath *);
static CGSize (*TSBOriginalContentSize)(UICollectionViewLayout *, SEL);
static void (*TSBOriginalPrepareUpdates)(UICollectionViewLayout *, SEL, NSArray *);
static void (*TSBOriginalReloadData)(UICollectionView *, SEL);
static void (*TSBOriginalCollectionLayout)(UICollectionView *, SEL);

static NSMutableDictionary<NSIndexPath *, TSBReservedRow *> *TSBRows(UICollectionView *collection) {
    return objc_getAssociatedObject(collection, &TSBBadgeRowsKey);
}

static UICollectionViewLayoutAttributes *TSBNativeItem(UICollectionViewLayout *layout, NSIndexPath *path) {
    if (path.section >= [layout.collectionView numberOfSections] ||
        path.item >= [layout.collectionView numberOfItemsInSection:path.section]) return nil;
    TSBNativeScope scope;
    return TSBOriginalItem(layout, @selector(layoutAttributesForItemAtIndexPath:), path);
}

struct TSBRowSnapshot {
    std::vector<TSBRowGap> gaps;
    __strong NSArray<TSBReservedRow *> *rows;
    double total = 0;
};

static TSBRowSnapshot TSBSnapshot(UICollectionViewLayout *layout) {
    TSBRowSnapshot result;
    NSMutableArray<TSBReservedRow *> *valid = [NSMutableArray array];
    NSMutableDictionary<NSIndexPath *, NSValue *> *frames = [NSMutableDictionary dictionary];
    for (TSBReservedRow *row in TSBRows(layout.collectionView).allValues) {
        UICollectionViewLayoutAttributes *attributes = TSBNativeItem(layout, row.path);
        if (!attributes || CGRectIsEmpty(attributes.frame)) continue;
        frames[row.path] = [NSValue valueWithCGRect:attributes.frame];
        [valid addObject:row];
    }
    [valid sortUsingComparator:^NSComparisonResult(TSBReservedRow *a, TSBReservedRow *b) {
        CGFloat ay = CGRectGetMaxY(frames[a.path].CGRectValue);
        CGFloat by = CGRectGetMaxY(frames[b.path].CGRectValue);
        return ay < by ? NSOrderedAscending : ay > by ? NSOrderedDescending : [a.path compare:b.path];
    }];
    result.rows = valid;
    for (TSBReservedRow *row in valid) {
        result.gaps.push_back({CGRectGetMaxY(frames[row.path].CGRectValue), row.height});
        result.total += row.height;
    }
    return result;
}

static UICollectionViewLayoutAttributes *TSBShiftAttributes(UICollectionViewLayoutAttributes *native,
                                                           const TSBRowSnapshot &snapshot) {
    if (!native || snapshot.gaps.empty()) return native;
    // Never mutate the native layout's cached attributes.
    UICollectionViewLayoutAttributes *copy = [native copy];
    CGRect frame = copy.frame;
    TSBRowRect moved = TSBShiftRect({frame.origin.x, frame.origin.y, frame.size.width, frame.size.height},
                                  snapshot.gaps.data(), snapshot.gaps.size());
    copy.frame = CGRectMake(moved.x, moved.y, moved.width, moved.height);
    return copy;
}

static NSArray *TSBElements(UICollectionViewLayout *layout, SEL cmd, CGRect rect) {
    if (TSBNativeDepth || !TSBRows(layout.collectionView).count) return TSBOriginalElements(layout, cmd, rect);
    TSBRowSnapshot snapshot = TSBSnapshot(layout);
    // Expanded query includes native cells that move into the requested viewport.
    TSBRowRect nativeQuery = TSBNativeQueryRect({rect.origin.x, rect.origin.y, rect.size.width, rect.size.height},
                                               snapshot.gaps.data(), snapshot.gaps.size());
    CGRect query = CGRectMake(nativeQuery.x, nativeQuery.y, nativeQuery.width, nativeQuery.height);
    NSArray *native;
    { TSBNativeScope scope; native = TSBOriginalElements(layout, cmd, query); }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:native.count];
    for (UICollectionViewLayoutAttributes *attributes in native) {
        UICollectionViewLayoutAttributes *moved = TSBShiftAttributes(attributes, snapshot);
        if (CGRectIntersectsRect(moved.frame, rect)) [result addObject:moved];
    }
    return result;
}

static UICollectionViewLayoutAttributes *TSBItem(UICollectionViewLayout *layout, SEL cmd, NSIndexPath *path) {
    UICollectionViewLayoutAttributes *native;
    { TSBNativeScope scope; native = TSBOriginalItem(layout, cmd, path); }
    return TSBNativeDepth ? native : TSBShiftAttributes(native, TSBSnapshot(layout));
}

static UICollectionViewLayoutAttributes *TSBSupplementary(UICollectionViewLayout *layout, SEL cmd,
                                                         NSString *kind, NSIndexPath *path) {
    UICollectionViewLayoutAttributes *native;
    { TSBNativeScope scope; native = TSBOriginalSupplementary(layout, cmd, kind, path); }
    return TSBNativeDepth ? native : TSBShiftAttributes(native, TSBSnapshot(layout));
}

static UICollectionViewLayoutAttributes *TSBDecoration(UICollectionViewLayout *layout, SEL cmd,
                                                      NSString *kind, NSIndexPath *path) {
    UICollectionViewLayoutAttributes *native;
    { TSBNativeScope scope; native = TSBOriginalDecoration(layout, cmd, kind, path); }
    return TSBNativeDepth ? native : TSBShiftAttributes(native, TSBSnapshot(layout));
}

static CGSize TSBContentSize(UICollectionViewLayout *layout, SEL cmd) {
    CGSize size;
    { TSBNativeScope scope; size = TSBOriginalContentSize(layout, cmd); }
    if (!TSBNativeDepth) size.height += TSBSnapshot(layout).total;
    return size;
}

void TSBResetBadgeRows(UICollectionView *collection) {
    if (!TSBRows(collection)) return;
    for (TSBReservedRow *row in TSBRows(collection).allValues) {
        [row.badge sendActionsForControlEvents:UIControlEventTouchCancel];
        [row.badge removeFromSuperview];
    }
    objc_setAssociatedObject(collection, &TSBBadgeRowsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [collection.collectionViewLayout invalidateLayout];
}

static void TSBPrepareUpdates(UICollectionViewLayout *layout, SEL cmd, NSArray *updates) {
    // Index paths belong to a single data snapshot; never reuse them after edits.
    TSBResetBadgeRows(layout.collectionView);
    TSBNativeScope scope;
    TSBOriginalPrepareUpdates(layout, cmd, updates);
}

static void TSBReloadData(UICollectionView *collection, SEL cmd) {
    TSBResetBadgeRows(collection);
    TSBOriginalReloadData(collection, cmd);
}

static void TSBPositionRows(UICollectionView *collection) {
    if (!TSBRows(collection).count || ![collection.collectionViewLayout isKindOfClass:TSBLayoutClass]) return;
    TSBRowSnapshot snapshot = TSBSnapshot(collection.collectionViewLayout);
    for (NSUInteger i = 0; i < snapshot.rows.count; ++i) {
        TSBReservedRow *row = snapshot.rows[i];
        UIButton *badge = row.badge;
        if (!badge || badge.superview != collection) continue;
        CGRect header = TSBNativeItem(collection.collectionViewLayout, row.path).frame;
        CGFloat left = MAX(CGRectGetMinX(header), CGRectGetMinX(collection.bounds) + collection.safeAreaInsets.left) + 8.0;
        CGFloat right = MIN(CGRectGetMaxX(header), CGRectGetMaxX(collection.bounds) - collection.safeAreaInsets.right) - 8.0;
        CGFloat width = MIN(row.desiredSize.width, MAX(1.0, right - left));
        CGFloat x = MAX(left, MIN(row.anchorX - width / 2.0, right - width));
        CGFloat top = TSBRowTop(i, snapshot.gaps.data());
        badge.frame = CGRectMake(x, top + row.headerOverflow + 4.0, width, row.desiredSize.height);
        [collection bringSubviewToFront:badge];
    }
}

static void TSBCollectionLayout(UICollectionView *collection, SEL cmd) {
    TSBOriginalCollectionLayout(collection, cmd);
    TSBPositionRows(collection);
}

static BOOL TSBInstallLayout(UICollectionViewLayout *layout) {
    Class cls = layout.class;
    if (TSBLayoutClass) return [layout isKindOfClass:TSBLayoutClass];
    // Exact layout discovered in this bundle; do not hook unrelated carousels.
    if (![NSStringFromClass(cls) isEqualToString:@"BCNFeedCollectionView.BCNFeedCollectionViewLayout"]) return NO;
    TSBLayoutClass = cls;
    MSHookMessageEx(cls, @selector(layoutAttributesForElementsInRect:), (IMP)TSBElements, (IMP *)&TSBOriginalElements);
    MSHookMessageEx(cls, @selector(layoutAttributesForItemAtIndexPath:), (IMP)TSBItem, (IMP *)&TSBOriginalItem);
    MSHookMessageEx(cls, @selector(layoutAttributesForSupplementaryViewOfKind:atIndexPath:), (IMP)TSBSupplementary, (IMP *)&TSBOriginalSupplementary);
    MSHookMessageEx(cls, @selector(layoutAttributesForDecorationViewOfKind:atIndexPath:), (IMP)TSBDecoration, (IMP *)&TSBOriginalDecoration);
    MSHookMessageEx(cls, @selector(collectionViewContentSize), (IMP)TSBContentSize, (IMP *)&TSBOriginalContentSize);
    MSHookMessageEx(cls, @selector(prepareForCollectionViewUpdates:), (IMP)TSBPrepareUpdates, (IMP *)&TSBOriginalPrepareUpdates);
    MSHookMessageEx(UICollectionView.class, @selector(reloadData), (IMP)TSBReloadData, (IMP *)&TSBOriginalReloadData);
    MSHookMessageEx(UICollectionView.class, @selector(layoutSubviews), (IMP)TSBCollectionLayout, (IMP *)&TSBOriginalCollectionLayout);
    return YES;
}

BOOL TSBReserveBadgeRow(UICollectionView *collection, NSIndexPath *headerPath,
                        UIButton *badge, CGFloat anchorX, CGSize desiredSize, CGFloat headerOverflow) {
    if (!collection || !headerPath || !TSBInstallLayout(collection.collectionViewLayout)) return NO;
    NSMutableDictionary *rows = TSBRows(collection);
    if (!rows) {
        rows = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(collection, &TSBBadgeRowsKey, rows, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    TSBReservedRow *row = rows[headerPath];
    CGFloat height = ceil(desiredSize.height) + ceil(headerOverflow) + 8.0;
    BOOL changed = !row || fabs(row.height - height) > 0.5;
    if (!row) {
        row = [TSBReservedRow new];
        row.path = headerPath;
        rows[headerPath] = row;
    }
    row.badge = badge;
    row.anchorX = anchorX;
    row.desiredSize = desiredSize;
    row.headerOverflow = ceil(headerOverflow);
    row.height = height;
    if (changed) {
        [collection.collectionViewLayout invalidateLayout];
        [collection setNeedsLayout];
    }
    TSBPositionRows(collection);
    return YES;
}
