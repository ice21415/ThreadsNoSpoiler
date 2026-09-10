#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString * const TSBEnabledKey = @"TSBEnabled";
static NSString * const TSBDebugKey = @"TSBDebugLogging";
static NSString * const TSBForceHideContainerKey = @"TSBForceHideContainer";
static NSString * const TSBShowBadgeKey = @"TSBShowSpoilerBadge";
static NSString * const TSBShowRemovalAnimationKey = @"TSBShowRemovalAnimation";
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
static NSMutableSet<NSString *> *TSBHookedClasses;
static NSHashTable<UIView *> *TSBPendingSpoilerViews;
static NSHashTable<UIView *> *TSBTrackedSpoilerViews;
static NSMutableOrderedSet<NSString *> *TSBObservedViewClasses;
static NSMutableOrderedSet<NSString *> *TSBLastSpoilerContext;
static NSMutableSet<NSString *> *TSBTimestampHookedClasses;
static NSMutableDictionary<NSString *, NSValue *> *TSBTimestampGetterIMPs;
static NSMutableSet<NSString *> *TSBHeaderHookedClasses;
static void (*TSBOriginalHeaderLayoutSubviews)(id, SEL);
static void (*TSBOriginalCollectionCellDidMoveToWindow)(id, SEL);
static void (*TSBOriginalSetHidden)(id, SEL, BOOL);

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

static BOOL TSBShowRemovalAnimation(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:TSBShowRemovalAnimationKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:TSBShowRemovalAnimationKey];
}

static void TSBLog(NSString *format, ...) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:TSBDebugKey]) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSLogv([@"[ThreadsNoSpoiler] " stringByAppendingString:format], arguments);
    va_end(arguments);
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

static BOOL TSBIsSpoilerMask(UIView *view) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    BOOL namedMask = [name containsString:@"spoiler"] &&
        ([name containsString:@"mask"] || [name containsString:@"overlay"] || [name containsString:@"blur"]);
    BOOL identifiedMask = [identifier containsString:@"spoiler"] || [identifier containsString:@"mask"];
    return namedMask || identifiedMask;
}

