#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "TSBFooterLayout.h"

static NSString * const TSBEnabledKey = @"TSBEnabled";
static NSString * const TSBForceHideContainerKey = @"TSBForceHideContainer";
static NSString * const TSBShowBadgeKey = @"TSBShowSpoilerBadge";
static char TSBSettingsButtonKey;
static char TSBBadgeKey;
static char TSBBadgeStatusKey;
static char TSBLastResolutionKey;
static char TSBBadgeAnchorKey;
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
static NSMutableArray<NSString *> *TSBLifecycleEvents;
static NSMutableSet<NSString *> *TSBFooterHookedClasses;
static void (*TSBOriginalFooterLayoutSubviews)(id, SEL);
static void (*TSBOriginalFooterPrepareForReuse)(id, SEL);
static void (*TSBOriginalCollectionCellDidMoveToWindow)(id, SEL);
static void (*TSBOriginalCollectionCellPrepareForReuse)(id, SEL);
static void (*TSBOriginalSetHidden)(id, SEL, BOOL);
static void (*TSBOriginalSetAlpha)(id, SEL, CGFloat);
static char TSBRequestedAlphaKey;
static char TSBNativeMaskSeenKey;
static char TSBPostIdentifierKey;
static void TSBUpdateSpoilerBadge(UIView *spoilerView);
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *share);
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
    if (!preview && ![objc_getAssociatedObject(view, &TSBActiveSpoilerKey) boolValue]) return;
    CGFloat originalAlpha = requested ? requested.doubleValue : 1.0;
    CGFloat alpha = preview ? originalAlpha : TSBEnabled() ? 0.0 : originalAlpha;
    TSBOriginalSetAlpha(view, @selector(setAlpha:), alpha);
}

static BOOL TSBHasNativeMaskPresentation(UIView *view) {
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:view];
    while (pending.count) {
        UIView *candidate = pending.lastObject;
        [pending removeLastObject];
        NSString *name = NSStringFromClass(candidate.class);
        if ([candidate isKindOfClass:UIVisualEffectView.class] ||
            [name containsString:@"SpoilerMask"] || [name containsString:@"VisualEffectBackdrop"]) return YES;
        [pending addObjectsFromArray:candidate.subviews];
    }
    return NO;
}

