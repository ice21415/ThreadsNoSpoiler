#import <UIKit/UIKit.h>

BOOL TSBLayoutBadgeInHeader(UICollectionViewCell *header, UIView *metadata, UIView *menu, UIButton *badge);
void TSBRestoreHeaderLayout(UIView *header);
void TSBResetAllHeaderLayouts(void);
UIView *TSBHitTestHeaderMenu(UIView *header, CGPoint point, UIView *source, UIEvent *event);
