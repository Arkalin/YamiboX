# Paged Manga Interaction

## Contract

This migration covers slide, quick fade and page curl, including spreads. Vertical
reading, native page animation, image loading and persistence remain outside it.

| Input | Base scale, hidden edge | Zoomed | No hidden edge |
| --- | --- | --- | --- |
| Horizontal drag toward content | Pan image, even with zoom disabled | Pan image | Navigate only at base scale |
| Edge tap / external control | Reveal edge | Reveal edge first | Navigate |
| Center tap | Toggle chrome | Toggle chrome | Toggle chrome |
| Center double tap | Zoom when enabled | Reset zoom | Zoom when enabled |
| Long press | Loaded image's central region only | Projected central region | No action in blank margins |

Long press uses 0.45 seconds and 10 points. Base-scale pan admission has no
distance threshold. Navigation completion retains its separate distance/velocity
thresholds. A drag never transfers ownership after admission. Chrome blocks image
manipulation, not the existing chrome-visible tap and menu actions.

## Ownership

Input adapters normalize coordinates and recognizer events. Runtime owns surface
registrations and state. Core owns geometry, policy and transactions. Rendering
reads state. Backends retain native navigation and only execute admitted actions.
Core imports Foundation/CoreGraphics; Runtime must not import UIKit or SwiftUI.
Input must not reference a concrete paging coordinator or read its parent.

A surface registration and each transaction carry generations. Admission is a
query; only began creates a transaction. Pan and pinch share a snapshot and commit
after both end. Cancellation of a joined member rolls back the entire operation;
late callbacks and old registration exits cannot modify a replacement surface.
Configuration changes invalidate before recognizers are cancelled. Resize clamps
committed state; base-scale zoom-disable preserves the cropped position.

## Migration Gates

1. Baseline contract and defect tests.
2. Independently compilable geometry, policy and session.
3. Runtime and single-page collection integration.
4. Single-page curl integration and native delegate lifetime.
5. Spread integration with separate SwiftUI/UIKit rendering adapters.
6. External inputs and removal of legacy mirrors, broadcasts and fallbacks.

Each gate is independently committed. Behavior fixes are separate from structural
changes. No publishing or automatic push is part of this migration.

## Verification

Host verification must link production sources, not copied implementations.
Device-target build and build-for-testing do not substitute for touch acceptance.
No simulator is used. Final touch acceptance requires iPhone and iPad, including
cancelled curl, boundaries, pan/pinch cancellation, rotation, reduced motion and
stale callbacks. Until performed, device interaction acceptance is incomplete.