static void TSBHideDirectSpoilerLayers(UIView *container) {
    if (!TSBEnabled()) {
        return;
    }
    container.backgroundColor = UIColor.clearColor;
    container.userInteractionEnabled = NO;
    for (UIView *subview in container.subviews) {
        if ([subview isKindOfClass:UIVisualEffectView.class] || subview.class == UIView.class) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
            TSBLog(@"hid direct spoiler layer %@", NSStringFromClass(subview.class));
        }
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

static void TSBProcessHeaderCell(UIView *self) {
    UIView *metadataTextView = TSBHeaderMetadataTextView(self);
    UIView *post = TSBPostContainer(self);
    if (post && metadataTextView) {
        objc_setAssociatedObject(self, &TSBPostTimestampKey, metadataTextView, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void TSBHookedHeaderLayoutSubviews(UIView *self, SEL _cmd) {
    TSBOriginalHeaderLayoutSubviews(self, _cmd);
    TSBProcessHeaderCell(self);
}

static void TSBHookedCollectionCellDidMoveToWindow(UICollectionViewCell *self, SEL _cmd) {
    TSBOriginalCollectionCellDidMoveToWindow(self, _cmd);
    if ([NSStringFromClass(self.class) isEqualToString:@"BCNFeedItemHeaderCell.BCNFeedItemHeaderCell"]) {
        if (self.window == nil) {
            UILabel *badge = objc_getAssociatedObject(self, &TSBBadgeKey);
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
    UIView *anchor = header ? TSBHeaderMetadataTextView(header) : nil;
    // Drop the previous association before rebinding to a different header.
    if (objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey) != anchor) {
        TSBClearSpoilerBadge(spoilerView);
    }
    NSString *status = !TSBShowBadge() ? @"disabled in settings" : !cell ? @"no outer feed cell" : !header ? @"no preceding visible header/index path" : !anchor ? @"header title identifier missing" : @"anchor resolved; placement requested";
    objc_setAssociatedObject(spoilerView, &TSBBadgeStatusKey, status, OBJC_ASSOCIATION_COPY_NONATOMIC);
    TSBPlaceSpoilerBadge(spoilerView, anchor);
}

static void TSBClearSpoilerBadge(UIView *spoilerView) {
    UIView *anchor = objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey);
    UICollectionViewCell *header = TSBHeaderCellContainingView(anchor);
    NSHashTable *owners = header ? objc_getAssociatedObject(header, &TSBBadgeOwnerKey) : nil;
    if ([owners containsObject:spoilerView]) [owners removeObject:spoilerView];
    if (header != nil && owners.count == 0) {
        UILabel *badge = objc_getAssociatedObject(header, &TSBBadgeKey);
        [badge removeFromSuperview];
        objc_setAssociatedObject(header, &TSBBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(header, &TSBBadgeOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

@interface TSBSpoilerBadgeLabel : UILabel
@end

@implementation TSBSpoilerBadgeLabel
- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 10.0, size.height + 2.0);
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize fitted = [super sizeThatFits:size];
    return CGSizeMake(fitted.width + 10.0, fitted.height + 2.0);
}

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(1.0, 5.0, 1.0, 5.0))];
}
@end

// Direct path used when the header has identified the spoiler in its own
// following cells. It intentionally bypasses collection-wide lookup.
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *timestamp) {
    UICollectionViewCell *header = TSBHeaderCellContainingView(timestamp);
    UILabel *badge = header ? objc_getAssociatedObject(header, &TSBBadgeKey) : nil;
    if (!TSBShowBadge() || header == nil || timestamp == nil) {
        [badge removeFromSuperview];
        return;
    }
    if (badge == nil) {
        badge = [TSBSpoilerBadgeLabel new];
        badge.text = @"劇透";
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        badge.textColor = UIColor.systemOrangeColor;
        badge.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.16];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.lineBreakMode = NSLineBreakByClipping;
        badge.numberOfLines = 1;
        badge.layer.cornerRadius = 4.0;
        badge.clipsToBounds = YES;
        badge.translatesAutoresizingMaskIntoConstraints = YES;
        badge.userInteractionEnabled = NO;
        badge.accessibilityIdentifier = @"ThreadsNoSpoilerBadge";
        badge.accessibilityLabel = @"劇透貼文";
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
    CGSize size = badge.bounds.size;
    CGFloat x = CGRectGetMaxX(anchorFrame) + 4.0;
    CGFloat y = round(CGRectGetMidY(anchorFrame) - size.height / 2.0);
    CGRect targetFrame = CGRectMake(x, y, MAX(36.0, ceil(size.width)), MAX(17.0, ceil(size.height)));
    if (!CGRectEqualToRect(badge.frame, targetFrame)) {
        badge.frame = targetFrame;
    }
    objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, timestamp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    badge.hidden = NO;
}

static void TSBAnimateSpoilerRemoval(UIView *spoilerView) {
    if (!TSBEnabled() || !TSBShowRemovalAnimation() || spoilerView.superview == nil ||
        !TSBIsInVisibleViewport(spoilerView) ||
        [objc_getAssociatedObject(spoilerView, &TSBRemovalAnimationPlayedKey) boolValue]) {
        return;
    }

    // Removal motion is intentionally limited to inline text spoilers.
    UIView *textCell = spoilerView;
    while (textCell != nil &&
           ![NSStringFromClass(textCell.class) containsString:@"BCNFeedTextCell"]) {
        textCell = textCell.superview;
    }
    if (textCell == nil || spoilerView.bounds.size.width < 4.0 ||
        spoilerView.bounds.size.height < 4.0) {
        return;
    }

    UIView *host = TSBOuterFeedCell(spoilerView) ?: textCell;
    if (host.window == nil) {
        return;
    }
    CGRect targetFrame = [spoilerView convertRect:spoilerView.bounds toView:host];
    CGRect visibleFrame = CGRectIntersection(targetFrame, host.bounds);
    if (!CGRectIsNull(visibleFrame) && visibleFrame.size.width >= 4.0 && visibleFrame.size.height >= 4.0) {
        targetFrame = visibleFrame;
    }
    if (CGRectIsNull(targetFrame) || CGRectIsEmpty(targetFrame) ||
        !isfinite(targetFrame.origin.x) || !isfinite(targetFrame.origin.y) ||
        targetFrame.size.width < 4.0 || targetFrame.size.height < 4.0) {
        return;
    }

    // Preserve only the original inline spoiler surface before setHidden: reveals it.
    UIView *dissolveView = [[UIView alloc] initWithFrame:targetFrame];
    dissolveView.userInteractionEnabled = NO;
    dissolveView.clipsToBounds = YES;

    UIView *snapshot = [host resizableSnapshotViewFromRect:targetFrame
                                        afterScreenUpdates:NO
                                             withCapInsets:UIEdgeInsetsZero];
    if (snapshot == nil) {
        return;
    }
    snapshot.frame = dissolveView.bounds;
    snapshot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dissolveView addSubview:snapshot];

    CAGradientLayer *dissolveMask = [CAGradientLayer layer];
    dissolveMask.frame = dissolveView.bounds;
    dissolveMask.startPoint = CGPointMake(0.0, 0.5);
    dissolveMask.endPoint = CGPointMake(1.0, 0.5);
    dissolveMask.colors = @[(id)UIColor.clearColor.CGColor,
                            (id)UIColor.clearColor.CGColor,
                            (id)UIColor.blackColor.CGColor,
                            (id)UIColor.blackColor.CGColor];
    dissolveMask.locations = @[@(-0.20), @(-0.10), @(0.0), @(0.0)];
    dissolveView.layer.mask = dissolveMask;
    [host addSubview:dissolveView];
    objc_setAssociatedObject(spoilerView, &TSBRemovalAnimationPlayedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        CABasicAnimation *wipe = [CABasicAnimation animationWithKeyPath:@"locations"];
        wipe.fromValue = @[@(-0.20), @(-0.10), @(0.0), @(0.0)];
        wipe.toValue = @[@(0.90), @(1.0), @(1.10), @(1.20)];
        wipe.duration = 1.05;
        wipe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        dissolveMask.locations = @[@(0.90), @(1.0), @(1.10), @(1.20)];
        [dissolveMask addAnimation:wipe forKey:@"ThreadsNoSpoilerDissolve"];

        [UIView animateWithDuration:1.05 delay:0.0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            dissolveView.alpha = 0.30;
            dissolveView.transform = CGAffineTransformMakeTranslation(5.0, 0.0);
        } completion:^(__unused BOOL completed) {
            [dissolveView removeFromSuperview];
        }];
    });
}

