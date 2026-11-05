# Browsing navigation follow-up

Continue the authorized whole-interface polish with the existing SwiftUI and AppKit components. No dependencies or file-operation changes.

Observed defects: clicking an icon leaves the search field focused; keyboard type-selection changes the selected file without scrolling it into view, including in List. Custom file cells merge into one accessibility text element.

- [x] Reveal the current selection in all four views, including the moving end of a keyboard range. Reuse the existing cursor and ScrollViewReader pattern; avoid jumping on mouse multi-selection.
- [x] Keep active tabs and newly opened columns visible. Preserve tab close actions and pane activation.
- [x] Release text-field focus when clicking file content, while retaining search/filter editing. Expose each custom file cell and its selected state to accessibility.
- [x] Check selection behavior with the existing self-check; build and test the installed app with a temporary large folder, deep columns, and overflowing tabs.
- [x] Review, sign/install, restore the original browsing tab, commit task files, and push main.

Scope: BrowserViews, BrowserPane selection state, BrowserSelfCheck. Keep file operations, cloud preview access rules, user data, and unrelated preferences unchanged. Verify all four browsing modes and text-field focus through the live app; no source-text tests.

## Verification

- The new reveal-target self-check failed before implementation, then passed for single selection, forward and reverse keyboard ranges, mouse multi-selection, and clearing selection.
- Final `./build.sh` and the complete release `--self-check` passed. Developer ID signature verified; the installed executable matches the built executable.
- Live checks used an 82-item temporary folder and seven nested folders: type-to-select and view transitions in all four modes; a 36-item keyboard range crossing the List viewport; deep column expansion and return; split-pane navigation; eight overflowing tabs, wraparound, and closing the extra tabs.
- Search and folder-filter fields remain editable. Selecting a file releases field focus, including through accessibility activation; arrow navigation then operates on files. Each custom cell exposes its name, selected state, and an Open action. The folder Open action was exercised.
- Review caught competing scroll requests when columns collapse. The last-column observer now runs only when the column count grows. The final source review found no additional substantive issues.
- List view needs one guarded follow-up scroll after layout to account for newly measured rows. Verified the last row is fully visible, without forcing clicked rows to the center.
- The original Documents tab was restored and all temporary panes/tabs were closed. Spoken VoiceOver, every macOS version, and extreme pane resizing were not fully verified. No new notarization or downloadable app release was performed; this task updates the local signed app and source repository.
