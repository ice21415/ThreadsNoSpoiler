#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "TSBAdaptiveRows.h"

static NSString * const TSBEnabledKey = @"TSBEnabled";
static NSString * const TSBForceHideContainerKey = @"TSBForceHideContainer";
static NSString * const TSBShowBadgeKey = @"TSBShowSpoilerBadge";
static char TSBSettingsButtonKey;
static char TSBBadgeKey;
static char TSBBadgeStatusKey;
static char TSBBadgeAnchorKey;
static char TSBPostTimestampKey;
static char TSBRemovalAnimationPlayedKey;
static char TSBVisibleSampleCountKey;
static char TSBLastVisibleFrameKey;
static char TSBActiveSpoilerKey;
static char TSBBadgeOwnerKey;
static char TSBPreviewingOriginalKey;
static NSMutableSet<NSString *> *TSBHookedClasses;
static NSHashTable<UIView *> *TSBPendingSpoilerViews;
static NSHashTable<UIView *> *TSBTrackedSpoilerViews;
static NSMutableOrderedSet<NSString *> *TSBObservedViewClasses;
static NSMutableOrderedSet<NSString *> *TSBLastSpoilerContext;
static NSMutableSet<NSString *> *TSBTimestampHookedClasses;
static NSMutableDictionary<NSString *, NSValue *> *TSBTimestampGetterIMPs;
static NSMutableSet<NSString *> *TSBHeaderHookedClasses;
static void (*TSBOriginalHeaderLayoutSubviews)(id, SEL);
static UIView *(*TSBOriginalCollectionHitTest)(id, SEL, CGPoint, UIEvent *);

static UIView *TSBHookedCollectionHitTest(UICollectionView *self, SEL selector, CGPoint point, UIEvent *event) {
    UIView *original = TSBOriginalCollectionHitTest(self, selector, point, event);
    if (!original || ![NSStringFromClass(self.class) containsString:@"BCNFeedCollectionView"] ||
        !CGRectContainsPoint(self.bounds, point)) return original;
    // The badge can sit below its header cell after a long topic wraps.
    // Route only its actual bounds at the collection level; a header-only
    // hit-test cannot catch a touch assigned to the following media cell.
    for (UICollectionViewCell *cell in self.visibleCells) {
        UIButton *badge = objc_getAssociatedObject(cell, &TSBBadgeKey);
        if (!badge || badge.hidden || badge.alpha < 0.01 || !badge.enabled ||
            !badge.userInteractionEnabled || badge.window != self.window ||
            cell.hidden || cell.alpha < 0.01) continue;
        CGPoint local = [badge convertPoint:point fromView:self];
        if (CGRectContainsPoint(badge.bounds, local)) return badge;
    }
    return original;
}
static void (*TSBOriginalCollectionCellDidMoveToWindow)(id, SEL);
static void (*TSBOriginalSetHidden)(id, SEL, BOOL);
static void (*TSBOriginalSetAlpha)(id, SEL, CGFloat);
static char TSBRequestedAlphaKey;
static void TSBUpdateSpoilerBadge(UIView *spoilerView);
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *timestamp);
static void TSBClearSpoilerBadge(UIView *spoilerView);

static BOOL TSBIsInVisibleViewport(UIView *view) {
    UIWindow *window = view.window;
    if (window == nil || view.superview == nil || view.bounds.size.width < 4.0 ||
        view.bounds.size.height < 4.0) {
        return NO;
    }
    for (UIView *ancestor = view.superview; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) {
            return NO;
        }
    }
    CGRect frameInWindow = [view convertRect:view.bounds toView:window];
    CGRect viewport = UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets);
    CGRect intersection = CGRectIntersection(frameInWindow, viewport);
    return !CGRectIsNull(intersection) && !CGRectIsEmpty(intersection) &&
        intersection.size.width >= 4.0 && intersection.size.height >= 4.0;
}

static BOOL TSBEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:TSBEnabledKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:TSBEnabledKey];
}

static BOOL TSBShowBadge(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:TSBShowBadgeKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:TSBShowBadgeKey];
}

// Preserve the native spoiler model and hierarchy so badges and previews
// remain available. Suppress only the concrete spoiler overlay's opacity.
static void TSBApplySpoilerPresentation(UIView *view) {
    if (!TSBOriginalSetAlpha) return;
    NSNumber *requested = objc_getAssociatedObject(view, &TSBRequestedAlphaKey);
    BOOL preview = [objc_getAssociatedObject(view, &TSBPreviewingOriginalKey) boolValue];
    CGFloat alpha = preview ? 1.0 : TSBEnabled() ? 0.0 : requested ? requested.doubleValue : 1.0;
    TSBOriginalSetAlpha(view, @selector(setAlpha:), alpha);
}

