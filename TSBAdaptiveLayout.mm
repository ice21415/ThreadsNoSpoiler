#import "TSBAdaptiveLayout.h"
#import "TSBHeaderGeometry.h"
#import <objc/runtime.h>

@interface TSBHeaderViewSnapshot : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) UIView *parent;
@property (nonatomic) CGPoint center;
@property (nonatomic) CGAffineTransform transform;
@property (nonatomic) CGPoint appliedCenter;
@property (nonatomic) CGAffineTransform appliedTransform;
@property (nonatomic) BOOL clips;
@property (nonatomic) BOOL appliedClips;
@end
@implementation TSBHeaderViewSnapshot
@end

@interface TSBHeaderState : NSObject
@property (nonatomic, strong) NSArray<TSBHeaderViewSnapshot *> *snapshots;
@property (nonatomic, weak) UIButton *badge;
@property (nonatomic, weak) UIView *menu;
@end
@implementation TSBHeaderState
@end

static char TSBHeaderStateKey;
static NSHashTable<UIView *> *TSBAdjustedHeaders;

static TSBHeaderRect TSBRect(CGRect rect) {
    return {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}
static CGRect TSBCGRect(TSBHeaderRect rect) {
    return CGRectMake(rect.x, rect.y, rect.width, rect.height);
}

void TSBRestoreHeaderLayout(UIView *header) {
    TSBHeaderState *state = objc_getAssociatedObject(header, &TSBHeaderStateKey);
    if (!state) return;
    [UIView performWithoutAnimation:^{
        for (TSBHeaderViewSnapshot *snapshot in state.snapshots) {
            UIView *view = snapshot.view;
            if (!view || view.superview != snapshot.parent) continue;
            // Restore only our applied values, preserving newer native updates.
            if (CGAffineTransformEqualToTransform(view.transform, snapshot.appliedTransform))
                view.transform = snapshot.transform;
            if (CGPointEqualToPoint(view.center, snapshot.appliedCenter))
                view.center = snapshot.center;
            if (view.clipsToBounds == snapshot.appliedClips) view.clipsToBounds = snapshot.clips;
        }
    }];
    objc_setAssociatedObject(header, &TSBHeaderStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TSBAdjustedHeaders removeObject:header];
}

void TSBResetAllHeaderLayouts(void) {
    for (UIView *header in TSBAdjustedHeaders.allObjects) {
        TSBHeaderState *state = objc_getAssociatedObject(header, &TSBHeaderStateKey);
        [state.badge sendActionsForControlEvents:UIControlEventTouchCancel];
        [state.badge removeFromSuperview];
        TSBRestoreHeaderLayout(header);
    }
}

static TSBHeaderViewSnapshot *TSBCaptureView(UIView *view) {
    TSBHeaderViewSnapshot *snapshot = [TSBHeaderViewSnapshot new];
    snapshot.view = view;
    snapshot.parent = view.superview;
    snapshot.center = view.center;
    snapshot.transform = view.transform;
    snapshot.clips = view.clipsToBounds;
    return snapshot;
}

UIView *TSBHitTestHeaderMenu(UIView *header, CGPoint point, UIView *source, UIEvent *event) {
    TSBHeaderState *state = objc_getAssociatedObject(header, &TSBHeaderStateKey);
    UIView *menu = state.menu;
    if (!menu || !menu.window || menu.hidden || menu.alpha < 0.01 || !menu.userInteractionEnabled ||
        header.hidden || header.alpha < 0.01) return nil;
    CGPoint local = [menu convertPoint:point fromView:source];
    return CGRectContainsPoint(menu.bounds, local) ? [menu hitTest:local withEvent:event] : nil;
}

static BOOL TSBFindFreeBadgeFrame(CGRect available, CGRect anchor, BOOL hasMenu,
                                  NSArray<NSValue *> *obstacles, CGRect *result) {
    const CGSize sizes[] = {{44, 28}, {36, 24}, {30, 20}};
    for (CGSize size : sizes) {
        CGFloat x = hasMenu ? CGRectGetMidX(anchor) - size.width / 2.0 :
            CGRectGetMaxX(available) - size.width;
        x = MAX(CGRectGetMinX(available), MIN(x, CGRectGetMaxX(available) - size.width));
        NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObjects:
            @(hasMenu ? CGRectGetMaxY(anchor) + 2.0 : CGRectGetMinY(available)),
            @(CGRectGetMaxY(available) - size.height), nil];
        for (NSValue *value in obstacles) [rows addObject:@(CGRectGetMaxY(value.CGRectValue) + 2.0)];
        for (NSNumber *row in rows) {
            CGRect frame = CGRectMake(x, row.doubleValue, size.width, size.height);
            if (hasMenu && CGRectGetMinY(frame) < CGRectGetMaxY(anchor) + 2.0) continue;
            if (!TSBHeaderContains(TSBRect(available), TSBRect(frame))) continue;
            BOOL blocked = NO;
            for (NSValue *value in obstacles) {
                if (CGRectIntersectsRect(CGRectInset(frame, -1, -1), value.CGRectValue)) {
                    blocked = YES;
                    break;
                }
            }
            if (!blocked) { *result = frame; return YES; }
        }
    }
    return NO;
}

