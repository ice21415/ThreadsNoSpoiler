# Footer placement (0.1.43)

The user replaced header placement with a badge at the bottom-right of the post,
to the right of the paper-plane share action. The header-compaction implementation
from 0.1.42 has been removed, including its menu hit-test routing and restore hooks.
Earlier header audits describe superseded behavior.

## Local bundle evidence

- `_TtC18BCNFeedItemUFICell18BCNFeedItemUFICell`: post action-row cell.
- `_TtC6BCNUFI10BCNUFIView` and `_TtC6BCNUFI12BCNUFIButton`: UFI container and controls.
- `shareButton`, `sendButton`, `$__lazy_storage_$_shareButton`,
  `$__lazy_storage_$_sendButton`, `threadsShareButton`: share-action clues.

These are static strings, not a verified on-device view dump. Detection first
checks object-returning share/send getters on the native UFI container, then
share/send accessibility descriptions. Its final fallback is the rightmost
`BCNUFIButton` inside the exact footer class, not an arbitrary page control.

## Behavior

- Match the nearest subsequent UFI cell in the same collection section. A visible
  intervening post header blocks the match. Do not require the original header
  to remain on screen.
- Align the badge to the action row's trailing edge with an 8-point margin, on
  the share button's vertical centerline. Keep at least 6 points after share.
- Treat only compact interactive controls and visible count labels as occupied
  space. Ignore decorative images and full-row containers; the supplied device
  screenshot shows these may cover the empty trailing region geometrically.
- Fit only the badge to remaining space; avoid existing controls and labels.
  No transforms or frames of native components are changed, and no rows are added.
- Attach the badge directly to the footer for native hit testing. Press/release
  preview targets only spoiler views associated with that footer.
- Cancel active previews and detach badge owners on footer reuse or removal.
- A missing footer/share anchor or an entirely occupied trailing slot remains a
  pending placement; do not place a badge onto another post or over native controls.

## Verification limits

`scripts/test-layout.sh` covers trailing positioning, row bounds, narrow slots,
collision rejection, unordered visible cells, same-section matching and a next
header boundary. Both iOS architectures are compiled; the existing arm64e ABI
warning remains. On-device share detection, scrolling/reuse, long posts with
recycled source cells and press/release behavior still require validation.