static void TSBHookedSetAlpha(UIView *self, SEL _cmd, CGFloat alpha) {
    objc_setAssociatedObject(self, &TSBRequestedAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TSBApplySpoilerPresentation(self);
}

static void TSBLog(NSString *format, ...) {
    (void)format;
}

static void TSBRecordView(UIView *view) {
    NSString *description = [NSString stringWithFormat:@"%@ (children: %lu)", NSStringFromClass(view.class), (unsigned long)view.subviews.count];
    if (![TSBObservedViewClasses containsObject:description] && TSBObservedViewClasses.count < 80) {
        [TSBObservedViewClasses addObject:description];
    }
}

static void TSBRecordHierarchy(UIView *view) {
    TSBRecordView(view);
    for (UIView *subview in view.subviews) {
        TSBRecordHierarchy(subview);
    }
}

// Threads renders a post as sibling header/text/media cells inside one feed
// collection. That collection is the stable common owner for its header and
// spoiler body. Do not inspect label text, subview order, or time formats.
static UIView *TSBPostContainer(UIView *view) {
    for (NSUInteger depth = 0; view && depth < 30; depth++, view = view.superview) {
        NSString *name = NSStringFromClass(view.class);
        if ([name containsString:@"BCNFeedCollection"] ||
            [name containsString:@"BCNFeedBaseCell"] ||
            [name containsString:@"BCNFeedInteractiveCell"] ||
            [name containsString:@"BCNPostRow"]) {
            return view;
        }
    }
    return nil;
}

static UICollectionViewCell *TSBOuterFeedCell(UIView *view) {
    for (NSUInteger depth = 0; view && depth < 30; depth++, view = view.superview) {
        if ([view isKindOfClass:UICollectionViewCell.class] &&
            [NSStringFromClass(view.superview.class) containsString:@"BCNFeedCollectionView"]) {
            return (UICollectionViewCell *)view;
        }
    }
    return nil;
}

static UICollectionViewCell *TSBHeaderCellForFeedCell(UICollectionViewCell *feedCell) {
    UICollectionView *collection = [feedCell.superview isKindOfClass:UICollectionView.class] ? (UICollectionView *)feedCell.superview : nil;
    NSIndexPath *target = collection ? [collection indexPathForCell:feedCell] : nil;
    if (!collection || !target) return nil;
    UICollectionViewCell *nearestHeader = nil;
    for (UICollectionViewCell *candidate in collection.visibleCells) {
        if (![NSStringFromClass(candidate.class) isEqualToString:@"BCNFeedItemHeaderCell.BCNFeedItemHeaderCell"]) continue;
        NSIndexPath *indexPath = [collection indexPathForCell:candidate];
        if (!indexPath) continue;
        BOOL isBefore = indexPath.section == target.section && indexPath.item < target.item;
        if (!isBefore) continue;
        NSIndexPath *current = nearestHeader ? [collection indexPathForCell:nearestHeader] : nil;
        if (!current || indexPath.section > current.section ||
            (indexPath.section == current.section && indexPath.item > current.item)) {
            nearestHeader = candidate;
        }
    }
    return nearestHeader;
}

static UICollectionViewCell *TSBHeaderCellContainingView(UIView *view) {
    for (NSUInteger depth = 0; view && depth < 20; depth++, view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"BCNFeedItemHeaderCell.BCNFeedItemHeaderCell"]) {
            return (UICollectionViewCell *)view;
        }
    }
    return nil;
}

static void TSBAppendHeaderTree(UIView *view, NSUInteger depth) {
    if (TSBLastSpoilerContext.count >= 120 || depth > 12) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    CGRect frame = view.frame;
    [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"%@header-tree %@ frame:(%.0f,%.0f,%.0f,%.0f) children:%lu",
        indent, NSStringFromClass(view.class), frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
        (unsigned long)view.subviews.count]];
    for (UIView *subview in view.subviews) {
        TSBAppendHeaderTree(subview, depth + 1);
    }
}

static void TSBCaptureSpoilerContext(UIView *spoilerView) {
    [TSBLastSpoilerContext removeAllObjects];
    UIView *candidate = spoilerView;
    for (NSUInteger depth = 0; candidate && depth < 30; depth++, candidate = candidate.superview) {
        [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"parent[%lu] %@ (children: %lu)",
            (unsigned long)depth, NSStringFromClass(candidate.class), (unsigned long)candidate.subviews.count]];
        if ([candidate isKindOfClass:UICollectionView.class]) {
            NSArray<__kindof UICollectionViewCell *> *visibleCells = ((UICollectionView *)candidate).visibleCells;
            for (UICollectionViewCell *cell in visibleCells) {
                if (TSBLastSpoilerContext.count >= 120) break;
                [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"collection[%lu] cell %@ (children: %lu)",
                    (unsigned long)depth, NSStringFromClass(cell.class), (unsigned long)cell.subviews.count]];
                for (UIView *child in cell.subviews) {
                    if (TSBLastSpoilerContext.count >= 120) break;
                    [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"  cell-child %@ (children: %lu)",
                        NSStringFromClass(child.class), (unsigned long)child.subviews.count]];
                }
                if ([NSStringFromClass(cell.class) containsString:@"BCNFeedItemHeaderCell"]) {
                    TSBAppendHeaderTree(cell, 0);
                }
            }
        }
    }
    UIView *post = TSBPostContainer(spoilerView);
    if (post) {
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:post];
        while (pending.count && TSBLastSpoilerContext.count < 120) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"post-tree %@ (children: %lu)",
                NSStringFromClass(view.class), (unsigned long)view.subviews.count]];
            for (UIView *subview in view.subviews.reverseObjectEnumerator) {
                [pending addObject:subview];
            }
        }
    }
}