static void TSBHookedSetAlpha(UIView *self, SEL _cmd, CGFloat alpha) {
    objc_setAssociatedObject(self, &TSBRequestedAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // This is the final app-generated mask presentation result. Once seen,
    // retain it through layout/reuse transitions until the source cell itself
    // is explicitly reused.
    if (alpha > 0.01 && TSBHasNativeMaskPresentation(self)) {
        objc_setAssociatedObject(self, &TSBNativeMaskSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TSBActiveSpoilerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    TSBApplySpoilerPresentation(self);
}

static void TSBLog(NSString *format, ...) {
    if (!TSBLifecycleEvents) TSBLifecycleEvents = [NSMutableArray array];
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [TSBLifecycleEvents addObject:[NSString stringWithFormat:@"%.3f %@",
        NSProcessInfo.processInfo.systemUptime, message]];
    if (TSBLifecycleEvents.count > 250) [TSBLifecycleEvents removeObjectAtIndex:0];
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
    UICollectionViewCell *fallback = nil;
    for (NSUInteger depth = 0; view && depth < 30; depth++, view = view.superview) {
        if ([view isKindOfClass:UICollectionViewCell.class] &&
            [view.superview isKindOfClass:UICollectionView.class]) {
            // Detail screens may use a different collection subclass.
            fallback = (UICollectionViewCell *)view;
        }
        if ([view isKindOfClass:UICollectionViewCell.class] &&
            [NSStringFromClass(view.superview.class) containsString:@"BCNFeedCollectionView"]) {
            return (UICollectionViewCell *)view;
        }
    }
    return fallback;
}

// A collection is only a rendering surface: it can contain several independent
// posts, quoted posts and recycled cells.  The model post ID is the only safe
// ownership key for a spoiler view and its UFI footer.
static NSString *TSBIdentifierString(id value) {
    if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    return nil;
}

static id TSBObjectGetter(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *TSBPostIdentifierForCell(UICollectionViewCell *cell) {
    if (!cell) return nil;
    NSString *cached = objc_getAssociatedObject(cell, &TSBPostIdentifierKey);
    if (cached.length) return cached;

    NSMutableArray<id> *pending = [NSMutableArray arrayWithObject:cell];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSArray<NSString *> *postGetters = @[@"postId", @"postID"];
    NSArray<NSString *> *modelGetters = @[@"viewModel", @"model", @"cellContext", @"context",
                                         @"fragment", @"item", @"configuration", @"data"];
    for (NSUInteger inspected = 0; pending.count && inspected < 80; inspected++) {
        id object = pending.lastObject;
        [pending removeLastObject];
        if (!object) continue;
        NSValue *address = [NSValue valueWithPointer:(__bridge const void *)object];
        if ([seen containsObject:address]) continue;
        [seen addObject:address];

        for (NSString *getter in postGetters) {
            NSString *postID = TSBIdentifierString(TSBObjectGetter(object, getter));
            if (postID.length) {
                objc_setAssociatedObject(cell, &TSBPostIdentifierKey, postID, OBJC_ASSOCIATION_COPY_NONATOMIC);
                return postID;
            }
        }
        for (Class cls = object_getClass(object); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int index = 0; index < count; index++) {
                Ivar ivar = ivars[index];
                const char *type = ivar_getTypeEncoding(ivar);
                if (!type || type[0] != '@') continue;
                NSString *name = @(ivar_getName(ivar));
                NSString *lowercase = name.lowercaseString;
                BOOL namedPostID = [lowercase containsString:@"postid"];
                BOOL namedModelField = [lowercase containsString:@"model"] ||
                    [lowercase containsString:@"context"] || [lowercase containsString:@"fragment"] ||
                    [lowercase containsString:@"viewmodel"] || [lowercase containsString:@"configuration"];
                id value = object_getIvar(object, ivar);
                if (namedPostID) {
                    NSString *postID = TSBIdentifierString(value);
                    if (postID.length) {
                        free(ivars);
                        objc_setAssociatedObject(cell, &TSBPostIdentifierKey, postID, OBJC_ASSOCIATION_COPY_NONATOMIC);
                        return postID;
                    }
                }
                if (value && (namedModelField || ([lowercase containsString:@"item"] ||
                              [lowercase containsString:@"post"] || [lowercase containsString:@"data"]))) {
                    [pending addObject:value];
                }
            }
            free(ivars);
        }
        for (NSString *getter in modelGetters) {
            id value = TSBObjectGetter(object, getter);
            if (value && ![value isKindOfClass:UIView.class]) [pending addObject:value];
        }
    }
    return nil;
}

static UICollectionViewCell *TSBFooterForPostIdentifier(UICollectionViewCell *source, NSString *postID) {
    if (!source || !postID.length) return nil;
    if (TSBIsFooterCell(source) && [TSBPostIdentifierForCell(source) isEqualToString:postID]) return source;
    UICollectionView *collection = [source.superview isKindOfClass:UICollectionView.class] ?
        (UICollectionView *)source.superview : nil;
    NSIndexPath *sourceIndex = collection ? [collection indexPathForCell:source] : nil;
    if (!sourceIndex) return nil;
    for (UICollectionViewCell *candidate in collection.visibleCells) {
        NSIndexPath *index = [collection indexPathForCell:candidate];
        if (!index || index.section != sourceIndex.section || index.item <= sourceIndex.item || !TSBIsFooterCell(candidate)) continue;
        if ([[TSBPostIdentifierForCell(candidate) description] isEqualToString:postID]) return candidate;
    }
    return nil;
}

static void TSBAppendHeaderTree(UIView *view, NSUInteger depth) {
    if (TSBLastSpoilerContext.count >= 120 || depth > 12) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    CGRect frame = view.frame;
    [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"%@header-tree %@ id:%@ frame:(%.0f,%.0f,%.0f,%.0f) children:%lu",
        indent, NSStringFromClass(view.class), view.accessibilityIdentifier ?: @"(none)", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
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
                // Record field names/types, never read model values or post text.
                for (Class cls = cell.class; cls && cls != UICollectionViewCell.class;
                     cls = class_getSuperclass(cls)) {
                    unsigned int count = 0;
                    Ivar *ivars = class_copyIvarList(cls, &count);
                    for (unsigned int i = 0; i < count && TSBLastSpoilerContext.count < 100; i++) {
                        const char *type = ivar_getTypeEncoding(ivars[i]);
                        [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"  field %@.%s type:%s",
                            NSStringFromClass(cls), ivar_getName(ivars[i]), type ?: "?"]];
                    }
                    free(ivars);
                }
                for (UIView *child in cell.subviews) {
                    if (TSBLastSpoilerContext.count >= 120) break;
                    [TSBLastSpoilerContext addObject:[NSString stringWithFormat:@"  cell-child %@ (children: %lu)",
                        NSStringFromClass(child.class), (unsigned long)child.subviews.count]];
                }
                if ([NSStringFromClass(cell.class) containsString:@"BCNFeedItemHeaderCell"] || TSBIsFooterCell(cell)) {
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

static BOOL TSBProcessSpoilerOwner(UIView *spoilerView) {
    if (![objc_getAssociatedObject(spoilerView, &TSBNativeMaskSeenKey) boolValue]) return NO;
    TSBApplySpoilerPresentation(spoilerView);
    TSBUpdateSpoilerBadge(spoilerView);
    return YES;
}

static void TSBClearFooterCell(UICollectionViewCell *cell) {
    TSBRestoreFooterShare(cell);
    NSHashTable *owners = objc_getAssociatedObject(cell, &TSBBadgeOwnerKey);
    UIButton *badge = objc_getAssociatedObject(cell, &TSBBadgeKey);
    if (badge) TSBLog(@"clear footer=%p class=%@ window=%d owners=%lu", cell,
        NSStringFromClass(cell.class), cell.window != nil, (unsigned long)owners.count);
    [badge sendActionsForControlEvents:UIControlEventTouchCancel];
    for (UIView *owner in owners.allObjects) {
        UIView *anchor = objc_getAssociatedObject(owner, &TSBBadgeAnchorKey);
        if (TSBOuterFeedCell(anchor) == cell)
            objc_setAssociatedObject(owner, &TSBBadgeAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [badge removeFromSuperview];
    objc_setAssociatedObject(cell, &TSBBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &TSBBadgeOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TSBRefreshFooterCell(UICollectionViewCell *cell) {
    NSString *footerPostID = TSBPostIdentifierForCell(cell);
    if (!footerPostID.length) return;
    // Footer visibility can begin after the source spoiler's last layout pass,
    // but never let an adjacent post refresh this footer.
    for (UIView *owner in TSBTrackedSpoilerViews.allObjects) {
        UICollectionViewCell *source = TSBOuterFeedCell(owner);
        if ([[TSBPostIdentifierForCell(source) description] isEqualToString:footerPostID]) TSBUpdateSpoilerBadge(owner);
    }
}

static void TSBHookedFooterLayoutSubviews(UICollectionViewCell *self, SEL cmd) {
    TSBRestoreFooterShare(self);
    TSBOriginalFooterLayoutSubviews(self, cmd);
    TSBRefreshFooterCell(self);
}

static void TSBHookedFooterPrepareForReuse(UICollectionViewCell *self, SEL cmd) {
    TSBClearFooterCell(self);
    TSBOriginalFooterPrepareForReuse(self, cmd);
}

static void TSBHookedCollectionCellDidMoveToWindow(UICollectionViewCell *self, SEL cmd) {
    TSBOriginalCollectionCellDidMoveToWindow(self, cmd);
    if (!TSBIsFooterCell(self)) return;
    // A footer can leave the window while the same post's media or text cell
    // remains visible. prepareForReuse is the definitive reuse signal.
    if (self.window) TSBRefreshFooterCell(self);
}

static void TSBHookedCollectionCellPrepareForReuse(UICollectionViewCell *self, SEL cmd) {
    // Detaching from a window is not reuse. Reset identity only when UIKit
    // explicitly recycles the cell, including source cells and embedded UFI.
    for (UIView *owner in TSBTrackedSpoilerViews.allObjects) {
        if (![owner isDescendantOfView:self]) continue;
        TSBLog(@"reuse source=%p class=%@ spoiler=%p", self, NSStringFromClass(self.class), owner);
        TSBClearSpoilerBadge(owner);
        if ([objc_getAssociatedObject(owner, &TSBRemovalAnimationPlayedKey) boolValue])
            TSBOriginalSetHidden(owner, @selector(setHidden:), NO);
        objc_setAssociatedObject(owner, &TSBActiveSpoilerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(owner, &TSBNativeMaskSeenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(owner, &TSBRemovalAnimationPlayedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [TSBPendingSpoilerViews removeObject:owner];
        [TSBTrackedSpoilerViews removeObject:owner];
    }
    TSBClearFooterCell(self);
    objc_setAssociatedObject(self, &TSBPostIdentifierKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TSBOriginalCollectionCellPrepareForReuse(self, cmd);
}

static void TSBUpdateSpoilerBadge(UIView *spoilerView) {
    if (!TSBEnabled() || !TSBShowBadge() ||
        ![objc_getAssociatedObject(spoilerView, &TSBActiveSpoilerKey) boolValue]) {
        TSBClearSpoilerBadge(spoilerView);
        return;
    }
    // Temporary detachment/zero-size layout of the text does not invalidate
    // an existing footer. Actual reuse and footer removal still clear it.
    if (!spoilerView.window || spoilerView.bounds.size.width < 4 ||
        spoilerView.bounds.size.height < 4) return;
    UICollectionViewCell *source = TSBOuterFeedCell(spoilerView);
    NSString *postID = TSBPostIdentifierForCell(source);
    UICollectionViewCell *footer = postID.length ? TSBFooterForPostIdentifier(source, postID) : nil;
    UIView *share = footer ? TSBFooterShareButton(footer) : nil;
    if (share && objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey) != share)
        TSBClearSpoilerBadge(spoilerView);
    NSString *status = !source ? @"no source feed cell" : !postID.length ? @"waiting for source post ID" : !footer ? @"waiting for matching post-ID footer" :
        !share ? @"waiting for visible share button" : @"footer share anchor resolved";
    if (![objc_getAssociatedObject(spoilerView, &TSBLastResolutionKey) isEqual:status])
        TSBLog(@"resolve spoiler=%p source=%p footer=%p share=%p %@", spoilerView, source, footer, share, status);
    objc_setAssociatedObject(spoilerView, &TSBLastResolutionKey, status, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(spoilerView, &TSBBadgeStatusKey, status, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (share) TSBPlaceSpoilerBadge(spoilerView, share);
}

static void TSBClearSpoilerBadge(UIView *spoilerView) {
    UIView *anchor = objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey);
    UICollectionViewCell *cell = TSBOuterFeedCell(anchor);
    NSHashTable *owners = cell ? objc_getAssociatedObject(cell, &TSBBadgeOwnerKey) : nil;
    if ([objc_getAssociatedObject(spoilerView, &TSBPreviewingOriginalKey) boolValue]) {
        UIButton *badge = objc_getAssociatedObject(cell, &TSBBadgeKey);
        [badge sendActionsForControlEvents:UIControlEventTouchCancel];
    }
    if ([owners containsObject:spoilerView]) [owners removeObject:spoilerView];
    if (cell && owners.count == 0) TSBClearFooterCell(cell);
    objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface TSBSpoilerBadgeButton : UIButton
@property (nonatomic, weak) UICollectionViewCell *owningCell;
- (void)tsb_beginOriginalPreview:(id)sender;
- (void)tsb_endOriginalPreview:(id)sender;
@end

@implementation TSBSpoilerBadgeButton
- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    return CGRectInset(contentRect, 3.0, 2.0);
}
- (void)tsb_setOriginalPreviewVisible:(BOOL)showingOriginal {
    NSHashTable<UIView *> *owners = objc_getAssociatedObject(self.owningCell, &TSBBadgeOwnerKey);
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

// One badge per footer, with only that post's spoiler views as preview owners.
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *share) {
    UICollectionViewCell *footer = TSBOuterFeedCell(share);
    if (!TSBIsFooterCell(footer) || !TSBShowBadge()) return;
    TSBSpoilerBadgeButton *badge = objc_getAssociatedObject(footer, &TSBBadgeKey);
    if (!badge) {
        badge = [TSBSpoilerBadgeButton buttonWithType:UIButtonTypeCustom];
        [badge setTitle:@"劇透" forState:UIControlStateNormal];
        [badge setTitleColor:UIColor.systemOrangeColor forState:UIControlStateNormal];
        badge.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.16];
        badge.layer.cornerRadius = 6.0;
        badge.translatesAutoresizingMaskIntoConstraints = YES;
        badge.exclusiveTouch = YES;
        badge.accessibilityIdentifier = @"ThreadsNoSpoilerBadge";
        badge.accessibilityLabel = @"劇透貼文";
        badge.accessibilityHint = @"按住可查看原始防劇透遮罩";
        badge.titleLabel.numberOfLines = 1;
        badge.titleLabel.textAlignment = NSTextAlignmentCenter;
        [badge addTarget:badge action:@selector(tsb_beginOriginalPreview:)
          forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [badge addTarget:badge action:@selector(tsb_endOriginalPreview:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel | UIControlEventTouchDragExit];
        objc_setAssociatedObject(footer, &TSBBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    badge.owningCell = footer;
    NSHashTable *owners = objc_getAssociatedObject(footer, &TSBBadgeOwnerKey);
    if (!owners) {
        owners = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(footer, &TSBBadgeOwnerKey, owners, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [owners addObject:spoilerView];
    objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, share, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL placed = TSBLayoutFooterBadge(footer, share, badge);
    objc_setAssociatedObject(spoilerView, &TSBBadgeStatusKey,
        placed ? @"footer trailing edge, right of share" : @"waiting for footer trailing space",
        OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!placed) [badge removeFromSuperview];
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

static void TSBRevealCarouselSpoilersIfNeeded(UIView *spoilerView) {
    if (!TSBEnabled() ||
        [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey] ||
        spoilerView.window == nil ||
        [objc_getAssociatedObject(spoilerView, &TSBPreviewingOriginalKey) boolValue]) {
        return;
    }
    // Each carousel page receives its own lifecycle call.  Walking the shared
    // collection here merges neighboring posts and creates false badges.
    TSBProcessSpoilerOwner(spoilerView);
}

static void (*TSBOriginalDidMoveToWindow)(id, SEL);
static void TSBHookedDidMoveToWindow(UIView *self, SEL _cmd) {
    TSBOriginalDidMoveToWindow(self, _cmd);
    TSBApplySpoilerPresentation(self);
    if (self.window == nil) {
        TSBLog(@"detach spoiler=%p active=%d anchor=%p", self,
            [objc_getAssociatedObject(self, &TSBActiveSpoilerKey) boolValue],
            objc_getAssociatedObject(self, &TSBBadgeAnchorKey));
        objc_setAssociatedObject(self, &TSBVisibleSampleCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TSBLastVisibleFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [TSBPendingSpoilerViews removeObject:self];
        return;
    }
    TSBRecordHierarchy(self);
    TSBCaptureSpoilerContext(self);
    [TSBTrackedSpoilerViews addObject:self];
    if (objc_getAssociatedObject(self, &TSBActiveSpoilerKey) == nil) {
        objc_setAssociatedObject(self, &TSBActiveSpoilerKey,
            @([objc_getAssociatedObject(self, &TSBNativeMaskSeenKey) boolValue]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    // Hooks can be installed after didMoveToWindow has already occurred.
    if (self.window) {
        [TSBTrackedSpoilerViews addObject:self];
        if (objc_getAssociatedObject(self, &TSBActiveSpoilerKey) == nil)
            objc_setAssociatedObject(self, &TSBActiveSpoilerKey,
                @([objc_getAssociatedObject(self, &TSBNativeMaskSeenKey) boolValue]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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
    BOOL wasActive = [objc_getAssociatedObject(self, &TSBActiveSpoilerKey) boolValue];
    if (!hidden && [objc_getAssociatedObject(self, &TSBNativeMaskSeenKey) boolValue]) {
        objc_setAssociatedObject(self, &TSBActiveSpoilerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hidden) {
        [TSBPendingSpoilerViews removeObject:self];
        objc_setAssociatedObject(self, &TSBVisibleSampleCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &TSBLastVisibleFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Threads briefly hides the spoiler overlay after its reveal pass.
        // Keep the post marked active, and therefore keep its footer badge,
        // until the view actually leaves the window or its cell is reused.
        if (wasActive) TSBUpdateSpoilerBadge(self);
        else {
            TSBClearSpoilerBadge(self);
            objc_setAssociatedObject(self, &TSBRemovalAnimationPlayedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        TSBOriginalSetHidden(self, _cmd, YES);
        return;
    }
    BOOL shouldForceHide = TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey];
    if (shouldForceHide) {
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"匯出診斷" style:UIBarButtonItemStylePlain
        target:self action:@selector(tsb_exportDiagnostics:)];
}

- (void)tsb_exportDiagnostics:(id)sender {
    NSString *report = [NSString stringWithFormat:
        @"ThreadsNoSpoiler 0.1.50\nApp: %@\n\nLifecycle\n%@\n\nLast source hierarchy\n%@\n\nObserved classes\n%@",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [TSBLifecycleEvents componentsJoinedByString:@"\n"],
        [TSBLastSpoilerContext.array componentsJoinedByString:@"\n"],
        [TSBObservedViewClasses.array componentsJoinedByString:@"\n"]];
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[report] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:share animated:YES completion:nil];
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
    if (toggle.tag == 1 && !toggle.on) {
        // "Force hide" may have hidden an existing container through the
        // original UIKit setter.  Changing the preference alone does not
        // cause Threads to lay those cells out again, so restore each tracked
        // container immediately and let the safe alpha-based bypass apply.
        for (UIView *spoiler in TSBTrackedSpoilerViews.allObjects) {
            [TSBPendingSpoilerViews removeObject:spoiler];
            objc_setAssociatedObject(spoiler, &TSBRemovalAnimationPlayedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TSBOriginalSetHidden(spoiler, @selector(setHidden:), NO);
            TSBApplySpoilerPresentation(spoiler);
            TSBRevealCarouselSpoilersIfNeeded(spoiler);
        }
    }
    if (!TSBEnabled() || !TSBShowBadge()) {
        for (UIView *spoiler in TSBTrackedSpoilerViews.allObjects) TSBClearSpoilerBadge(spoiler);
    }
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
        // Seed views that were already on screen before the delayed hook
        // installation; their first didMoveToWindow event was missed.
        NSMutableArray<UIView *> *pending = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class])
                [pending addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        while (pending.count) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            [pending addObjectsFromArray:view.subviews];
            if (![view isKindOfClass:cls]) continue;
            [TSBTrackedSpoilerViews addObject:view];
            if (objc_getAssociatedObject(view, &TSBActiveSpoilerKey) == nil)
                objc_setAssociatedObject(view, &TSBActiveSpoilerKey,
                    @([objc_getAssociatedObject(view, &TSBNativeMaskSeenKey) boolValue]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TSBApplySpoilerPresentation(view);
            TSBUpdateSpoilerBadge(view);
        }
        TSBLog(@"hooked %@", name);
        // The original IMP storage is intentionally single-use: one concrete
        // BCNSpoilerView implementation owns the descendant masking hierarchy.
        break;
    }
    free(classes);
}

static void TSBInstallFooterHooks(void) {
    int classCount = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        NSString *name = NSStringFromClass(cls);
        if (![name containsString:@"BCNFeedItemUFICell"] || [TSBFooterHookedClasses containsObject:name]) continue;
        MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)TSBHookedFooterLayoutSubviews,
                        (IMP *)&TSBOriginalFooterLayoutSubviews);
        MSHookMessageEx(cls, @selector(prepareForReuse), (IMP)TSBHookedFooterPrepareForReuse,
                        (IMP *)&TSBOriginalFooterPrepareForReuse);
        [TSBFooterHookedClasses addObject:name];
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
        TSBFooterHookedClasses = [NSMutableSet set];
        NSTimer *visibilityTimer = [NSTimer timerWithTimeInterval:0.10 repeats:YES block:^(__unused NSTimer *timer) {
            TSBCheckPendingSpoilers();
        }];
        [NSRunLoop.mainRunLoop addTimer:visibilityTimer forMode:NSRunLoopCommonModes];
        MSHookMessageEx(UIViewController.class, @selector(viewDidAppear:), (IMP)TSBHookedViewDidAppear, (IMP *)&TSBOriginalViewDidAppear);
        MSHookMessageEx(UICollectionViewCell.class, @selector(didMoveToWindow), (IMP)TSBHookedCollectionCellDidMoveToWindow, (IMP *)&TSBOriginalCollectionCellDidMoveToWindow);
        MSHookMessageEx(UICollectionViewCell.class, @selector(prepareForReuse), (IMP)TSBHookedCollectionCellPrepareForReuse, (IMP *)&TSBOriginalCollectionCellPrepareForReuse);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TSBInstallSpoilerHooks();
            TSBInstallFooterHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TSBInstallSpoilerHooks();
            TSBInstallFooterHooks();
        });
    }
}
