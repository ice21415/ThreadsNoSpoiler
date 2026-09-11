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

## Implemented behavior

- Preserve the complete native header and its native text wrapping, including
  unknown inline glyphs and controls. Do not shrink or replace the author's ID.
- Measure visible header descendants as a group; account for content extending
  below the cell bounds. The diagnostic hierarchy now includes accessibility IDs.
- Reserve an independent action row after the header. Shift subsequent native
  layout attributes and grow content size by the reserved height. Copy attributes
  instead of mutating native cached objects. Spanning decoration frames grow too.
- Center the badge under the menu, clamped to the safe horizontal range. If a
  menu is absent, align to the trailing edge of the header.
- Measure the badge title using Dynamic Type, allow wrapping, retain at least a
  44-point height and normal-width touch target. Increase row height for large text.
- Remove the minimum-overlap fallback entirely. Content crowding no longer
  selects a colliding badge rectangle or shrinks the badge to a 1-point height.
- Keep row spacing stable when a header scrolls out of view. Reset index-path
  reservations on collection reload/batch updates and when the feature is disabled.
- Keep press/release preview ownership on the header, independent of the badge's
  collection-view host. Cancel an active preview when resetting rows.

## Verification and limits

`scripts/test-layout.sh` exercises the same portable geometry used in the tweak:
all listed header elements, narrow widths, large fonts, overflowing header content,
multiple posts, spanning decorations, fractional boundaries, viewport queries and
reset. The iOS package is also compiled for arm64 and arm64e.

No device was attached for this change. Native layout cache behavior, batch update
animations, rotation, scrolling/reuse and press/release behavior still require
on-device verification. The existing arm64e ABI compiler warning remains.

Only the bundled `BCNFeedCollectionView.BCNFeedCollectionViewLayout` is hooked.
An unknown runtime layout records an unsupported-layout status and does not use
an overlapping fallback. Consequently this is not a verified guarantee that the
badge remains visible on every Threads version or screen.