BOOL TSBLayoutBadgeInHeader(UICollectionViewCell *header, UIView *metadata, UIView *menu, UIButton *badge) {
    TSBRestoreHeaderLayout(header);
    if (CGRectGetWidth(header.bounds) < 8 || CGRectGetHeight(header.bounds) < 8) return NO;
    if (badge.superview != header) [header addSubview:badge];
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    for (UIView *view in header.subviews) {
        if (view != badge && !view.hidden && view.alpha >= 0.01) [roots addObject:view];
    }
    NSMutableArray<NSValue *> *obstacles = [NSMutableArray array];
    NSMutableArray<UIView *> *pending = [roots mutableCopy];
    CGRect envelope = header.bounds;
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.01 || view == badge) continue;
        CGRect frame = [view convertRect:view.bounds toView:header];
        if (!CGRectIsEmpty(frame)) envelope = CGRectUnion(envelope, frame);
        BOOL content = view == metadata || view == menu || [view isKindOfClass:UIControl.class] ||
            [view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class] ||
            [view isKindOfClass:UITextView.class] || view.subviews.count == 0;
        if (content) {
            if (!CGRectIsEmpty(frame)) [obstacles addObject:[NSValue valueWithCGRect:frame]];
        }
        if (!content || !view.clipsToBounds) {
            [pending addObjectsFromArray:view.subviews];
        }
    }

    TSBHeaderState *state = [TSBHeaderState new];
    state.badge = badge;
    CGRect anchor = menu ? [menu convertRect:menu.bounds toView:header] : CGRectZero;
    CGRect target = CGRectZero;
    BOOL freeSlot = TSBFindFreeBadgeFrame(CGRectInset(header.bounds, 2, 2), anchor, menu != nil,
                                         obstacles, &target);
    if (!freeSlot) {
        // Compact the whole native group so inline CoreText glyphs, author ID,
        // date, topic, count and unknown controls keep their relative positions.
        TSBHeaderPlan plan = TSBCompactHeader(TSBRect(header.bounds), TSBRect(envelope), 32.0, menu != nil);
        NSMutableArray<TSBHeaderViewSnapshot *> *snapshots = [NSMutableArray array];
        for (UIView *root in roots) [snapshots addObject:TSBCaptureView(root)];
        if (menu && ![roots containsObject:menu]) [snapshots addObject:TSBCaptureView(menu)];
        for (UIView *parent = menu.superview; parent && parent != header; parent = parent.superview) {
            if (parent.clipsToBounds && ![roots containsObject:parent]) [snapshots addObject:TSBCaptureView(parent)];
        }
        [UIView performWithoutAnimation:^{
            for (UIView *root in roots) {
                CGPoint center = root.center;
                root.transform = CGAffineTransformScale(root.transform, plan.scale, plan.scale);
                root.center = CGPointMake(center.x * plan.scale + plan.translateX,
                                          center.y * plan.scale + plan.translateY);
            }
            if (menu) {
                for (UIView *parent = menu.superview; parent && parent != header; parent = parent.superview)
                    parent.clipsToBounds = NO;
                CGRect current = [menu convertRect:menu.bounds toView:header];
                if (!CGRectIsEmpty(current)) {
                    CGRect slot = TSBCGRect(plan.menu);
                    CGFloat scale = MIN(slot.size.width / current.size.width, slot.size.height / current.size.height);
                    menu.transform = CGAffineTransformScale(menu.transform, scale, scale);
                    menu.center = [header convertPoint:CGPointMake(CGRectGetMidX(slot), CGRectGetMidY(slot))
                                                toView:menu.superview];
                }
            }
        }];
        for (TSBHeaderViewSnapshot *snapshot in snapshots) {
            snapshot.appliedCenter = snapshot.view.center;
            snapshot.appliedTransform = snapshot.view.transform;
            snapshot.appliedClips = snapshot.view.clipsToBounds;
        }
        state.snapshots = snapshots;
        state.menu = menu;
        target = TSBCGRect(plan.badge);
    }
    // Both rendering and the hit target are confined to the native header.
    badge.titleLabel.font = [UIFont systemFontOfSize:target.size.height < 22.0 ? 10.0 : 11.0
                                            weight:UIFontWeightSemibold];
    badge.titleLabel.adjustsFontSizeToFitWidth = YES;
    badge.titleLabel.minimumScaleFactor = 0.85;
    [UIView performWithoutAnimation:^{ badge.frame = target; }];
    [header bringSubviewToFront:badge];
    objc_setAssociatedObject(header, &TSBHeaderStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!TSBAdjustedHeaders) TSBAdjustedHeaders = [NSHashTable weakObjectsHashTable];
    [TSBAdjustedHeaders addObject:header];
    return YES;
}
