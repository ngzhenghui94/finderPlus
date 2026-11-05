# Browsing polish

Make existing navigation easier to see and click while preserving FinderPlus's native macOS layout. The user selected the whole browsing interface.

## Approach

Extend the existing SwiftUI views and shared sidebar style. A visual redesign would discard familiar controls; a sidebar-only pass would leave the reproduced filter bug and small navigation targets. No dependencies, new preferences, or file-operation changes are needed.

## Changes

- Align sidebar icons and labels; use readable text, subtle hover feedback, a clear accent selection, and full-path tooltips. Keep the entire row clickable. Reflect the active pane and search scope accurately.
- Enlarge tab controls and breadcrumb targets. Expose tab selection and close actions to accessibility, preserve context menus, and keep the current breadcrumb visible for deep paths.
- Distinguish an empty folder, unmatched filter, unmatched search, failed loading, and a search that needs attention. Retain search warnings and offer the appropriate recovery action. Make the filter easy to clear or dismiss with Escape.
- Improve file-name readability and tooltips across Icons, Columns, and Gallery, without changing their selection or file-operation behavior.

## Constraints and validation

Keep macOS 15 support, system appearance, existing navigation/history, custom favorites, and user data. Do not change file-operation or search security boundaries.

Add self-checks for empty-state precedence and busy/nonempty suppression. Build with `./build.sh`, run `--self-check`, sign and install the same app in `/Applications`, and check actual clicks, filter recovery, tabs, breadcrumbs, and existing views. Commit task files and push to `main`.
