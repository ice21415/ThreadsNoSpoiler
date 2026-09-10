// Local layout adapter: reserve space in layout attributes, never translate
// live cells independently of the collection's content size or hit testing.
static char TSBRowsKey, TSBLayoutBaseKey, TSBLayoutDepthKey, TSBRowsInvalidationKey;
static const CGFloat TSBRowHeight = 40.0;

static NSMutableSet<NSIndexPath *> *TSBRows(UICollectionViewLayout *layout) {
    NSMutableSet *rows = objc_getAssociatedObject(layout, &TSBRowsKey);
    if (!rows) {
        rows = [NSMutableSet set];
        objc_setAssociatedObject(layout, &TSBRowsKey, rows, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return rows;
}

static IMP TSBLayoutBaseIMP(id layout, SEL selector) {
    Class base = objc_getAssociatedObject(layout, &TSBLayoutBaseKey);
    return class_getMethodImplementation(base, selector);
}

static BOOL TSBLayoutBusy(id layout) {
    return [objc_getAssociatedObject(layout, &TSBLayoutDepthKey) boolValue];
}

static void TSBLayoutSetBusy(id layout, BOOL value) {
    objc_setAssociatedObject(layout, &TSBLayoutDepthKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UICollectionViewLayoutAttributes *TSBNativeItem(UICollectionViewLayout *layout, NSIndexPath *path) {
    BOOL busy = TSBLayoutBusy(layout);
    TSBLayoutSetBusy(layout, YES);
    UICollectionViewLayoutAttributes *result = nil;
    @try {
        result = ((id (*)(id, SEL, id))TSBLayoutBaseIMP(layout, @selector(layoutAttributesForItemAtIndexPath:)))
            (layout, @selector(layoutAttributesForItemAtIndexPath:), path);
    } @finally { TSBLayoutSetBusy(layout, busy); }
    return result;
}

static NSArray<UICollectionViewLayoutAttributes *> *TSBRowAnchors(UICollectionViewLayout *layout) {
    NSMutableArray *anchors = [NSMutableArray array];
    UICollectionView *collection = layout.collectionView;
    for (NSIndexPath *path in TSBRows(layout).allObjects) {
        if (path.section >= collection.numberOfSections ||
            path.item >= [collection numberOfItemsInSection:path.section]) continue;
        UICollectionViewLayoutAttributes *attributes = TSBNativeItem(layout, path);
        if (attributes) [anchors addObject:attributes];
    }
    return anchors;
}

static UICollectionViewLayoutAttributes *TSBAdjustAttributes(UICollectionViewLayoutAttributes *native,
    NSArray<UICollectionViewLayoutAttributes *> *anchors) {
    if (!native) return nil;
    UICollectionViewLayoutAttributes *result = [native copy];
    CGRect frame = native.frame;
    CGFloat shift = 0;
    BOOL ownsRow = NO;
    for (UICollectionViewLayoutAttributes *anchor in anchors) {
        if (native.representedElementCategory == UICollectionElementCategoryCell &&
            [native.indexPath isEqual:anchor.indexPath]) ownsRow = YES;
        else if (CGRectGetMinY(native.frame) >= CGRectGetMaxY(anchor.frame) - 0.5) shift += TSBRowHeight;
    }
    frame.origin.y += shift;
    if (ownsRow) frame.size.height += TSBRowHeight;
    result.frame = frame;
    return result;
}

static id TSBLayoutItem(UICollectionViewLayout *self, SEL selector, NSIndexPath *path) {
    if (TSBLayoutBusy(self)) return ((id (*)(id, SEL, id))TSBLayoutBaseIMP(self, selector))(self, selector, path);
    return TSBAdjustAttributes(TSBNativeItem(self, path), TSBRowAnchors(self));
}

static id TSBLayoutElements(UICollectionViewLayout *self, SEL selector, CGRect rect) {
    IMP original = TSBLayoutBaseIMP(self, selector);
    if (TSBLayoutBusy(self) || TSBRows(self).count == 0)
        return ((id (*)(id, SEL, CGRect))original)(self, selector, rect);
    NSArray *anchors = TSBRowAnchors(self);
    // Inverse query includes cells shifted into the requested viewport.
    CGRect query = rect;
    CGFloat extra = anchors.count * TSBRowHeight;
    query.origin.y -= extra;
    query.size.height += extra;
    NSArray *native = nil;
    TSBLayoutSetBusy(self, YES);
    @try { native = ((id (*)(id, SEL, CGRect))original)(self, selector, query); }
    @finally { TSBLayoutSetBusy(self, NO); }
    NSMutableArray *result = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attribute in native) {
        UICollectionViewLayoutAttributes *adjusted = TSBAdjustAttributes(attribute, anchors);
        if (CGRectIntersectsRect(adjusted.frame, rect)) [result addObject:adjusted];
    }
    return result;
}

static CGSize TSBLayoutContentSize(UICollectionViewLayout *self, SEL selector) {
    BOOL busy = TSBLayoutBusy(self);
    TSBLayoutSetBusy(self, YES);
    CGSize size;
    @try { size = ((CGSize (*)(id, SEL))TSBLayoutBaseIMP(self, selector))(self, selector); }
    @finally { TSBLayoutSetBusy(self, busy); }
    if (!busy) size.height += TSBRowAnchors(self).count * TSBRowHeight;
    return size;
}

static void TSBLayoutUpdates(UICollectionViewLayout *self, SEL selector, NSArray *updates) {
    // Index paths can change when new posts arrive. Rediscover visible rows.
    [TSBRows(self) removeAllObjects];
    ((void (*)(id, SEL, id))TSBLayoutBaseIMP(self, selector))(self, selector, updates);
}

static void TSBLayoutInvalidate(UICollectionViewLayout *self, SEL selector, UICollectionViewLayoutInvalidationContext *context) {
    if (context.invalidateDataSourceCounts) [TSBRows(self) removeAllObjects];
    ((void (*)(id, SEL, id))TSBLayoutBaseIMP(self, selector))(self, selector, context);
}

static void TSBInstallRowLayout(UICollectionViewLayout *layout) {
    if (objc_getAssociatedObject(layout, &TSBLayoutBaseKey)) return;
    Class base = object_getClass(layout);
    NSString *name = [@"TSBRows_" stringByAppendingString:NSStringFromClass(base)];
    Class adapter = NSClassFromString(name);
    if (!adapter) {
        adapter = objc_allocateClassPair(base, name.UTF8String, 0);
        SEL selectors[] = {@selector(layoutAttributesForItemAtIndexPath:), @selector(layoutAttributesForElementsInRect:),
            @selector(collectionViewContentSize), @selector(prepareForCollectionViewUpdates:), @selector(invalidateLayoutWithContext:)};
        IMP replacements[] = {(IMP)TSBLayoutItem, (IMP)TSBLayoutElements, (IMP)TSBLayoutContentSize,
            (IMP)TSBLayoutUpdates, (IMP)TSBLayoutInvalidate};
        for (NSUInteger i = 0; i < 5; i++) {
            class_addMethod(adapter, selectors[i], replacements[i], method_getTypeEncoding(class_getInstanceMethod(base, selectors[i])));
        }
        objc_registerClassPair(adapter);
    }
    objc_setAssociatedObject(layout, &TSBLayoutBaseKey, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(layout, adapter);
}

static CGFloat TSBHeaderNativeHeight(UICollectionViewCell *header) {
    UICollectionView *collection = (UICollectionView *)header.superview;
    if (![collection isKindOfClass:UICollectionView.class]) return header.bounds.size.height;
    NSIndexPath *path = [collection indexPathForCell:header];
    UICollectionViewLayout *layout = collection.collectionViewLayout;
    if (!path || !objc_getAssociatedObject(layout, &TSBLayoutBaseKey)) return header.bounds.size.height;
    UICollectionViewLayoutAttributes *native = TSBNativeItem(layout, path);
    return native ? native.size.height : header.bounds.size.height;
}

static void TSBSetHeaderRow(UICollectionViewCell *header, BOOL needed) {
    UICollectionView *collection = (UICollectionView *)header.superview;
    if (![collection isKindOfClass:UICollectionView.class]) return;
    NSIndexPath *path = [collection indexPathForCell:header];
    if (!path) return;
    UICollectionViewLayout *layout = collection.collectionViewLayout;
    if (!needed && !objc_getAssociatedObject(layout, &TSBLayoutBaseKey)) return;
    TSBInstallRowLayout(layout);
    NSMutableSet *rows = TSBRows(layout);
    if ([rows containsObject:path] == needed) return;
    if (needed) [rows addObject:path]; else [rows removeObject:path];
    if ([objc_getAssociatedObject(layout, &TSBRowsInvalidationKey) boolValue]) return;
    objc_setAssociatedObject(layout, &TSBRowsInvalidationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(layout, &TSBRowsInvalidationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [layout invalidateLayout];
    });
}
