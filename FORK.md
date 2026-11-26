# Fork notes

Personal fork of [LK4D4/suwayomi.koplugin](https://github.com/LK4D4/suwayomi.koplugin).

## Changes from upstream

- **Server archive memory fix.** Downloading a chapter the server already
  packed as a CBZ rebuilt a 64 KB string for every ~2 KB network chunk, about
  250 MB of garbage per 4 MB archive, which got Kobo and Kindle download workers
  killed for running out of memory. The archive tail is now kept as a short list
  of chunks and joined once (`suwayomi/api/transport.lua`).
- **Uncompressed chapter archives.** Page-by-page downloads write CBZs with zip
  "store" instead of deflate. Pages are already-compressed images, so deflate only
  cost CPU time. Older KOReader builds without `setZipCompression` keep the default.

- **Per-manga chapter list files.** Saved chapter lists live in
  `suwayomi_chapters/` (one file per manga) beside KOReader's `suwayomi.lua`, so
  download queue and read-status saves no longer rewrite every saved chapter list.
  An existing in-document cache is read, then migrated on the next chapter list save.
- **Connection reuse for page downloads.** Each chapter download keeps one HTTP/1.1
  connection instead of a new TCP + TLS connection per page. Redirects and
  connection failures fall back to the original request code.
- **Resize pages to fit screen** (Settings > Downloads; on by default on Kobo,
  Kindle, PocketBook, reMarkable and Cervantes). Oversized pages are shrunk to the
  screen while downloading and stored as JPEG. Spreads fit the rotated screen, long
  strips fit its width, and pages over 8 MP, near screen size, or that would not
  get smaller are kept unchanged. While it is on, chapters download page by page so
  they can be resized; when off, archives the server already made are used.

## Staying up to date

`.github/workflows/sync-upstream.yml` merges upstream `master` daily, runs lint and
tests, and pushes only if they pass. If the merge conflicts or tests fail, the run
fails and GitHub sends an email. Run it manually from **Actions > Sync upstream >
Run workflow**.

On the Kobo, install this repo through Storefront using **Install from branch** with
`master`, so Storefront tracks new commits here as updates.
