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
static NSMutableSet<NSString *> *TSBFooterHookedClasses;
static void (*TSBOriginalFooterLayoutSubviews)(id, SEL);
static void (*TSBOriginalFooterPrepareForReuse)(id, SEL);
static void (*TSBOriginalCollectionCellDidMoveToWindow)(id, SEL);
static void (*TSBOriginalSetHidden)(id, SEL, BOOL);
static void (*TSBOriginalSetAlpha)(id, SEL, CGFloat);
static char TSBRequestedAlphaKey;
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

static void TSBClearFooterCell(UICollectionViewCell *cell) {
    NSHashTable *owners = objc_getAssociatedObject(cell, &TSBBadgeOwnerKey);
    UIButton *badge = objc_getAssociatedObject(cell, &TSBBadgeKey);
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
    // Footer visibility can begin after the source spoiler's last layout pass.
    for (UIView *owner in TSBTrackedSpoilerViews.allObjects) {
        UICollectionViewCell *source = TSBOuterFeedCell(owner);
        if (source.superview == cell.superview) TSBUpdateSpoilerBadge(owner);
    }
}

static void TSBHookedFooterLayoutSubviews(UICollectionViewCell *self, SEL cmd) {
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
    if (!self.window) TSBClearFooterCell(self);
    else TSBRefreshFooterCell(self);
}

static void TSBUpdateSpoilerBadge(UIView *spoilerView) {
    if (!TSBEnabled() || !TSBShowBadge() ||
        ![objc_getAssociatedObject(spoilerView, &TSBActiveSpoilerKey) boolValue] ||
        spoilerView.bounds.size.width < 4 || spoilerView.bounds.size.height < 4) {
        TSBClearSpoilerBadge(spoilerView);
        return;
    }
    UICollectionViewCell *source = TSBOuterFeedCell(spoilerView);
    UICollectionViewCell *footer = source ? TSBFooterForFeedCell(source) : nil;
    UIView *share = footer && TSBIsInVisibleViewport(footer) ? TSBFooterShareButton(footer) : nil;
    if (objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey) != share)
        TSBClearSpoilerBadge(spoilerView);
    NSString *status = !source ? @"no source feed cell" : !footer ? @"waiting for this post's footer" :
        !share ? @"waiting for visible share button" : @"footer share anchor resolved";
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
        TSBLog(@"hooked %@", name);
        // The original IMP storage is intentionally single-use: one concrete
        // BCNSpoilerView implementation owns the descendant masking hierarchy.
        break;
    }
    free(classes);
}

static void TSBInstallFooterHooks(void) {
    Class cls = NSClassFromString(@"BCNFeedItemUFICell.BCNFeedItemUFICell");
    NSString *name = cls ? NSStringFromClass(cls) : nil;
    if (!cls || [TSBFooterHookedClasses containsObject:name]) return;
    MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)TSBHookedFooterLayoutSubviews,
                    (IMP *)&TSBOriginalFooterLayoutSubviews);
    MSHookMessageEx(cls, @selector(prepareForReuse), (IMP)TSBHookedFooterPrepareForReuse,
                    (IMP *)&TSBOriginalFooterPrepareForReuse);
    [TSBFooterHookedClasses addObject:name];
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