static void TSBRegisterTimestampLabel(UIView *header, UILabel *label) {
    UICollectionViewCell *headerCell = TSBHeaderCellContainingView(header);
    if (headerCell && label) {
        objc_setAssociatedObject(headerCell, &TSBPostTimestampKey, label, OBJC_ASSOCIATION_ASSIGN);
        TSBLog(@"registered timestamp %@ for %@", NSStringFromClass(header.class), NSStringFromClass(headerCell.class));
    }
}

// In this Threads build, author and timestamp are CoreText runs in this exact
// header component, rather than separate UILabel instances.
static UIView *TSBHeaderMetadataTextView(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:@"feed-item-header-title"]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *result = TSBHeaderMetadataTextView(subview);
        if (result) return result;
    }
    return nil;
}

// The bundled Threads binary exposes MoreButtonConfig as part of the feed
// header layout. Prefer its named control, then use the rightmost compact
// header button as a resilient fallback when Threads changes its class name.
static UIView *TSBHeaderMoreButton(UIView *header) {
    UIView *namedButton = nil;
    UIView *rightmostButton = nil;
    CGFloat namedX = -CGFLOAT_MAX;
    CGFloat rightmostX = -CGFLOAT_MAX;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:header];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        for (UIView *subview in view.subviews) {
            [pending addObject:subview];
        }
        if ([view.accessibilityIdentifier isEqualToString:@"ThreadsNoSpoilerBadge"]) continue;
        if (view == header || view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) continue;

        NSString *className = NSStringFromClass(view.class).lowercaseString;
        NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        BOOL looksLikeButton = [view isKindOfClass:UIControl.class] || [className containsString:@"button"];
        if (!looksLikeButton) continue;

        CGRect frame = [view convertRect:view.bounds toView:header];
        if (CGRectIsEmpty(frame) || frame.size.width > 72.0 || frame.size.height > 72.0) continue;
        BOOL namedMoreButton = [className containsString:@"more"] ||
            [className containsString:@"overflow"] || [className containsString:@"menu"] ||
            [identifier containsString:@"more"] || [identifier containsString:@"overflow"] ||
            [identifier containsString:@"menu"] || [label containsString:@"more"] ||
            [label containsString:@"更多"] || [label containsString:@"選項"];
        if (namedMoreButton && CGRectGetMaxX(frame) > namedX) {
            namedButton = view;
            namedX = CGRectGetMaxX(frame);
        }
        if (CGRectGetMidX(frame) > CGRectGetWidth(header.bounds) * 0.60 &&
            CGRectGetMaxX(frame) > rightmostX) {
            rightmostButton = view;
            rightmostX = CGRectGetMaxX(frame);
        }
    }
    // A Threads logo or our own badge is not a post menu.
    (void)rightmostButton;
    return namedButton;
}

static UIView *TSBHeaderFollowButton(UIView *header) {
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:header];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.01 ||
            [view.accessibilityIdentifier isEqualToString:@"ThreadsNoSpoilerBadge"]) continue;
        [pending addObjectsFromArray:view.subviews];
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        NSString *title = [view isKindOfClass:UIButton.class] ? ((UIButton *)view).currentTitle.lowercaseString : @"";
        BOOL namedFollow = ([name containsString:@"follow"] && [name containsString:@"button"]) ||
            [identifier containsString:@"follow-button"] || [identifier containsString:@"follow_button"];
        BOOL followText = [label isEqualToString:@"追蹤"] || [label isEqualToString:@"关注"] ||
            [label isEqualToString:@"follow"] || [title isEqualToString:@"追蹤"] ||
            [title isEqualToString:@"关注"] || [title isEqualToString:@"follow"];
        CGRect frame = [view convertRect:view.bounds toView:header];
        if ((namedFollow || followText) && frame.size.width > 0 && frame.size.width <= 140 &&
            frame.size.height > 0 && frame.size.height <= 60) return view;
    }
    return nil;
}

static void TSBProcessHeaderCell(UIView *self) {
    UIView *metadataTextView = TSBHeaderMetadataTextView(self);
    UIView *post = TSBPostContainer(self);
    if (post && metadataTextView) {
        objc_setAssociatedObject(self, &TSBPostTimestampKey, metadataTextView, OBJC_ASSOCIATION_ASSIGN);
    }
    // Native layout can move the follow control after topic text wraps.
    NSHashTable *owners = objc_getAssociatedObject(self, &TSBBadgeOwnerKey);
    for (UIView *owner in owners.allObjects) {
        TSBUpdateSpoilerBadge(owner);
    }
}

static void TSBHookedHeaderLayoutSubviews(UIView *self, SEL _cmd) {
    TSBOriginalHeaderLayoutSubviews(self, _cmd);
    // Keep native header content in its original height. The appended row
    // belongs to our direct child badge, not to avatar/title centering.
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    CGFloat nativeHeight = TSBHeaderNativeHeight(cell);
    if (cell.bounds.size.height > nativeHeight + 1.0) {
        CGRect frame = cell.contentView.frame;
        if (frame.size.height != nativeHeight) {
            frame.size.height = nativeHeight;
            cell.contentView.frame = frame;
            [cell.contentView setNeedsLayout];
            [cell.contentView layoutIfNeeded];
        }
    }
    TSBProcessHeaderCell(self);
}

