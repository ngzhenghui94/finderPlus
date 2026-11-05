# Browsing Polish Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make everyday browsing easier to read, click, and recover from a no-results state.
**Architecture:** Extend existing SwiftUI views and styles. Derive empty-state classification from BrowserPane, and retain existing navigation and file operations.
**Tech Stack:** Swift 6, SwiftUI, AppKit; macOS 15 minimum; no dependencies.
**Spec:** `docs/superpowers/specs/2026-11-06-browsing-polish-design.md`

## Global Constraints

Preserve unrelated work, user files, favorites, history, and security boundaries. Build, install, smoke-check, commit, and push to main under standing user authorization.

## Review Focus

- Filters must not claim that a populated folder is empty.
- Loading and errors must not be presented as empty success.
- Sidebar selection must follow the active pane and current search.
- Closing a tab must not select the closed tab through a parent gesture.
- Deep paths and long names must remain understandable without widening the whole window.

## Tasks

- [x] Extract existing empty-state classification into `BrowserPane.EmptyState` in `Models.swift`. Add failing cases in `BrowserSelfCheck.run()` for unmatched filters and failed loads; run the debug self-check and observe the expected failure.
- [x] Correct classification and add recovery controls in `PaneView`. Check empty, filtered, searched, unavailable, loading, and nonempty cases through the existing self-check.
- [x] Polish `SidebarView` and `SidebarButtonStyle` in `NavigationViews.swift`; pass the active pane from `BrowserWindowContent`, align labels, and preserve full-row hit testing and context menus.
- [x] Polish tabs, breadcrumbs, file labels, and filter controls in `BrowserViews.swift`. Keep existing actions and add accessibility labels and full-path tooltips.
- [x] Run `./build.sh` and the built app's `--self-check`; inspect the diff and obtain a focused review.
- [x] Sign, install, launch, and verify the changed UI. Repeat the original blank-space click test and check filter recovery, tab close/selection, breadcrumbs, and all browser modes.
- [x] Commit task-related changes and push to `origin/main`; verify a clean working tree and matching remote head.

## Execution notes

- Initial UI reproduction: a nonmatching current-folder filter displayed “This folder is empty” and “Create New Folder…” while the folder contained 14 entries.
- Work remains in the clean existing checkout; the user has standing authorization for task commits and pushes to main. UI inspection and the built app provide the click-target checks; no source-text assertion tests will be added.
- Both regression checks failed before their fixes: unmatched folder filter; searching without accessible roots. The latter uses the real search service against no roots, a missing root, and an empty temporary folder.
- Review correction: search failures use search warnings rather than the folder error. Empty results with warnings now show “Search needs attention”, retain the warning detail, and offer Retry Search and Clear Search. Successful searches with results still display those results.

## Verification

- Debug and release builds passed. The full built-app self-check passed after both regression fixes.
- Installed Developer ID signed build matches the built executable; strict code-signature verification passed.
- Live UI checks passed: full-row sidebar clicks (including padded edges), favorites and drives, navigation history, all four browser modes, filter clear/Escape, true empty-folder action, clean search recovery, search warning retry/clear, tab selection, closing active and inactive tabs, padded breadcrumb clicks, deep-path visibility, split-pane selection, and folder context menus. The original tab was restored.
- Accessibility inspection confirmed selected sidebar/tab traits, named tab-close controls, headings, and full-path help. Continuous pointer hover, spoken VoiceOver output, and light appearance were not independently verified.
- No new notarization or public app release was performed.
