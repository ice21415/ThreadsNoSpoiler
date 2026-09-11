# Header layout audit

Static inspection of the local `../Threads` executable. These strings establish
that identifiers or symbols exist; they are not an on-device view hierarchy dump.

| Requested content | Bundle evidence | Confidence |
| --- | --- | --- |
| Author ID / profile action | `feed-item-header-user-button`, `feed-item-header-title` | Explicit accessibility identifiers; exact text runs need runtime inspection |
| Date | `timestampLabel`, `showTimestamp` | Getter/configuration strings, not proof of a separate label in this header |
| Edited glyph | `isEdited`, `$__lazy_storage_$_editIconImageView` | Candidate state/view symbols; header ownership unconfirmed |
| Thread/post count | `selfThreadCount`, `selfThreadInfo`, `$__lazy_storage_$_threadCountLabel` | Candidate model/view symbols; header ownership unconfirmed |
| Menu | `feed-item-header-more-button`, `MoreButtonConfig` | Explicit menu identifier |
| Topic and other text | `TopicTagConfig`, `topicTagConfig`, `BCNFeedItemHeaderSupplementalLine` | Header configuration symbols; text may share a rendered component |
| Header container | `BCNFeedItemHeaderCell`, `BCNFeedItemHeaderCellContentView`, `BCNFeedItemHeaderLayout` | Container/layout symbols |
| Feed layout | `_TtC21BCNFeedCollectionView27BCNFeedCollectionViewLayout` | Swift runtime class symbol |

## Implemented behavior (0.1.42)

- Preserve the native header height and all following post positions. No hooks
  on collection layout attributes, content size, reloads or batch updates remain.
- Search for a non-overlapping badge slot below the menu inside the header.
- When it is crowded, proportionally scale the native header group into the left
  portion of the same rectangle. ID, date, topic, edit and count attachments stay
  in their existing relative arrangement. Native text is scaled as rendered,
  rather than edited or reflowed into additional lines.
- Position the native menu and badge in a right-hand lane inside the existing
  header. The menu stays above the badge. No minimum-overlap fallback is used.
- Keep the menu in its native hierarchy and route compact-menu touches through
  its actual bounds. Temporarily release ancestor clipping only where needed,
  restoring it with the other native properties.
- Restore centers, transforms and clipping before native header layout, when a
  header leaves the window, when its badge is cleared, and when disabled. Repeat
  layout always starts from the restored native geometry.
- Badge text stays on one line and adapts to the available width. Short headers
  require smaller text and touch targets; a 44-point minimum target cannot be
  promised together with two stacked controls inside a 44-point header.
- Unknown collection-layout subclasses are no longer a reason to remove the
  badge: placement is local to the detected header and does not hook its layout.

## Verification and limits

`scripts/test-layout.sh` exercises the same fixed-header geometry used by the
tweak, including narrow widths, short/tall headers, all requested content kinds,
native overflow, menu presence/absence, component separation, constant header
dimensions, aspect ratios and repeated calculations. Both iOS slices compile.

No device was attached for this change. Native transforms, menu hit testing,
cell reuse and visual readability still require on-device verification. The
existing arm64e ABI compiler warning remains. Static bundle symbols alone do not
establish the exact runtime view for the edited/count glyphs.
