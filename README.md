# FinderPlus

A native SwiftUI/AppKit file manager for macOS 15 or later. Inspired by the public [FileOctopus](https://www.fileoctopus.com/) feature descriptions and supplied layout reference; this is an independent implementation, not its source code or a branded copy.

## Build and run

Requires the Xcode command-line tools and Swift 6. No third-party packages or API keys are needed.

```sh
./build.sh
./dist/FinderPlus.app/Contents/MacOS/FinderPlus --self-check
```

`./build.sh` produces an ad-hoc-signed local build; macOS asks again for folder access after each ad-hoc rebuild. `dist/FinderPlus.zip` is a Developer ID–signed, notarized and stapled release build. A rebuilt app must be signed and notarized again before you distribute it.

## Browsing

- Icons, List, Columns and Gallery views in a native unified toolbar, local thumbnails, Quick Look, and Get Info with recursive folder size and sharing permissions.
- Group By Kind, Date Modified, Size or Tags (View menu or the toolbar's group button); Finder tag colours and a Tags column.
- Independent pane tabs, native window tabs, recursive horizontal/vertical splits (up to 16 panes), pane zoom, layout presets and saved multi-window workspaces.
- Back/forward history (mouse side buttons and trackpad swipes act on the pane under the pointer), breadcrumbs, Go to Folder, fuzzy Quick Open, command palette, type-to-select, hidden files, sorting and current-folder filtering.
- Favorites and sidebar groups, saved searches, mounted volumes, network locations, Finder/AirDrop handoffs, and a Shelf for gathering file references across folders.
- Finder, Explorer and Total Commander keyboard profiles; editable shortcuts with validated import/export.
- Create folders with the visible **New Folder** toolbar control, **Create New Folder…** in an empty folder, **File → New Folder…**, or the folder context menu. The dialog identifies the destination and uses an explicit **Create** action.

Common default shortcuts:

| Action | Shortcut |
| --- | --- |
| Icons / List / Columns / Gallery | Command-1 / 2 / 3 / 4 |
| Find | Command-F |
| Go to Folder | Command-Shift-G |
| Quick Open | Control-Command-P |
| Command palette | Control-Command-Shift-P |
| New native window tab | Command-T |
| New pane tab | Control-Option-Command-T |
| New folder | Command-Shift-N |
| Split pane | Control-Option-Command-arrow |
| Zoom pane | Shift-Command-Return |
| Copy / Paste | Command-C / Command-V |
| Move copied items here | Option-Command-V |
| Rename / Open (Finder profile) | Return / Command-Down |
| Quick Look | Space |
| Settings | Command-comma |

## Local, inspectable search

Search the current folder and its descendants, or switch to explicitly approved roots. Add approved roots in **Settings → Search & Privacy**. The parser runs on-device; no prompts, file names or file contents are sent to an AI service. Query chips show the interpreted constraints and can be edited or removed.

Examples:

- `screenshots last week`
- `videos larger than 1 GB`
- `downloaded from github`
- `pdfs created this month`
- `images in June 2026`
- `kind:pdf size:>10MB`
- `name:invoice NOT name:draft`
- `content:"project brief"`

Date filters use the local calendar. Size query units are binary (`1 GB` means 1,073,741,824 bytes); Finder-style displayed sizes can differ. A recorded download source must exist in the file's macOS `WhereFroms` metadata—FinderPlus cannot infer a missing origin. Natural-language search uses a defined local grammar, not unrestricted language-model reasoning. Unsupported input is retained as text or reported rather than secretly sent elsewhere.

Content search and Vision OCR are separate opt-ins and only run under approved roots. Plain words match names and, with content search on, text and PDF contents; OCR runs only for `content:` filters. Search skips symlink traversal, package contents, network-volume traversal and online-only cloud content. Metadata is cached in memory for ten seconds; application file operations invalidate the cache immediately. Cold searches scan the selected tree and are not guaranteed instant on very large folders.

Malformed Boolean groups fall back to literal-name matching with a warning rather than matching every file. Failed operators keep their following words as search terms. Pipes, devices and sockets are not opened for content search or previews. Changing approved roots or content/OCR permissions cancels active searches and clears their results; an unavailable remaining root cannot cause a removed approval to return after restart. Bookmark-save failures are shown in Settings.

Content limits bound resource use: text up to 8 MiB, PDFs up to 32 MiB and 200 text pages; OCR up to 32 MiB, images downsampled to 4096 pixels, and up to 20 PDF pages. Encrypted, unsupported, unreadable and skipped files are reported. Content/OCR results therefore are not a complete forensic inventory.

## File operations and recovery

Copy, move, duplicate, rename, previewed batch rename, create folder, new folder with selection, ZIP compression, Finder aliases, Trash/Put Back, and reviewed folder comparison/synchronization are supported. Internal multi-file drag/drop and standard file-URL drops use the same operation queue. The outgoing standard file-URL drag payload exposes the first selected item to other applications; use clipboard copy/paste for multi-item transfers to Finder.

**New Folder with Selection** is one transaction: folder creation and selected moves either complete together or roll back together, and one Undo/Redo covers the whole action. Failed or no-op operations preserve the existing Redo history.

The Operations window exposes whole-job progress with bytes copied, speed and time left, queued-job ordering, pause/resume, cancellation, undo/redo, failures with a plain-language next step and Retry, and interrupted-work recovery. Name conflicts show the existing and incoming versions side by side with the newer one marked; Keep Both is the default and Stop (Esc) cancels the operation. Moves within one disk are journaled renames: instant, and they need no extra space. Renames, same-disk moves and Trash record a metadata fingerprint (names, sizes, dates, file IDs, extended attributes) rather than reading file contents, so they also work on folders holding online-only cloud files. Copies, and moves between disks, are staged and verified before publishing; same-disk copies of files are APFS clones. Existing names are never silently overwritten. Undo checks that affected files still match the recorded state and refuses to overwrite later external edits.

Copy verification includes user extended attributes. macOS's system-owned `com.apple.provenance` and `com.apple.macl` are excluded from fingerprints because macOS assigns them to new files and to items moved into the Trash; FinderPlus does not remove or rewrite that security metadata.

Undo can retain hidden `.FinderPlus-…` staging/backup folders beside affected files (replaced items, and originals of moves from disks without a Trash, such as network shares). Do not manually remove or move that storage. Moving a folder containing active retained storage is refused. Moves within one disk are renames. Moves between disks put the verified original in the Trash: empty the Trash to reclaim the space; Undo and Put Back restore it while it is there. **File Operations → Clear File Operation History…** explicitly reviews and trashes owned retained storage, then removes the corresponding undo history; it never empties system Trash. Keep an independent backup: the journal is not a backup service, and external changes can prevent recovery.

Folder comparison hashes file contents recursively. Synchronization copies only reviewed selections, replacing reviewed destination files (Undo restores them); it does not propagate deletions. Symlinks, type conflicts, equal-date content conflicts and changes since review require manual resolution. Case-only renames and cyclic batch renames are refused instead of risking data loss. Put Back applies to Trash actions tracked by FinderPlus, not arbitrary untracked Finder Trash entries.

Queued synchronization retains the original reviewed content hashes and checks them again when executing. Changes between review and enqueue, redirected parent paths outside the compared roots, newly occupied destinations (including dangling symlinks), and added children in a reviewed empty folder require another comparison.

## Send to Nearby Mac

Nearby Share is off by default; turn it on in **Settings → General** on both Macs. While it is on, this Mac is visible to other FinderPlus Macs on the network, and sender names are not verified. Select files and choose **File → Send to Nearby Mac…** (or the context menu) to send them straight to another Mac running FinderPlus on the same local network, similar to Spacedrive's Spacedrop. Peers are found over Bonjour; the receiver must accept each request, and accepted files are saved to Downloads under a new name if one already exists, with the macOS quarantine flag set like AirDrop. Folders must be compressed first. Transfers use plain TCP and are **not encrypted**—use them only on networks you trust.

Incoming batches stay in hidden staging until every file arrives. Interrupted or cancelled transfers remove their unpublished data; turning Nearby Share off cancels active transfer tasks as well as discovery. A lost final acknowledgement does not turn already-saved files into a receiver-side failure.

## Cloud folders and privacy

FinderPlus discovers iCloud Drive and local `~/Library/CloudStorage` providers. Your provider's own macOS application handles authentication and synchronization; FinderPlus stores no account credentials. iCloud uses public macOS download/eviction APIs. Other providers support explicit coordinated file downloads; provider-specific status, folder hydration, eviction and web actions may require **Show in Finder**. Search and previews do not intentionally hydrate online-only files. Moving or trashing cloud files warns that the change can synchronize to other devices.

The app follows macOS filesystem permissions. It does not grant itself Full Disk Access or bypass protected folders. Search scope approval is an application privacy boundary, not an App Sandbox entitlement. Local preferences store paths/bookmarks, layouts and saved searches; the operation journal (`operations.json` plus an append-only `operations.log` folded into it after each operation) stores paths and recovery metadata in the user's Application Support directory. There is no telemetry or analytics SDK.

## Checks and implementation boundaries

`--self-check` uses disposable temporary fixtures for search parsing and real extraction, scope/cancellation/cache behavior, recursive pane/session invariants, SHA-256 comparison and stale-review rejection, batch rename validation, and file-operation conflict/undo/recovery paths. It does not operate on the user's real documents or empty Trash.

Verified on this Apple Silicon Mac running macOS 27: release build, code-signature verification and the full self-check passed. Native UI checks covered the three example natural-language queries, all four views, pane tabs, repeated Gallery split/collapse, native text editing, auxiliary-window closing, comparison of missing versus identical files, settings, and an actual file copy followed by Undo. Copied bytes and the final on-disk state were checked separately. All smoke fixtures were disposable.

Folder-creation checks also exercised the toolbar, empty-folder action, File menu, keyboard shortcut, all four views, targeting an inactive split pane, and Undo. Eight temporary directories were checked on disk. Automated right-click-menu verification was inconclusive; foreground approval was not received. Regression checks reject occupied names and path traversal without replacing existing files.

The audit regression suite additionally covers failed Back/Forward navigation, deterministic sorting of equal-name search results, tab-history preservation when moving panes, malformed queries, special-file read rejection, privacy revocation and bookmark failures, atomic folder grouping, Redo preservation, stale queued synchronization, and interrupted loopback transfers. The release build and full self-check passed, including a real cross-disk move using a disposable RAM disk and loopback transfer quarantine/no-overwrite checks.

The audited build was installed in `/Applications` and checked through its native UI: malformed search returned no unrelated file, New Folder with Selection completed as one job and one Undo restored the original bytes while removing its folder, and moving an inactive tab selected the correct tab and preserved Back/Forward history. Back/Forward failures leave history intact, and size/kind/date sorting uses paths to break equal-name ties.

Residual boundary: filesystem checks are path-based, so a different process can still change a path between validation and the final filesystem call. Multi-Mac sharing, live cloud providers, forced process termination during transfer, and every supported macOS release were not exercised by this audit.

The interface uses the system appearance and native controls. It is not pixel-identical to the reference. Split arrangements and tabs persist; custom divider ratios and native window-tab group membership do not. Provider account behavior, removable-device failures, production-scale performance, live system Trash restoration and every supported macOS version require separate environment-specific testing before relying on the app for irreplaceable files.
