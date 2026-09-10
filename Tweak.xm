#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString * const TSBEnabledKey = @"TSBEnabled";
static NSString * const TSBDebugKey = @"TSBDebugLogging";
static NSString * const TSBForceHideContainerKey = @"TSBForceHideContainer";
static NSString * const TSBShowBadgeKey = @"TSBShowSpoilerBadge";
static char TSBSettingsButtonKey;
static char TSBBadgeKey;
static char TSBBadgeStatusKey;
static char TSBBadgeAnchorKey;
static char TSBPostTimestampKey;
static char TSBCopyButtonKey;
static char TSBCopyButtonHeaderKey;
static NSMutableSet<NSString *> *TSBHookedClasses;
static NSMutableOrderedSet<NSString *> *TSBObservedViewClasses;
static NSMutableOrderedSet<NSString *> *TSBLastSpoilerContext;
static NSMutableSet<NSString *> *TSBTimestampHookedClasses;
static NSMutableDictionary<NSString *, NSValue *> *TSBTimestampGetterIMPs;
static NSMutableSet<NSString *> *TSBHeaderHookedClasses;
static void (*TSBOriginalHeaderLayoutSubviews)(id, SEL);
static void (*TSBOriginalCollectionCellDidMoveToWindow)(id, SEL);

static void TSBUpdateSpoilerBadge(UIView *spoilerView);
static void TSBCopyPostData(UIView *header);
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *timestamp);

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
        BOOL isBefore = indexPath.section < target.section ||
            (indexPath.section == target.section && indexPath.item < target.item);
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
        if ([NSStringFromClass(view.class) containsString:@"BCNFeedItemHeaderCell"]) {
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

@interface TSBPostCopyButton : UIButton
@end

@implementation TSBPostCopyButton
- (void)tsb_copyPostData:(id)sender {
    UIView *header = objc_getAssociatedObject(self, &TSBCopyButtonHeaderKey);
    TSBCopyPostData(header);
    [self setTitle:@"Copied" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setTitle:@"Copy data" forState:UIControlStateNormal];
    });
}
@end

static void TSBAppendCopyData(NSMutableString *output, UIView *view, NSUInteger depth, NSUInteger *count) {
    if (*count >= 400 || depth > 20) return;
    (*count)++;
    CGRect frame = view.frame;
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    NSString *badgeStatus = objc_getAssociatedObject(view, &TSBBadgeStatusKey);
    if (badgeStatus) [output appendFormat:@"badge-status: %@\n", badgeStatus];
    NSString *label = view.accessibilityLabel ?: @"";
    NSString *value = view.accessibilityValue ?: @"";
    NSString *text = @"";
    if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text ?: @"";
    if ([view isKindOfClass:UIButton.class]) text = ((UIButton *)view).currentTitle ?: text;
    [output appendFormat:@"%*s%@ frame:(%.1f,%.1f,%.1f,%.1f) hidden:%d alpha:%.2f tag:%ld id:%@ axLabel:%@ axValue:%@ text:%@\n",
        (int)(depth * 2), "", NSStringFromClass(view.class), frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
        view.hidden, view.alpha, (long)view.tag, identifier, label, value, text];
    for (UIView *subview in view.subviews) {
        TSBAppendCopyData(output, subview, depth + 1, count);
    }
}

static void TSBCopyPostData(UIView *header) {
    UIView *post = TSBPostContainer(header) ?: header;
    NSMutableString *output = [NSMutableString stringWithFormat:@"Threads No Spoiler post runtime data\nheader: %@\npost container: %@\n\n",
        NSStringFromClass(header.class), NSStringFromClass(post.class)];
    NSUInteger count = 0;
    [output appendFormat:@"build: 0.1.20 showBadge:%d\nHEADER FIRST\n", TSBShowBadge()];
    TSBAppendCopyData(output, header, 0, &count);
    if ([post isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)post;
        for (UICollectionViewCell *cell in collection.visibleCells) {
            NSIndexPath *path = [collection indexPathForCell:cell];
            UICollectionViewCell *matched = TSBHeaderCellForFeedCell(cell);
            [output appendFormat:@"cell %@ index:%@ matched-header:%@\n",
                NSStringFromClass(cell.class), path, [collection indexPathForCell:matched]];
        }
    }
    [output appendString:@"\nCOLLECTION TREE (limited)\n"];
    TSBAppendCopyData(output, post, 0, &count);
    UIPasteboard.generalPasteboard.string = output;
}

