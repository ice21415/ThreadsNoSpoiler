#import "TSBFooterLayout.h"
#import "TSBFooterGeometry.h"
#import <objc/message.h>
#include <vector>

@interface TSBFooterShareState : NSObject
@property (nonatomic, weak) UIView *share;
@property (nonatomic) CGPoint originalCenter;
@property (nonatomic) CGPoint appliedCenter;
@end
@implementation TSBFooterShareState
@end
static char TSBFooterShareStateKey;

static UIView *TSBFindUFIView(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([NSStringFromClass(view.class) containsString:@"BCNUFIView"]) return view;
        [pending addObjectsFromArray:view.subviews];
    }
    return nil;
}

BOOL TSBIsFooterCell(UIView *view) {
    if (![view isKindOfClass:UICollectionViewCell.class]) return NO;
    return [NSStringFromClass(view.class) containsString:@"BCNFeedItemUFICell"] ||
        TSBFindUFIView(view) != nil;
}

void TSBRestoreFooterShare(UICollectionViewCell *footer) {
    TSBFooterShareState *state = objc_getAssociatedObject(footer, &TSBFooterShareStateKey);
    if (!state) return;
    if (state.share && CGPointEqualToPoint(state.share.center, state.appliedCenter))
        state.share.center = state.originalCenter;
    objc_setAssociatedObject(footer, &TSBFooterShareStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UICollectionViewCell *TSBFooterForFeedCell(UICollectionViewCell *source) {
    UICollectionView *collection = [source.superview isKindOfClass:UICollectionView.class] ?
        (UICollectionView *)source.superview : nil;
    if (!collection || ![collection indexPathForCell:source]) return nil;
    // Some feed layouts embed BCNUFIView in the same cell as the post body.
    if (TSBFindUFIView(source)) return source;
    CGRect sourceFrame = [source convertRect:source.bounds toView:collection];
    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    std::vector<TSBVisualRow> rows;
    for (UICollectionViewCell *cell in collection.visibleCells) {
        NSIndexPath *index = [collection indexPathForCell:cell];
        if (!index) continue;
        BOOL header = [NSStringFromClass(cell.class) containsString:@"BCNFeedItemHeaderCell"];
        CGRect frame = [cell convertRect:cell.bounds toView:collection];
        rows.push_back({CGRectGetMinY(frame), CGRectGetMaxY(frame), (bool)header, (bool)TSBIsFooterCell(cell)});
        [cells addObject:cell];
    }
    int match = TSBFindVisualFooter(CGRectGetMinY(sourceFrame), rows.data(), rows.size());
    return match >= 0 ? cells[(NSUInteger)match] : nil;
}

static BOOL TSBVisibleInFooter(UIView *view, UIView *footer) {
    if (!view || ![view isDescendantOfView:footer] || CGRectIsEmpty(view.bounds)) return NO;
    for (UIView *current = view; current; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) return NO;
        if (current == footer) return YES;
    }
    return NO;
}

UIView *TSBFooterShareButton(UICollectionViewCell *footer) {
    if (!TSBIsFooterCell(footer)) return nil;
    UIView *ufi = TSBFindUFIView(footer);
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:ufi ?: footer];
    UIView *named = nil;
    UIView *rightmostUFI = nil;
    UIView *rightmostControl = nil;
    CGFloat rightmostX = -CGFLOAT_MAX;
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.01 ||
            [view.accessibilityIdentifier isEqualToString:@"ThreadsNoSpoilerBadge"]) continue;
        [pending addObjectsFromArray:view.subviews];
        NSString *className = NSStringFromClass(view.class);
        // Use observed selector names only on the UFI container, never KVC on
        // arbitrary views. The return type must be an Objective-C object.
        if ([className containsString:@"BCNUFIView"] || view == footer) {
            // Current Threads bundle exposes the paper plane as sendButton
            // (IGUFIButton) and stores it in _sendButtonContainer.
            for (NSString *getter in @[@"sendButton", @"shareButton"]) {
                SEL selector = NSSelectorFromString(getter);
                if (![view respondsToSelector:selector]) continue;
                NSMethodSignature *signature = [view methodSignatureForSelector:selector];
                if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(view, selector);
                if ([value isKindOfClass:UIView.class] && TSBVisibleInFooter(value, footer)) return value;
            }
        }
        BOOL nativeButton = [className containsString:@"BCNUFIButton"];
        if (!nativeButton && ![view isKindOfClass:UIControl.class]) continue;
        NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        BOOL isShare = ([identifier containsString:@"share"] && ![identifier containsString:@"reshare"]) ||
            [identifier containsString:@"send"] || [label hasPrefix:@"share"] || [label hasPrefix:@"send"] ||
            [label hasPrefix:@"分享"] || [label hasPrefix:@"傳送"] || [label hasPrefix:@"发送"];
        if (isShare) named = view;
        CGRect frame = [view convertRect:view.bounds toView:footer];
        if (nativeButton && !CGRectIsEmpty(frame) && CGRectGetMaxX(frame) > rightmostX) {
            rightmostX = CGRectGetMaxX(frame);
            rightmostUFI = view;
        }
        BOOL compactControl = [view isKindOfClass:UIControl.class] && frame.size.width > 0 &&
            frame.size.width <= 96.0 && frame.size.height > 0 && frame.size.height <= 72.0;
        if (compactControl && CGRectGetMaxX(frame) > rightmostX) {
            rightmostX = CGRectGetMaxX(frame);
            rightmostControl = view;
        }
    }
    // Current bundle's UFI ends with the paper-plane action. Restrict this
    // geometry fallback to BCNUFIButton, not arbitrary footer controls.
    return named ?: rightmostUFI ?: rightmostControl;
}

