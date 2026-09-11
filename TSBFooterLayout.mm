#import "TSBFooterLayout.h"
#import "TSBFooterGeometry.h"
#import <objc/message.h>
#include <vector>

BOOL TSBIsFooterCell(UIView *view) {
    return [view isKindOfClass:UICollectionViewCell.class] &&
        [NSStringFromClass(view.class) isEqualToString:@"BCNFeedItemUFICell.BCNFeedItemUFICell"];
}

UICollectionViewCell *TSBFooterForFeedCell(UICollectionViewCell *source) {
    UICollectionView *collection = [source.superview isKindOfClass:UICollectionView.class] ?
        (UICollectionView *)source.superview : nil;
    NSIndexPath *path = [collection indexPathForCell:source];
    if (!path) return nil;
    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    std::vector<TSBFeedRow> rows;
    for (UICollectionViewCell *cell in collection.visibleCells) {
        NSIndexPath *index = [collection indexPathForCell:cell];
        if (!index) continue;
        BOOL header = [NSStringFromClass(cell.class) isEqualToString:@"BCNFeedItemHeaderCell.BCNFeedItemHeaderCell"];
        rows.push_back({(long)index.section, (long)index.item, (bool)header, (bool)TSBIsFooterCell(cell)});
        [cells addObject:cell];
    }
    int match = TSBFindFooterRow(path.section, path.item, rows.data(), rows.size());
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
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:footer];
    UIView *named = nil;
    UIView *rightmostUFI = nil;
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
        if ([className isEqualToString:@"BCNUFI.BCNUFIView"] || view == footer) {
            for (NSString *getter in @[@"shareButton", @"sendButton"]) {
                SEL selector = NSSelectorFromString(getter);
                if (![view respondsToSelector:selector]) continue;
                NSMethodSignature *signature = [view methodSignatureForSelector:selector];
                if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(view, selector);
                if ([value isKindOfClass:UIView.class] && TSBVisibleInFooter(value, footer)) return value;
            }
        }
        BOOL nativeButton = [className isEqualToString:@"BCNUFI.BCNUFIButton"];
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
    }
    // Current bundle's UFI ends with the paper-plane action. Restrict this
    // geometry fallback to BCNUFIButton, not arbitrary footer controls.
    return named ?: rightmostUFI;
}

BOOL TSBLayoutFooterBadge(UICollectionViewCell *footer, UIView *share, UIButton *badge) {
    if (!TSBVisibleInFooter(share, footer)) return NO;
    std::vector<TSBFooterRect> obstacles;
    NSMutableArray<UIView *> *pending = [footer.subviews mutableCopy];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.01 || view == badge) continue;
        NSString *name = NSStringFromClass(view.class);
        BOOL content = view == share || [name isEqualToString:@"BCNUFI.BCNUFIButton"] ||
            [view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UITextView.class];
        if (content) {
            CGRect rect = [view convertRect:view.bounds toView:footer];
            if (!CGRectIsEmpty(rect)) obstacles.push_back({rect.origin.x, rect.origin.y, rect.size.width, rect.size.height});
        } else {
            [pending addObjectsFromArray:view.subviews];
        }
    }
    CGRect bounds = footer.bounds;
    CGRect anchor = [share convertRect:share.bounds toView:footer];
    TSBFooterRect frame;
    if (!TSBFindFooterBadge({bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height},
        {anchor.origin.x, anchor.origin.y, anchor.size.width, anchor.size.height},
        obstacles.data(), obstacles.size(), &frame)) return NO;
    if (badge.superview != footer) [footer addSubview:badge];
    badge.titleLabel.font = [UIFont systemFontOfSize:frame.width < 30 ? 10 : 11 weight:UIFontWeightSemibold];
    badge.titleLabel.adjustsFontSizeToFitWidth = YES;
    badge.titleLabel.minimumScaleFactor = 0.85;
    [UIView performWithoutAnimation:^{ badge.frame = CGRectMake(frame.x, frame.y, frame.width, frame.height); }];
    [footer bringSubviewToFront:badge];
    return YES;
}