static void TSBHookedCollectionCellDidMoveToWindow(UICollectionViewCell *self, SEL _cmd) {
    TSBOriginalCollectionCellDidMoveToWindow(self, _cmd);
    if ([NSStringFromClass(self.class) isEqualToString:@"BCNFeedItemHeaderCell.BCNFeedItemHeaderCell"]) {
        if (self.window == nil) {
            UIView *badge = objc_getAssociatedObject(self, &TSBBadgeKey);
            [badge removeFromSuperview];
            objc_setAssociatedObject(self, &TSBBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &TSBBadgeOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        TSBProcessHeaderCell(self);
    }
}

static IMP TSBOriginalTimestampGetter(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *stored = TSBTimestampGetterIMPs[NSStringFromClass(cls)];
        if (stored) return (IMP)stored.pointerValue;
    }
    return NULL;
}

static id TSBHookedTimestampLabel(id self, SEL _cmd) {
    IMP original = TSBOriginalTimestampGetter(self);
    id value = original ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
    if ([value isKindOfClass:UILabel.class]) {
        TSBRegisterTimestampLabel(self, value);
    }
    return value;
}

static void TSBUpdateSpoilerBadge(UIView *spoilerView) {
    if (!TSBEnabled() || ![objc_getAssociatedObject(spoilerView, &TSBActiveSpoilerKey) boolValue] ||
        spoilerView.bounds.size.width < 4 || spoilerView.bounds.size.height < 4 ||
        !TSBIsInVisibleViewport(spoilerView)) {
        TSBClearSpoilerBadge(spoilerView);
        return;
    }
    UICollectionViewCell *cell = TSBOuterFeedCell(spoilerView);
    UICollectionViewCell *header = TSBHeaderCellForFeedCell(cell);
    UIView *moreButton = header ? TSBHeaderMoreButton(header) : nil;
    UIView *anchor = moreButton ?: (header ? TSBHeaderMetadataTextView(header) : nil);
    // Drop the previous association before rebinding to a different header.
    if (objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey) != anchor) {
        TSBClearSpoilerBadge(spoilerView);
    }
    NSString *status = !TSBShowBadge() ? @"disabled in settings" : !cell ? @"no outer feed cell" : !header ? @"no preceding visible header/index path" : !anchor ? @"header more button missing" : (moreButton ? @"more button resolved; placement requested" : @"metadata fallback; placement requested");
    objc_setAssociatedObject(spoilerView, &TSBBadgeStatusKey, status, OBJC_ASSOCIATION_COPY_NONATOMIC);
    TSBPlaceSpoilerBadge(spoilerView, anchor);
}

