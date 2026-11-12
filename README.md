# Matinee

Matinee is a native macOS client for watching YouTube without an account. It is written in Swift and SwiftUI, plays video inside its own window with libmpv, and uses yt-dlp to find streams. You can drive all of it from the keyboard.

It started as a replacement for FreeTube. FreeTube is an Electron app: opening a video took a visible moment, videos often failed to load, and it never looked like a Mac app. Matinee keeps only the parts of FreeTube that were in daily use and tries to do those well.

## Install

You need a Mac with Apple Silicon and macOS 27 or later. In Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/kirakirag/matinee/main/install.sh | sh
```

This downloads the latest release, checks it against its SHA-256 and copies Matinee.app to `/Applications`. Run the same command to update. Quit Matinee first; your subscriptions and history stay where they are.

The app is signed with a self-signed certificate rather than an Apple Developer ID, and it isn't notarized. That's fine with this command, because curl doesn't mark the download as quarantined. If you download `Matinee.zip` from the releases page with a browser instead, macOS blocks it until you allow it under System Settings → Privacy & Security.

## What's in it

The window has a sidebar with one section per tab:

- Search: videos, channels and playlists, with FreeTube's filters for sort order, upload date, type and duration.
- Subscriptions: the newest videos from the channels you follow, newest first. The feed is built from each channel's public RSS feed, opens straight from a local cache and refreshes in the background.
- History: every video you played, with how far you got. A partly watched video resumes where you stopped.
- Playlists: YouTube playlists opened from a link or from a channel page. They play in order and advance on their own. Matinee doesn't make or edit playlists of its own.
- Downloads: videos saved for offline viewing, kept in `~/Movies/Matinee` together with their subtitles.
- For You: recommendations ranked on your Mac (see below).
- Settings.

Channel pages are deliberately small: the latest videos, the channel's playlists, and a subscribe button.

Some other things Matinee does:

- SponsorBlock skips sponsor and self-promotion segments, and U undoes the last skip.
- DeArrow replaces clickbait titles and thumbnails with community ones. When DeArrow has no thumbnail, Matinee shows a frame from the middle of the video, never the uploader's designed thumbnail.
- The player can show a video's top comments in a side panel. This is off by default and read-only.
- Some videos won't play without a YouTube account (age-restricted, members-only, or "confirm you're not a bot"). For those, the player says so and offers to open the video in Brave, in the browser profile you choose in Settings.

## Keyboard

Key presses are handled in the window before they reach the menu bar, so holding an arrow key through a long list doesn't queue up lag. Shortcuts follow the physical key, so they also work with a non-Latin keyboard layout.

| Key | Action |
|---|---|
| ⌘1 to ⌘7, or Q W E R T Y | Switch section (the letters work when you're not typing) |
| ⌘, | Settings |
| ⌘F | Jump to the search field |
| ⌘K | Filter the current list |
| ⌘R | Refresh |
| ⌘P | Bring back the player |
| ⌘B | Show or hide the sidebar |
| ⌘V | Open a copied YouTube video, channel or playlist link |
| ⌘C | Copy the link of the selected item, or of the playing video |
| ⌘⌫ | Delete or unsubscribe (asks first) |
| ↑ ↓ or j k | Move through a list |
| Home End | First or last item |
| ↓ | From the search or filter field into the list |
| Return | Open |
| Escape | Go back to exactly where you were |

In lists, on the selected item:

| Key | Action |
|---|---|
| S | Save for offline |
| D | Subscribe or unsubscribe |
| C | Open the channel |
| X | Not interested in this video (For You) |
| ⇧X | Not interested in this channel (For You) |
| ⌘Z | Undo the last dismissal (For You) or removal (History) |
| Tab | Switch between Videos and Channels (Subscriptions) |
| ⌥1 to ⌥4 | Step through Sort, Date, Type and Duration (Search; with ⇧ to go back) |

In Settings, ↑ ↓ or j k move, ← → or h l change a value, Space or Return toggles or presses, and ⌫ on the models row deletes the downloaded models.

In the player:

| Key | Action |
|---|---|
| Space | Play or pause |
| ← → | Back or forward 5 seconds |
| J L | Back or forward 10 seconds |
| ↑ ↓, - = | Volume |
| , . | Slower or faster |
| F | Fullscreen |
| ⇧N | Next in the playlist, or the first "Up next" video when there's no playlist |
| ⇧P | Previous in the playlist |
| O | Comments and Up next panel (↑ ↓ to move, Return to open, Tab to switch tabs, Escape to close) |
| Q | Quality (↑ ↓ to choose, Return to apply, Escape to close) |
| V | Subtitles, the same way. Matinee remembers the language and turns it on for the next videos that have it |
| A | Audio language, for videos dubbed into other languages. Matinee remembers the choice |
| S | Save for offline |
| D | Subscribe or unsubscribe |
| C | Open the channel |
| U | Undo the last SponsorBlock skip |
| Return | Open in Brave, when a video needs a signed-in account |
| Escape | Leave fullscreen, then shrink to the mini player |
| ⌘Escape | Stop the video, also from the mini player |

Leaving the player (Escape, C, another section) keeps the video playing in a corner while you browse. Click the mini player or press ⌘P to bring it back; its ✕ or ⌘Escape stops the video.

## Settings file

Every setting is also kept in `~/.config/matinee/settings.json`, so you or a script or coding agent can change them as text. Matinee rewrites the file when you change something in Settings and applies an edit to it at once, with no restart. A key you leave out keeps its value. Unknown keys and values of the wrong type are skipped, and Matinee tells you which. If the file isn't valid JSON, nothing changes until you fix it.

```json
{
  "audioLanguage" : "",
  "braveProfile" : "",
  "dearrowThumbnails" : true,
  "dearrowTitles" : true,
  "defaultQuality" : 0,
  "localModels" : true,
  "openglPlayback" : false,
  "recommendations" : true,
  "showComments" : false,
  "sponsorblock" : {
    "filler" : false,
    "interaction" : false,
    "intro" : false,
    "music_offtopic" : false,
    "outro" : false,
    "preview" : false,
    "selfpromo" : true,
    "sponsor" : true
  },
  "subtitleLanguage" : ""
}
```

`defaultQuality` is the highest resolution to play: 2160, 1440, 1080, 720 or 480, or 0 for the best available. `braveProfile` is the Brave profile folder name, such as `Profile 1`; empty means the default profile. `subtitleLanguage` and `audioLanguage` are language codes such as `en` or `pt-BR`, set by the player's V and A menus. An empty `subtitleLanguage` means subtitles are off; an empty `audioLanguage` plays each video in its original language.

## Recommendations without an account

YouTube's recommendations depend on a signed-in account. Matinee builds its own on your Mac instead.

Up next is the list of suggestions from the watch page of the video you're playing. For You collects the suggestions next to your last 20 watches and ranks them by how much each one resembles what you actually watched. Videos and channels you mark "not interested" drop out, and similar ones move down.

With Local AI ranking turned on (the default), Matinee downloads two models from Hugging Face once and runs them on the Mac's GPU through [MLX](https://github.com/ml-explore/mlx-swift):

- [multilingual-e5-large](https://huggingface.co/intfloat/multilingual-e5-large) (2.2 GB, MIT) embeds each video's title and description.
- [JevK5](https://huggingface.co/alibiserikbay/JevK5) (8 GB, Apache-2.0), a fine-tune of Qwen3.5-4B, reads a short profile of your subscriptions, recent watches and dismissals, then reorders the top 40.

The list appears right away and is refined in the background. When something has changed, Matinee re-ranks after the Mac has sat untouched for 10 minutes and nothing is playing, and it stops the moment you come back. Closing the window doesn't quit the app, so this keeps working with the window closed.

To give it more history to learn from, export your YouTube watch history with [Google Takeout](https://takeout.google.com) in JSON format and choose "Import YouTube History…" in Settings.

YouTube only sees which watch pages Matinee loads. It never sees an account, cookies, or the ranking.

`Scripts/recommendations/` has the offline experiments that picked these models and weights.

## How it works

The app and everything it starts run in the macOS App Sandbox. It can reach the network, read and write `~/Movies` and `~/.config/matinee`, and read a file you pick yourself (the Takeout imports). Nothing else outside its container.

- `Matinee/Matinee` holds the SwiftUI app, and `Matinee/MatineeKit` the testable core: the SQLite store, feed, search, the key maps, ranking, SponsorBlock and DeArrow.
- `Matinee/Worker/matinee_worker.py` is a long-running yt-dlp process that the app talks to over stdin and stdout in JSON lines. It resolves streams, searches, lists channels and playlists, and downloads. It runs on a bundled Python, with a URL allowlist, and nothing derived from network data ever picks a program to run.
- yt-dlp solves YouTube's JavaScript challenges with Deno, using Deno's default no-permission sandbox.
- libmpv runs inside the app and draws into the app's own view. `Scripts/mpv/` has the two patches that make that work.
- No web view renders anything from the network.

## Building

You need an Apple Silicon Mac with macOS 27 and Xcode 27. Add Xcode's Metal toolchain once with `xcodebuild -downloadComponent MetalToolchain`. The mpv and ffmpeg scripts copy the pinned Homebrew versions; they list anything missing and install nothing themselves.

```sh
Scripts/fetch_runtime.sh          # Python, yt-dlp and Deno, checked against Scripts/runtime.lock
Scripts/build_mpv.sh              # libmpv with Matinee's patches, into Mpv.bundle
Scripts/bundle_ffmpeg.sh          # ffmpeg, which yt-dlp uses to merge downloads
Scripts/make_signing_identity.sh  # once: a stable local code-signing identity
Scripts/install_app.sh            # Release build, signed, installed to /Applications
```

For development, open `Matinee/Matinee.xcodeproj` and run the Matinee scheme. The tests run in Xcode (MatineeKitTests), and the worker's tests run with `python3 -m unittest test_matinee_worker` from `Matinee/Worker`.

Moving from YouTube? Export your subscriptions with [Google Takeout](https://takeout.google.com) and choose "Import YouTube Subscriptions…" in Settings, then pick `subscriptions.csv`.

Moving from FreeTube? `matinee-import` copies FreeTube's subscriptions and watch history into Matinee's database. Point it at a copy of FreeTube's data folder, not the live one; AGENTS.md has the commands.

## Credits

Matinee depends on [yt-dlp](https://github.com/yt-dlp/yt-dlp), [mpv](https://mpv.io), [FFmpeg](https://ffmpeg.org), [Deno](https://deno.com), [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) and [swift-transformers](https://github.com/huggingface/swift-transformers), and on data from [SponsorBlock](https://sponsor.ajay.app) and [DeArrow](https://dearrow.ajay.app). [FreeTube](https://freetubeapp.io) showed what a private YouTube client could be.

Matinee is not affiliated with YouTube or Google.

## License

Matinee is free software under the GNU General Public License, version 3 or later. See `LICENSE`.

Release builds bundle mpv, FFmpeg and other libraries under their own licenses; `THIRD_PARTY_NOTICES.md` lists them. FFmpeg in those builds is built with GPL components, which is why Matinee is under the GPL. Each release's `Matinee-sources.tar` holds the source of every GPL and LGPL library in it.
