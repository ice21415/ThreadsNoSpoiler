#import <UIKit/UIKit.h>

BOOL TSBIsFooterCell(UIView *view);
UICollectionViewCell *TSBFooterForFeedCell(UICollectionViewCell *source);
UIView *TSBFooterShareButton(UICollectionViewCell *footer);
BOOL TSBLayoutFooterBadge(UICollectionViewCell *footer, UIView *share, UIButton *badge);