static void TSBInstallPostCopyButton(UIView *header, UIView *metadataTextView) {
    TSBPostCopyButton *button = objc_getAssociatedObject(header, &TSBCopyButtonKey);
    if (button) return;
    button = [TSBPostCopyButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Copy data" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    button.tintColor = UIColor.secondaryLabelColor;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityIdentifier = @"ThreadsNoSpoilerCopyPostData";
    objc_setAssociatedObject(button, &TSBCopyButtonHeaderKey, header, OBJC_ASSOCIATION_ASSIGN);
    [button addTarget:button action:@selector(tsb_copyPostData:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-38],
        [button.centerYAnchor constraintEqualToAnchor:metadataTextView.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:48],
        [button.heightAnchor constraintEqualToConstant:18]
    ]];
    objc_setAssociatedObject(header, &TSBCopyButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TSBRefreshSpoilerBadgesBelowView(UIView *view) {
    if ([NSStringFromClass(view.class) containsString:@"BCNSpoilerView"]) {
        TSBUpdateSpoilerBadge(view);
    }
    for (UIView *subview in view.subviews) {
        TSBRefreshSpoilerBadgesBelowView(subview);
    }
}

static BOOL __attribute__((unused)) TSBViewContainsSpoiler(UIView *view) {
    if ([NSStringFromClass(view.class) containsString:@"BCNSpoilerView"]) return YES;
    for (UIView *subview in view.subviews) {
        if (TSBViewContainsSpoiler(subview)) return YES;
    }
    return NO;
}

static void TSBProcessHeaderCell(UIView *self) {
    UIView *metadataTextView = TSBHeaderMetadataTextView(self);
    UIView *post = TSBPostContainer(self);
    if (post && metadataTextView) {
        objc_setAssociatedObject(self, &TSBPostTimestampKey, metadataTextView, OBJC_ASSOCIATION_ASSIGN);
        TSBInstallPostCopyButton(self, metadataTextView);
        TSBRefreshSpoilerBadgesBelowView(post);
    }
}

static void TSBHookedHeaderLayoutSubviews(UIView *self, SEL _cmd) {
    TSBOriginalHeaderLayoutSubviews(self, _cmd);
    TSBProcessHeaderCell(self);
}

static void TSBHookedCollectionCellDidMoveToWindow(UICollectionViewCell *self, SEL _cmd) {
    TSBOriginalCollectionCellDidMoveToWindow(self, _cmd);
    if ([NSStringFromClass(self.class) containsString:@"BCNFeedItemHeaderCell"]) {
        TSBProcessHeaderCell(self);
    }
    if (self.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.window) TSBRefreshSpoilerBadgesBelowView(TSBPostContainer(self) ?: self);
        });
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
    UICollectionViewCell *cell = TSBOuterFeedCell(spoilerView);
    UICollectionViewCell *header = TSBHeaderCellForFeedCell(cell);
    UIView *anchor = header ? TSBHeaderMetadataTextView(header) : nil;
    NSString *status = !TSBShowBadge() ? @"disabled in settings" : !cell ? @"no outer feed cell" : !header ? @"no preceding visible header/index path" : !anchor ? @"header title identifier missing" : @"anchor resolved; placement requested";
    objc_setAssociatedObject(spoilerView, &TSBBadgeStatusKey, status, OBJC_ASSOCIATION_COPY_NONATOMIC);
    TSBPlaceSpoilerBadge(spoilerView, anchor);
}

