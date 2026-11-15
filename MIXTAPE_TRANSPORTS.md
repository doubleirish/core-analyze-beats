# Mixtape transfer methods

analyze-this (PC) builds a self-contained mixtape package (`manifest.json`, `playlist.m3u8` with relative paths, `songs/`, `art/`) and sends it to beats-me (Android). Each mix has a stable id (`<pc id>-<random>`) that follows it through renames, so re-sending updates the phone's copy instead of duplicating it.

The phone accepts a package from any method and installs it under that method's label:

```
<music root>/Mixtapes/<label>/<name> [<id6>]/
```

A ledger (`.ledger.json`) maps `label:id` to its folder. Renames move the folder. Stale songs are removed only inside that mix's folder. Ledgers and caches are written to a temporary file and renamed, so an interrupted write can't corrupt them.

Per-track manifest fields beyond tags and tempo (all optional; older players ignore them):
- `start` / `end`: trim points in seconds; playback and plans are relative to `start`.
- `loudness`: integrated loudness (LUFS) used for volume levelling.
- `note`: the instructor's cue for that song in this mix.
- `explicit`: explicit by the user's mark or the lyrics check.

## Methods

| Label | PC (analyze-this: **Send to phone…**) | Phone (beats-me: Library → **Import mixtape from PC** icon) |
|---|---|---|
| push (Wi-Fi) | Pick a phone found on the network → Send. The first time, the phone asks "Allow <PC>?" and both show the same 6-digit code. | The first time, keep the Import screen open to allow the PC. After that, with "Receive mixes from PC while beats-me is open" (on by default once a PC is allowed) the phone receives from allowed PCs whenever beats-me is in front; a send that's running finishes in the background (foreground service). |
| usb | Plug in a phone with USB debugging on → Send. Uses adb; only changed songs are copied. | Opens automatically and imports. Unplugged sends are picked up on next app resume. |
| pull (QR) | Shows a QR code; the server keeps running after the dialog closes (chip in the mix screen → Stop). | **Scan QR** (or the system camera opens the `beatsme://` link). |
| zip (.beatsmix) | Saves `<name>.beatsmix`; share it with Quick Share, Drive, email, etc. | Tap the file / "Open with beats-me", or **Open .beatsmix**. |
| folder | More methods → export to a folder | Advanced → Exported folder |
| syncdir | More methods → write into a synced folder (manifest last) | Advanced → Sync folder (watched) |

Fixed ports: push 47820/TCP, discovery 47821/UDP, pull 47822/TCP. If a port is busy, a random one is used and advertised via discovery/QR.

Defaults that need no setup:
- **Auto preset**: Android-playable files (mp3, m4a/aac/alac, flac, ogg, opus, wav) are copied; others (wma, aiff, ape, wv, dsf…) are transcoded to AAC 256 if ffmpeg is available.
- Incremental sending is on: unchanged songs are skipped. Interrupted pushes are re-sent per file.
- The mix icon and program name are included in every method, including folder, zip and syncdir.
- The dialog remembers the last method and target per mix.
- The PC is kept awake while sending.

Pre-flight checks run before Send. Errors disable Send; warnings explain the risk:
- missing files
- songs flagged as damaged audio (the phone also records the reason per song)
- unplayable formats without ffmpeg
- phone reachable, version, free space
- same subnet
- adb device authorised
- folder exists

## Troubleshooting

- **Phone not found / unreachable (push)**
  - PC and phone must be on the same Wi-Fi. Guest networks and "AP/client isolation" block device-to-device traffic.
  - Use the QR or .beatsmix method instead, or enter the address shown on the phone under Advanced.
- **Pull: phone can't connect**
  - Windows Firewall blocks inbound connections to the PC. Allow analyze-this when Windows asks, or add an inbound rule for TCP 47822 (private network).
- **Pairing refused / "not trusted"**
  - Re-pair from the dialog. The phone lists trusted PCs under Advanced, and you can remove them there.
- **USB: no device / unauthorized**
  - Enable Developer options → USB debugging, then accept the "Allow USB debugging" prompt on the phone.
  - Set the adb path under Advanced if it isn't on PATH or in `%LOCALAPPDATA%\Android\Sdk\platform-tools`.
  - The first USB import needs the "All files access" permission.
- **Some songs skipped**: install ffmpeg (set its path under Advanced) so Auto can transcode formats Android can't play.

## Benchmark template (fill in on a real phone)

Use the same mixtape (e.g. 50 songs, ~300 MB), once with original files and once transcoded.

| Method | Setup steps | Time first send | Time re-send (1 song changed) | Failures/retries | Works w/o Wi-Fi | UX 1-5 | Keep? |
|---|---|---|---|---|---|---|---|
| push (Wi-Fi) | | | | | | | |
| usb (adb) | | | | | | | |
| pull (QR) | | | | | | | |
| zip via Quick Share | | | | | | | |
| zip via cloud/email | | | | | | | |
| folder | | | | | | | |
| syncdir | | | | | | | |

After each method, check:
- the playlist opens in beats-me
- songs play
- BPM and segments are present (no re-analysis)
- cover art, artist and album are shown
- re-sending does not duplicate the mix
- renaming the mix on the PC renames it on the phone

To remove a method that loses the benchmark, delete:
- its transport class (`lib/services/mixtape/transports.dart`, `http_transport.dart`, `usb_transport.dart`)
- its `Transport` constant
- its tile in analyze-this `send_dialog.dart` and its action in beats-me `mixtape_screen.dart`
- its tests in `test/mixtape_test.dart`