BOOL TSBLayoutFooterBadge(UICollectionViewCell *footer, UIView *share, UIButton *badge) {
    TSBRestoreFooterShare(footer);
    if (!TSBVisibleInFooter(share, footer)) return NO;
    std::vector<TSBFooterRect> movableObstacles;
    NSMutableArray<UIView *> *pending = [footer.subviews mutableCopy];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.01 || view == badge) continue;
        NSString *name = NSStringFromClass(view.class);
        BOOL namedButton = [name containsString:@"BCNUFIButton"];
        NSString *identifier = view.accessibilityIdentifier ?: @"";
        NSString *label = view.accessibilityLabel ?: @"";
        CGRect rect = [view convertRect:view.bounds toView:footer];
        // The screenshot confirms the native UFI has a large empty trailing
        // region. Ignore decorative/full-row image views and containers; they
        // do not occupy interactive layout space. Count only compact controls
        // and visible count labels.
        BOOL compactControl = ([view isKindOfClass:UIControl.class] || namedButton) &&
            (!identifier.length || ![identifier isEqualToString:@"ThreadsNoSpoilerBadge"]) &&
            rect.size.width > 0 && rect.size.width <= 96.0 &&
            rect.size.height > 0 && rect.size.height <= CGRectGetHeight(footer.bounds) + 8.0;
        BOOL countLabel = [view isKindOfClass:UILabel.class] &&
            (((UILabel *)view).text.length || label.length) && rect.size.width <= 96.0;
        BOOL content = view == share || compactControl || countLabel;
        if (content) {
            if (!CGRectIsEmpty(rect)) {
                TSBFooterRect item = {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
                if (view != share && ![view isDescendantOfView:share]) movableObstacles.push_back(item);
            }
        }
        if (!content || ![view isKindOfClass:UIControl.class]) {
            [pending addObjectsFromArray:view.subviews];
        }
    }
    CGRect bounds = footer.bounds;
    CGRect anchor = [share convertRect:share.bounds toView:footer];
    TSBFooterRect frame;
    TSBFooterRect footerRect = {bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height};
    TSBFooterRect shareRect = {anchor.origin.x, anchor.origin.y, anchor.size.width, anchor.size.height};
    BOOL moved = NO;
    TSBFooterRect movedShare;
    // The current Threads UFI visibly reserves its trailing half. Place there
    // directly; decorative hierarchy must not veto an empty rendered region.
    if (!TSBFindFooterBadge(footerRect, shareRect, nullptr, 0, &frame)) {
        moved = TSBFindFooterBadgeMovingShare(footerRect, shareRect,
            movableObstacles.data(), movableObstacles.size(), &movedShare, &frame);
        if (!moved) return NO;
    }
    if (moved) {
        TSBFooterShareState *state = [TSBFooterShareState new];
        state.share = share;
        state.originalCenter = share.center;
        CGPoint target = [footer convertPoint:CGPointMake(movedShare.x + movedShare.width / 2.0,
            movedShare.y + movedShare.height / 2.0) toView:share.superview];
        [UIView performWithoutAnimation:^{ share.center = target; }];
        state.appliedCenter = share.center;
        objc_setAssociatedObject(footer, &TSBFooterShareStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (badge.superview != footer) [footer addSubview:badge];
    badge.titleLabel.font = [UIFont systemFontOfSize:frame.width < 30 ? 10 : 11 weight:UIFontWeightSemibold];
    badge.titleLabel.adjustsFontSizeToFitWidth = YES;
    badge.titleLabel.minimumScaleFactor = 0.85;
    [UIView performWithoutAnimation:^{ badge.frame = CGRectMake(frame.x, frame.y, frame.width, frame.height); }];
    [footer bringSubviewToFront:badge];
    return YES;
}