// Direct path used when the header has identified the spoiler in its own
// following cells. It intentionally bypasses collection-wide lookup.
static void TSBPlaceSpoilerBadge(UIView *spoilerView, UIView *timestamp) {
    UILabel *badge = objc_getAssociatedObject(spoilerView, &TSBBadgeKey);
    if (!TSBShowBadge() || timestamp == nil || timestamp.superview == nil) {
        [badge removeFromSuperview];
        return;
    }
    if (badge == nil) {
        badge = [UILabel new];
        badge.text = @"劇透";
        badge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        badge.textColor = UIColor.secondaryLabelColor;
        badge.backgroundColor = UIColor.clearColor;
        badge.textAlignment = NSTextAlignmentCenter;
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.accessibilityIdentifier = @"ThreadsNoSpoilerBadge";
        objc_setAssociatedObject(spoilerView, &TSBBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id previousAnchor = objc_getAssociatedObject(spoilerView, &TSBBadgeAnchorKey);
    if (badge.superview != TSBOuterFeedCell(timestamp) || previousAnchor != timestamp) {
        [badge removeFromSuperview];
        [TSBOuterFeedCell(timestamp) addSubview:badge];
        [NSLayoutConstraint activateConstraints:@[
            [badge.leadingAnchor constraintEqualToAnchor:timestamp.trailingAnchor constant:4],
            [badge.centerYAnchor constraintEqualToAnchor:timestamp.centerYAnchor]
        ]];
        objc_setAssociatedObject(spoilerView, &TSBBadgeAnchorKey, timestamp, OBJC_ASSOCIATION_ASSIGN);
    }
    badge.hidden = NO;
    [badge.superview bringSubviewToFront:badge];
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
    TSBRecordHierarchy(self);
    TSBCaptureSpoilerContext(self);
    TSBUpdateSpoilerBadge(self);
    if (TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey]) {
        self.hidden = YES;
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
    TSBUpdateSpoilerBadge(self);
    if (TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey]) {
        self.hidden = YES;
        return;
    }
    TSBHideDirectSpoilerLayers(self);
    TSBHideMasksBelowView(self);
}

static void (*TSBOriginalSetHidden)(id, SEL, BOOL);
static void TSBHookedSetHidden(UIView *self, SEL _cmd, BOOL hidden) {
    BOOL shouldForceHide = TSBEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey];
    TSBOriginalSetHidden(self, _cmd, shouldForceHide ? YES : hidden);
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
    if (section == 0) return 2;
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
    toggle.tag = indexPath.section == 0 ? (indexPath.row == 0 ? 0 : 3) : (indexPath.section == 1 ? 1 : 2);
    toggle.on = toggle.tag == 0 ? TSBEnabled() : (toggle.tag == 1 ? [NSUserDefaults.standardUserDefaults boolForKey:TSBForceHideContainerKey] : (toggle.tag == 2 ? [NSUserDefaults.standardUserDefaults boolForKey:TSBDebugKey] : TSBShowBadge()));
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.textLabel.text = toggle.tag == 0 ? @"Automatically reveal spoilers" : (toggle.tag == 1 ? @"Force-hide spoiler container" : (toggle.tag == 2 ? @"Debug logging" : @"Show spoiler badge"));
    cell.accessoryView = toggle;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *key = toggle.tag == 0 ? TSBEnabledKey : (toggle.tag == 1 ? TSBForceHideContainerKey : (toggle.tag == 2 ? TSBDebugKey : TSBShowBadgeKey));
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
        TSBObservedViewClasses = [NSMutableOrderedSet orderedSet];
        TSBLastSpoilerContext = [NSMutableOrderedSet orderedSet];
        TSBTimestampHookedClasses = [NSMutableSet set];
        TSBTimestampGetterIMPs = [NSMutableDictionary dictionary];
        TSBHeaderHookedClasses = [NSMutableSet set];
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