static void TSBClearSpoilerBadge(UIView *spoilerView) {
    UIView *anchor = objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey);
    UICollectionViewCell *header = TSBHeaderCellContainingView(anchor);
    NSHashTable *owners = header ? objc_getAssociatedObject(header, &TSBBadgeOwnerKey) : nil;
    if ([owners containsObject:spoilerView]) [owners removeObject:spoilerView];
    if (header != nil && owners.count == 0) {
        TSBSetHeaderRow(header, NO);
        UIView *badge = objc_getAssociatedObject(header, &TSBBadgeKey);
        [badge removeFromSuperview];
        objc_setAssociatedObject(header, &TSBBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(header, &TSBBadgeOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

@interface TSBSpoilerBadgeButton : UIButton
- (void)tsb_beginOriginalPreview:(id)sender;
- (void)tsb_endOriginalPreview:(id)sender;
@end

@implementation TSBSpoilerBadgeButton
- (void)tsb_setOriginalPreviewVisible:(BOOL)showingOriginal {
    NSHashTable<UIView *> *owners = objc_getAssociatedObject(self.superview, &TSBBadgeOwnerKey);
    if (showingOriginal) {
        self.alpha = 0.58;
    } else {
        self.alpha = 1.0;
    }
    for (UIView *spoilerView in owners.allObjects) {
        if (![objc_getAssociatedObject(spoilerView, &TSBActiveSpoilerKey) boolValue]) continue;
        objc_setAssociatedObject(spoilerView, &TSBPreviewingOriginalKey,
                                 showingOriginal ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL shouldHide = !showingOriginal &&
            [objc_getAssociatedObject(spoilerView, &TSBRemovalAnimationPlayedKey) boolValue];
        TSBOriginalSetHidden(spoilerView, @selector(setHidden:), shouldHide);
        TSBApplySpoilerPresentation(spoilerView);
    }
}

- (void)tsb_beginOriginalPreview:(id)sender {
    [self tsb_setOriginalPreviewVisible:YES];
}

- (void)tsb_endOriginalPreview:(id)sender {
    [self tsb_setOriginalPreviewVisible:NO];
}
@end

// Direct path used when the header has identified the spoiler in its own
// following cells. It intentionally bypasses collection-wide lookup.
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *timestamp) {
    UICollectionViewCell *header = TSBHeaderCellContainingView(timestamp);
    TSBSpoilerBadgeButton *badge = header ? objc_getAssociatedObject(header, &TSBBadgeKey) : nil;
    if (!TSBShowBadge() || header == nil || timestamp == nil) {
        if (header) TSBSetHeaderRow(header, NO);
        [badge removeFromSuperview];
        return;
    }
    if (badge == nil) {
        badge = [TSBSpoilerBadgeButton buttonWithType:UIButtonTypeCustom];
        [badge setTitle:@"劇透" forState:UIControlStateNormal];
        badge.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        [badge setTitleColor:UIColor.systemOrangeColor forState:UIControlStateNormal];
        badge.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.16];
        badge.layer.cornerRadius = 4.0;
        badge.clipsToBounds = YES;
        badge.translatesAutoresizingMaskIntoConstraints = YES;
        badge.exclusiveTouch = YES;
        badge.accessibilityIdentifier = @"ThreadsNoSpoilerBadge";
        badge.accessibilityLabel = @"劇透貼文";
        badge.accessibilityHint = @"按住可查看原始防劇透遮罩";
        [badge addTarget:badge action:@selector(tsb_beginOriginalPreview:)
          forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [badge addTarget:badge action:@selector(tsb_endOriginalPreview:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel | UIControlEventTouchDragExit];
        [badge sizeToFit];
        [header addSubview:badge];
        objc_setAssociatedObject(header, &TSBBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (badge.superview != header) {
        [badge removeFromSuperview];
        [header addSubview:badge];
    }
    NSHashTable *owners = objc_getAssociatedObject(header, &TSBBadgeOwnerKey);
    if (!owners) {
        owners = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(header, &TSBBadgeOwnerKey, owners, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [owners addObject:spoilerView];
    CGRect anchorFrame = [timestamp convertRect:timestamp.bounds toView:header];
    CGSize size = CGSizeMake(MAX(44.0, ceil(badge.bounds.size.width)), 32.0);
    UIView *metadata = TSBHeaderMetadataTextView(header);
    // Detail headers may have no local menu. Reserve a trailing slot rather
    // than treating the title or the Threads logo as a menu anchor.
    BOOL hasMenu = timestamp != metadata;
    CGFloat trailing = hasMenu ? CGRectGetMinX(anchorFrame) - 8.0 : CGRectGetWidth(header.bounds) - 56.0;
    CGFloat x = MAX(8.0, trailing - size.width);
    CGFloat y = round(CGRectGetMidY(anchorFrame) - size.height / 2.0);
    UIView *follow = TSBHeaderFollowButton(header);
    if (follow) {
        CGRect followFrame = [follow convertRect:follow.bounds toView:header];
        x = MAX(8.0, MIN(CGRectGetMidX(followFrame) - size.width / 2.0,
                        CGRectGetWidth(header.bounds) - size.width - 8.0));
        y = CGRectGetMaxY(followFrame) + 4.0;
    }
    CGRect targetFrame = CGRectMake(x, y, MAX(44.0, ceil(size.width)), MAX(32.0, ceil(size.height)));
    // Use actual rendered geometry, including unknown future header controls.
    NSMutableArray<NSValue *> *obstacles = [NSMutableArray array];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:header];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.01 || view == badge) continue;
        BOOL content = view == metadata || [view isKindOfClass:UIControl.class] ||
            [view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class] ||
            [view isKindOfClass:UITextView.class] ||
            (view.subviews.count == 0 && view != header);
        if (content) {
            CGRect frame = [view convertRect:view.bounds toView:header];
            if (!CGRectIsEmpty(frame)) [obstacles addObject:[NSValue valueWithCGRect:frame]];
        } else {
            [pending addObjectsFromArray:view.subviews];
        }
    }
    // Keep the complete touch target inside its owning cell. Moving outside
    // this rectangle could cover a sibling text/media cell, even if the header
    // itself has no obstacle at that position.
    CGFloat nativeHeight = TSBHeaderNativeHeight(header);
    CGRect nativeBounds = header.bounds;
    nativeBounds.size.height = nativeHeight;
    CGRect available = CGRectInset(nativeBounds, 4.0, 2.0);
    NSMutableArray<NSValue *> *candidates = [NSMutableArray arrayWithObject:[NSValue valueWithCGRect:targetFrame]];
    // Prefer below the requested anchor, then other free gaps in this header.
    NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObjects:@(y), @(CGRectGetMinY(available)), nil];
    NSMutableArray<NSNumber *> *columns = [NSMutableArray arrayWithObjects:@(x),
        @(CGRectGetMaxX(available) - size.width), @(CGRectGetMinX(available)), nil];
    for (NSValue *value in obstacles) {
        CGRect frame = value.CGRectValue;
        [rows addObject:@(CGRectGetMaxY(frame) + 4.0)];
        [columns addObject:@(CGRectGetMaxX(frame) + 8.0)];
        [columns addObject:@(CGRectGetMinX(frame) - size.width - 8.0)];
    }
    [rows sortUsingSelector:@selector(compare:)];
    for (NSNumber *row in rows) {
        for (NSNumber *column in columns) {
            [candidates addObject:[NSValue valueWithCGRect:CGRectMake(column.doubleValue,
                row.doubleValue, size.width, size.height)]];
        }
    }
    BOOL found = NO;
    for (NSValue *candidate in candidates) {
        CGRect frame = candidate.CGRectValue;
        if (!CGRectContainsRect(available, frame)) continue;
        BOOL blocked = NO;
        for (NSValue *obstacle in obstacles) {
            if (CGRectIntersectsRect(CGRectInset(frame, -4.0, -2.0), obstacle.CGRectValue)) {
                blocked = YES;
                break;
            }
        }
        if (!blocked) {
            targetFrame = frame;
            found = YES;
            break;
        }
    }
    if (!found) {
        TSBSetHeaderRow(header, YES);
        targetFrame = CGRectMake(MAX(4.0, CGRectGetWidth(header.bounds) - size.width - 8.0),
                                 nativeHeight + 4.0, size.width, size.height);
    } else {
        TSBSetHeaderRow(header, NO);
    }
    if (!CGRectEqualToRect(badge.frame, targetFrame)) {
        badge.frame = targetFrame;
    }
    objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, timestamp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    badge.hidden = NO;
}

static void TSBRegisterPendingSpoiler(UIView *spoilerView) {
    if (spoilerView != nil) {
        [TSBPendingSpoilerViews addObject:spoilerView];
    }
}

static void TSBRevealCarouselSpoilersIfNeeded(UIView *spoilerView);

static void TSBCheckPendingSpoilers(void) {
    for (UIView *view in TSBTrackedSpoilerViews.allObjects) {
        // A carousel can reuse an off-screen page without sending it through
        // a layout pass. Refresh every spoiler page in that post together.
        TSBRevealCarouselSpoilersIfNeeded(view);
        TSBUpdateSpoilerBadge(view);
    }
    if (!TSBEnabled() || ![NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey]) {
        return;
    }
    for (UIView *spoilerView in TSBPendingSpoilerViews.allObjects) {
        if (spoilerView.window == nil) {
            objc_setAssociatedObject(spoilerView, &TSBVisibleSampleCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(spoilerView, &TSBLastVisibleFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [TSBPendingSpoilerViews removeObject:spoilerView];
            continue;
        }
        UIWindow *window = spoilerView.window;
        CGRect frameInWindow = [spoilerView convertRect:spoilerView.bounds toView:window];
        CGRect viewport = UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets);
        BOOL fullyVisible = TSBIsInVisibleViewport(spoilerView) && CGRectContainsRect(viewport, frameInWindow);
        if (!fullyVisible) {
            objc_setAssociatedObject(spoilerView, &TSBVisibleSampleCountKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(spoilerView, &TSBLastVisibleFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }

        // Reveal on the first timer pass once the text is fully visible.
        objc_setAssociatedObject(spoilerView, &TSBRemovalAnimationPlayedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TSBOriginalSetHidden(spoilerView, @selector(setHidden:), YES);
        [TSBPendingSpoilerViews removeObject:spoilerView];
    }
}

static BOOL TSBIsSpoilerContainer(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"BCNSpoilerView"];
}

static void TSBRevealCarouselSpoilersIfNeeded(UIView *spoilerView) {
    if (!TSBEnabled() ||
        [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey] ||
        spoilerView.window == nil ||
        [objc_getAssociatedObject(spoilerView, &TSBPreviewingOriginalKey) boolValue]) {
        return;
    }
    UIView *post = TSBPostContainer(spoilerView) ?: spoilerView;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:post];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ((view == spoilerView || TSBIsSpoilerContainer(view)) &&
            ![objc_getAssociatedObject(view, &TSBPreviewingOriginalKey) boolValue]) {
            TSBApplySpoilerPresentation(view);
        }
        [pending addObjectsFromArray:view.subviews];
    }
}

static void (*TSBOriginalDidMoveToWindow)(id, SEL);
static void TSBHookedDidMoveToWindow(UIView *self, SEL _cmd) {
    TSBOriginalDidMoveToWindow(self, _cmd);
    TSBApplySpoilerPresentation(self);
    if (self.window == nil) {
        TSBClearSpoilerBadge(self);
        objc_setAssociatedObject(self, &TSBVisibleSampleCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TSBLastVisibleFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [TSBPendingSpoilerViews removeObject:self];
        return;
    }
    TSBRecordHierarchy(self);
    TSBCaptureSpoilerContext(self);
    [TSBTrackedSpoilerViews addObject:self];
    if (objc_getAssociatedObject(self, &TSBActiveSpoilerKey) == nil) {
        objc_setAssociatedObject(self, &TSBActiveSpoilerKey, @(!self.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey]) {
        if (![objc_getAssociatedObject(self, &TSBActiveSpoilerKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
            return;
        }
        TSBUpdateSpoilerBadge(self);
        if ([objc_getAssociatedObject(self, &TSBPreviewingOriginalKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), NO);
        } else if ([objc_getAssociatedObject(self, &TSBRemovalAnimationPlayedKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
        } else {
            TSBRegisterPendingSpoiler(self);
            TSBOriginalSetHidden(self, @selector(setHidden:), NO);
        }
        return;
    }
    TSBRevealCarouselSpoilersIfNeeded(self);
}

static void (*TSBOriginalLayoutSubviews)(id, SEL);
static void TSBHookedLayoutSubviews(UIView *self, SEL _cmd) {
    TSBOriginalLayoutSubviews(self, _cmd);
    TSBApplySpoilerPresentation(self);
    TSBRecordHierarchy(self);
    TSBCaptureSpoilerContext(self);
    if (TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey]) {
        if (![objc_getAssociatedObject(self, &TSBActiveSpoilerKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
            return;
        }
        TSBUpdateSpoilerBadge(self);
        if ([objc_getAssociatedObject(self, &TSBPreviewingOriginalKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), NO);
        } else if ([objc_getAssociatedObject(self, &TSBRemovalAnimationPlayedKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
        } else {
            TSBRegisterPendingSpoiler(self);
            TSBOriginalSetHidden(self, @selector(setHidden:), NO);
        }
        return;
    }
    TSBRevealCarouselSpoilersIfNeeded(self);
}

static void TSBHookedSetHidden(UIView *self, SEL _cmd, BOOL hidden) {
    TSBApplySpoilerPresentation(self);
    // Only app writes reach this hook. Plugin writes use the original IMP.
    [TSBTrackedSpoilerViews addObject:self];
    if ([objc_getAssociatedObject(self, &TSBPreviewingOriginalKey) boolValue]) {
        TSBOriginalSetHidden(self, _cmd, NO);
        return;
    }
    objc_setAssociatedObject(self, &TSBActiveSpoilerKey, @(!hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hidden) {
        TSBClearSpoilerBadge(self);
        [TSBPendingSpoilerViews removeObject:self];
        objc_setAssociatedObject(self, &TSBRemovalAnimationPlayedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TSBVisibleSampleCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TSBLastVisibleFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TSBOriginalSetHidden(self, _cmd, YES);
        return;
    }
    BOOL shouldForceHide = TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey];
    if (shouldForceHide) {
        BOOL isKnownSpoiler = [objc_getAssociatedObject(self, &TSBActiveSpoilerKey) boolValue];
        if (hidden && !isKnownSpoiler) {
            TSBClearSpoilerBadge(self);
            [TSBPendingSpoilerViews removeObject:self];
            TSBOriginalSetHidden(self, _cmd, YES);
            return;
        }
        if (!hidden) {
            objc_setAssociatedObject(self, &TSBActiveSpoilerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TSBUpdateSpoilerBadge(self);
        }
        TSBRegisterPendingSpoiler(self);
        TSBOriginalSetHidden(self, _cmd, [objc_getAssociatedObject(self, &TSBRemovalAnimationPlayedKey) boolValue]);
        return;
    }
    TSBOriginalSetHidden(self, _cmd, hidden);
    // Reveal every page belonging to this post after Threads restores a
    // reused carousel page, not only the page currently on screen.
    dispatch_async(dispatch_get_main_queue(), ^{
        TSBRevealCarouselSpoilersIfNeeded(self);
    });
}

@interface TSBPreferencesController : UITableViewController
@end

@implementation TSBPreferencesController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"劇透設定";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"SettingCell"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"劇透顯示" : @"進階設定";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"控制劇透內容與劇透標籤的顯示方式。";
    return @"一般情況不需要調整。遇到相容性問題時再開啟。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SettingCell" forIndexPath:indexPath];
    cell.accessoryView = nil;
    UISwitch *toggle = [UISwitch new];
    toggle.tag = indexPath.section == 0 ? (indexPath.row == 0 ? 0 : 3) : 1;
    toggle.on = toggle.tag == 0 ? TSBEnabled() : (toggle.tag == 1 ? [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey] : TSBShowBadge());
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.textLabel.text = toggle.tag == 0 ? @"自動顯示劇透內容" : (toggle.tag == 1 ? @"強制隱藏劇透區塊" : @"顯示劇透標籤");
    cell.accessoryView = toggle;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *key = toggle.tag == 0 ? TSBEnabledKey : (toggle.tag == 1 ? TSBForceHideContainerKey : TSBShowBadgeKey);
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:key];
    [NSUserDefaults.standardUserDefaults synchronize];
}

@end

static BOOL TSBIsSettingsController(UIViewController *controller) {
    if ([controller isKindOfClass:TSBPreferencesController.class]) {
        return NO;
    }
    NSString *title = controller.navigationItem.title ?: controller.title ?: @"";
    NSString *lowercaseTitle = title.lowercaseString;
    return [lowercaseTitle isEqualToString:@"settings"] ||
        [title containsString:@"設定"] ||
        [title containsString:@"设置"];
}

static void (*TSBOriginalViewDidAppear)(id, SEL, BOOL);
static void TSBHookedViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    TSBOriginalViewDidAppear(self, _cmd, animated);
    if (!TSBIsSettingsController(self) || objc_getAssociatedObject(self, &TSBSettingsButtonKey)) {
        return;
    }
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"劇透設定"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(tsb_openSpoilerBypass:)];
    NSMutableArray<UIBarButtonItem *> *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:item];
    self.navigationItem.rightBarButtonItems = items;
    objc_setAssociatedObject(self, &TSBSettingsButtonKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface UIViewController (ThreadsNoSpoiler)
- (void)tsb_openSpoilerBypass:(id)sender;
@end

@implementation UIViewController (ThreadsNoSpoiler)
- (void)tsb_openSpoilerBypass:(id)sender {
    [self.navigationController pushViewController:[TSBPreferencesController new] animated:YES];
}
@end

static void TSBInstallSpoilerHooks(void) {
    int classCount = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        NSString *name = NSStringFromClass(cls);
        if (![name containsString:@"BCNSpoilerView"] || [TSBHookedClasses containsObject:name]) {
            continue;
        }
        if (class_getInstanceMethod(cls, @selector(didMoveToWindow)) == NULL) {
            continue;
        }
        MSHookMessageEx(cls, @selector(didMoveToWindow), (IMP)TSBHookedDidMoveToWindow, (IMP *)&TSBOriginalDidMoveToWindow);
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)TSBHookedLayoutSubviews, (IMP *)&TSBOriginalLayoutSubviews);
        MSHookMessageEx(cls, @selector(setHidden:), (IMP)TSBHookedSetHidden, (IMP *)&TSBOriginalSetHidden);
        MSHookMessageEx(cls, @selector(setAlpha:), (IMP)TSBHookedSetAlpha, (IMP *)&TSBOriginalSetAlpha);
        [TSBHookedClasses addObject:name];
        TSBLog(@"hooked %@", name);
        // The original IMP storage is intentionally single-use: one concrete
        // BCNSpoilerView implementation owns the descendant masking hierarchy.
        break;
    }
    free(classes);
}

static void __attribute__((unused)) TSBInstallTimestampHooks(void) {
    SEL selector = NSSelectorFromString(@"timestampLabel");
    int classCount = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        NSString *name = NSStringFromClass(cls);
        // Threads sometimes changes the concrete header class. Select by the
        // actual timestampLabel implementation, never by label contents.
        BOOL isView = NO;
        for (Class current = cls; current; current = class_getSuperclass(current)) {
            if (current == UIView.class) { isView = YES; break; }
        }
        if (!isView || ![name containsString:@"BCN"] || [TSBTimestampHookedClasses containsObject:name]) {
            continue;
        }
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL definesTimestampGetter = NO;
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            if (method_getName(methods[methodIndex]) == selector) {
                definesTimestampGetter = YES;
                break;
            }
        }
        free(methods);
        if (!definesTimestampGetter) {
            continue;
        }
        IMP original = NULL;
        MSHookMessageEx(cls, selector, (IMP)TSBHookedTimestampLabel, &original);
        if (original) {
            TSBTimestampGetterIMPs[name] = [NSValue valueWithPointer:(const void *)original];
            [TSBTimestampHookedClasses addObject:name];
            TSBLog(@"hooked timestampLabel on %@", name);
        }
    }
    free(classes);
}

static void TSBInstallHeaderHooks(void) {
    int classCount = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        NSString *name = NSStringFromClass(cls);
        if (![name isEqualToString:@"BCNFeedItemHeaderCell.BCNFeedItemHeaderCell"] || [TSBHeaderHookedClasses containsObject:name]) {
            continue;
        }
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)TSBHookedHeaderLayoutSubviews, (IMP *)&TSBOriginalHeaderLayoutSubviews);
        [TSBHeaderHookedClasses addObject:name];
        TSBLog(@"hooked header metadata on %@", name);
        break;
    }
    free(classes);
}

%ctor {
    @autoreleasepool {
        TSBHookedClasses = [NSMutableSet set];
        TSBPendingSpoilerViews = [NSHashTable weakObjectsHashTable];
        TSBTrackedSpoilerViews = [NSHashTable weakObjectsHashTable];
        TSBObservedViewClasses = [NSMutableOrderedSet orderedSet];
        TSBLastSpoilerContext = [NSMutableOrderedSet orderedSet];
        TSBTimestampHookedClasses = [NSMutableSet set];
        TSBTimestampGetterIMPs = [NSMutableDictionary dictionary];
        TSBHeaderHookedClasses = [NSMutableSet set];
        NSTimer *visibilityTimer = [NSTimer timerWithTimeInterval:0.10 repeats:YES block:^(__unused NSTimer *timer) {
            TSBCheckPendingSpoilers();
        }];
        [NSRunLoop.mainRunLoop addTimer:visibilityTimer forMode:NSRunLoopCommonModes];
        MSHookMessageEx(UIViewController.class, @selector(viewDidAppear:), (IMP)TSBHookedViewDidAppear, (IMP *)&TSBOriginalViewDidAppear);
        MSHookMessageEx(UICollectionViewCell.class, @selector(didMoveToWindow), (IMP)TSBHookedCollectionCellDidMoveToWindow, (IMP *)&TSBOriginalCollectionCellDidMoveToWindow);
        MSHookMessageEx(UICollectionView.class, @selector(hitTest:withEvent:), (IMP)TSBHookedCollectionHitTest, (IMP *)&TSBOriginalCollectionHitTest);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TSBInstallSpoilerHooks();
            // Legacy timestamp getter hooks disabled; use the observed title identifier.
            TSBInstallHeaderHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TSBInstallSpoilerHooks();
            // Legacy timestamp getter hooks disabled; use the observed title identifier.
            TSBInstallHeaderHooks();
        });
    }
}
