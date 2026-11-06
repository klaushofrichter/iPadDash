---
name: ipad-screenshots
description: Screenshot every page of iPadDash on the USB-connected iPad and post them to the Slack channel #ipad-dashboard. Use when asked for screenshots of the iPad pages, the current dashboard, or to post the dashboard to Slack.
---

# iPad dashboard screenshots → Slack

1. **Capture.** Run, in the background if auto-move is slow:
   ```sh
   IPAD=silver .claude/skills/ipad-screenshots/capture.sh "$SCRATCH/ipad-shots"
   ```
   `IPAD` is `silver` or `black` (the two iPad Airs) and may be left out when only
   one iPad is connected; ask the user which one if they didn't say.
   (`$SCRATCH` = your scratchpad directory.) It waits for auto-move to show each
   page, keeps one settled 1536 × 2048 shot per page (`page-1.png` … `page-4.png`)
   and finds the page from the lit page dot. Exit 2 means pages were missing:
   auto-move is None, a page is frozen (tap), or the app is not in front.
   Tell the user which, rather than retrying blindly. Needs `idevicescreenshot`,
   which needs the developer disk image mounted (`deploy.sh` mounts it).

2. **Look** at each shot (downscale with `sips -Z 400 page-N.png --out <other file>`;
   never `--out` a directory, which overwrites the originals). Note anything red.

3. **Post** to `#ipad-dashboard` (channel ID `C0CDM45PQR0`). For each page:
   `slack_get_file_upload_url` (filename, exact byte size from `stat -f%z`, alt
   text naming the page), then `URL='<returned url>' && curl -sS -X POST "$URL"
   -H 'Content-Type: image/png' --data-binary @page-N.png`, then
   `slack_complete_file_upload` with the channel ID. Put a one-line summary in the
   first file's `initial_comment`, e.g. "iPadDash 11:31 · all green" or the red
   items; titles: `1 Steps & Claude`, `2 Cluster`, `3 Uptime`, `4 GitHub`.
   The user asked for this channel, so no confirmation per post is needed;
   never post these anywhere else.

Pages: 1 Steps & Claude, 2 Cluster, 3 Uptime, 4 GitHub. If pages are added, pass
the count as the second argument to `capture.sh`.
