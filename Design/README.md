# Design

Reference artifacts, **not build inputs**.

`Said-Mac-Redesign.html` is the Mac layout pass ("UI v3 — Mac-native"). Its STRUCTURE is what the
macOS app implements today; its palette is superseded — the record red and indigo accent it draws
were replaced by the violet/amber identity. Read it for layout, not for colour.

`Said-iPhone-Screens.html` is the settled Said identity applied to the ten iPhone screens Phase 2
builds: first run, Library, source sheet, recording, camera slide capture, session view, generation
sheet, Ask, Settings, and send-as-`.said`. It also records the three platform constraints that
shaped those screens (no phone-call audio, no live speaker names, no ReplayKit in Phase 2).

The written version of everything in here lives in `CLAUDE.md` ▸ **Design system**, which is the
source of truth. This folder is the picture; `CLAUDE.md` is the contract.

Nothing in `Design/` is referenced by `Package.swift`, listed in any target's `resources:`, or
copied by `Scripts/build_app.sh` — it can never end up inside `Said.app`.
