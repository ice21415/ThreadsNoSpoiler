#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString * const TSBEnabledKey = @"TSBEnabled";
static NSString * const TSBDebugKey = @"TSBDebugLogging";
static char TSBSettingsButtonKey;
static NSMutableSet<NSString *> *TSBHookedClasses;

static BOOL TSBEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:TSBEnabledKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:TSBEnabledKey];
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

static BOOL TSBIsSpoilerMask(UIView *view) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    return [name containsString:@"spoiler"] &&
        ([name containsString:@"mask"] || [name containsString:@"overlay"] || [name containsString:@"blur"]);
}

static void TSBHideMasksBelowView(UIView *view) {
    if (!TSBEnabled()) {
        return;
    }
    for (UIView *subview in view.subviews) {
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
    TSBHideMasksBelowView(self);
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Display" : @"Diagnostics";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"When enabled, the tweak hides recognised Threads spoiler-mask views on this device." : @"Enable only when checking compatibility after a Threads update.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SettingCell" forIndexPath:indexPath];
    UISwitch *toggle = [UISwitch new];
    toggle.tag = indexPath.section;
    toggle.on = indexPath.section == 0 ? TSBEnabled() : [NSUserDefaults.standardUserDefaults boolForKey:TSBDebugKey];
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.textLabel.text = indexPath.section == 0 ? @"Automatically reveal spoilers" : @"Debug logging";
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *key = toggle.tag == 0 ? TSBEnabledKey : TSBDebugKey;
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:key];
    [NSUserDefaults.standardUserDefaults synchronize];
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
        [TSBHookedClasses addObject:name];
        TSBLog(@"hooked %@", name);
        // The original IMP storage is intentionally single-use: one concrete
        // BCNSpoilerView implementation owns the descendant masking hierarchy.
        break;
    }
    free(classes);
}

%ctor {
    @autoreleasepool {
        TSBHookedClasses = [NSMutableSet set];
        MSHookMessageEx(UIViewController.class, @selector(viewDidAppear:), (IMP)TSBHookedViewDidAppear, (IMP *)&TSBOriginalViewDidAppear);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TSBInstallSpoilerHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TSBInstallSpoilerHooks();
        });
    }
}