static void TSBRegisterPendingSpoiler(UIView *spoilerView) {
    if (spoilerView != nil) {
        [TSBPendingSpoilerViews addObject:spoilerView];
    }
}

static void TSBCheckPendingSpoilers(void) {
    for (UIView *view in TSBTrackedSpoilerViews.allObjects) {
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

        NSValue *lastFrameValue = objc_getAssociatedObject(spoilerView, &TSBLastVisibleFrameKey);
        CGRect lastFrame = lastFrameValue ? lastFrameValue.CGRectValue : CGRectNull;
        BOOL positionStable = !CGRectIsNull(lastFrame) &&
            fabs(CGRectGetMinX(lastFrame) - CGRectGetMinX(frameInWindow)) < 0.5 &&
            fabs(CGRectGetMinY(lastFrame) - CGRectGetMinY(frameInWindow)) < 0.5 &&
            fabs(CGRectGetWidth(lastFrame) - CGRectGetWidth(frameInWindow)) < 0.5 &&
            fabs(CGRectGetHeight(lastFrame) - CGRectGetHeight(frameInWindow)) < 0.5;
        objc_setAssociatedObject(spoilerView, &TSBLastVisibleFrameKey,
                                 [NSValue valueWithCGRect:frameInWindow], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!positionStable) {
            objc_setAssociatedObject(spoilerView, &TSBVisibleSampleCountKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }

        NSInteger samples = [objc_getAssociatedObject(spoilerView, &TSBVisibleSampleCountKey) integerValue] + 1;
        objc_setAssociatedObject(spoilerView, &TSBVisibleSampleCountKey, @(samples), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Reveal after the fully visible text has stopped moving for about 1 second.
        if (samples < 10) {
            continue;
        }
        TSBAnimateSpoilerRemoval(spoilerView);
        objc_setAssociatedObject(spoilerView, &TSBRemovalAnimationPlayedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TSBOriginalSetHidden(spoilerView, @selector(setHidden:), YES);
        [TSBPendingSpoilerViews removeObject:spoilerView];
    }
}

static void TSBHideMasksBelowView(UIView *view) {
    if (!TSBEnabled()) {
        return;
    }
    for (UIView *subview in view.subviews) {
        TSBRecordView(subview);
        if (TSBIsSpoilerMask(subview)) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
            TSBLog(@"hid %@", NSStringFromClass(subview.class));
            continue;
        }
        TSBHideMasksBelowView(subview);
    }
}

static void (*TSBOriginalDidMoveToWindow)(id, SEL);
static void TSBHookedDidMoveToWindow(UIView *self, SEL _cmd) {
    TSBOriginalDidMoveToWindow(self, _cmd);
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
        if ([objc_getAssociatedObject(self, &TSBRemovalAnimationPlayedKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
        } else {
            TSBRegisterPendingSpoiler(self);
            TSBOriginalSetHidden(self, @selector(setHidden:), NO);
        }
        return;
    }
    TSBHideDirectSpoilerLayers(self);
    TSBHideMasksBelowView(self);
}

static void (*TSBOriginalLayoutSubviews)(id, SEL);
static void TSBHookedLayoutSubviews(UIView *self, SEL _cmd) {
    TSBOriginalLayoutSubviews(self, _cmd);
    TSBRecordHierarchy(self);
    TSBCaptureSpoilerContext(self);
    if (TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey]) {
        if (![objc_getAssociatedObject(self, &TSBActiveSpoilerKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
            return;
        }
        TSBUpdateSpoilerBadge(self);
        if ([objc_getAssociatedObject(self, &TSBRemovalAnimationPlayedKey) boolValue]) {
            TSBOriginalSetHidden(self, @selector(setHidden:), YES);
        } else {
            TSBRegisterPendingSpoiler(self);
            TSBOriginalSetHidden(self, @selector(setHidden:), NO);
        }
        return;
    }
    TSBHideDirectSpoilerLayers(self);
    TSBHideMasksBelowView(self);
}

static void TSBHookedSetHidden(UIView *self, SEL _cmd, BOOL hidden) {
    // Only app writes reach this hook. Plugin writes use the original IMP.
    [TSBTrackedSpoilerViews addObject:self];
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
}

@interface TSBPreferencesController : UITableViewController
@end

@implementation TSBPreferencesController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Spoiler Bypass";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"SettingCell"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    return section == 2 ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Display";
    if (section == 1) return @"Compatibility";
    return @"Diagnostics";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"When enabled, the tweak hides recognised Threads spoiler-mask views on this device.";
    if (section == 1) return @"Use only if automatic reveal does not work. It can hide the whole spoiler container instead of only its overlay.";
    return @"Show detected views after opening a spoiler post. This lets you report compatibility details without SSH.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SettingCell" forIndexPath:indexPath];
    cell.accessoryView = nil;
    if (indexPath.section == 2 && indexPath.row < 2) {
        cell.textLabel.text = indexPath.row == 0 ? @"Show detected spoiler views" : @"Show current spoiler post hierarchy";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    UISwitch *toggle = [UISwitch new];
    toggle.tag = indexPath.section == 0 ? (indexPath.row == 0 ? 0 : (indexPath.row == 1 ? 3 : 4)) : (indexPath.section == 1 ? 1 : 2);
    toggle.on = toggle.tag == 0 ? TSBEnabled() : (toggle.tag == 1 ? [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey] : (toggle.tag == 2 ? [NSUserDefaults.standardUserDefaults boolForKey:TSBDebugKey] : (toggle.tag == 3 ? TSBShowBadge() : TSBShowRemovalAnimation())));
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.textLabel.text = toggle.tag == 0 ? @"Automatically reveal spoilers" : (toggle.tag == 1 ? @"Force-hide spoiler container" : (toggle.tag == 2 ? @"Debug logging" : (toggle.tag == 3 ? @"Show spoiler badge" : @"Show removal animation")));
    cell.accessoryView = toggle;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *key = toggle.tag == 0 ? TSBEnabledKey : (toggle.tag == 1 ? TSBForceHideContainerKey : (toggle.tag == 2 ? TSBDebugKey : (toggle.tag == 3 ? TSBShowBadgeKey : TSBShowRemovalAnimationKey)));
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:key];
    [NSUserDefaults.standardUserDefaults synchronize];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 2 || indexPath.row > 1) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BOOL showingContext = indexPath.row == 1;
    NSArray<NSString *> *entries = showingContext ? TSBLastSpoilerContext.array : TSBObservedViewClasses.array;
    NSString *message = entries.count ? [entries componentsJoinedByString:@"\n"] : @"No spoiler view has been detected yet. Open a post with a spoiler first, then return here.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(showingContext ? @"Current spoiler post hierarchy" : @"Detected spoiler views") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = message;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL TSBIsSettingsController(UIViewController *controller) {
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
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"Spoiler Bypass"
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
