#import <UIKit/UIKit.h>

// Reserves a real gap after the native header; the badge belongs to that gap.
BOOL TSBReserveBadgeRow(UICollectionView *collection, NSIndexPath *headerPath,
                        UIButton *badge, CGFloat anchorX, CGSize desiredSize, CGFloat headerOverflow);
void TSBResetBadgeRows(UICollectionView *collection);
