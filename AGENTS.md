# Installing Matinee for someone

Install with the one-liner in README.md → Install. Then bring their data over: ask whether they're coming from YouTube, FreeTube, or both, and follow those sections. The work is done when Matinee's Settings shows an "Imported …" note for each file and the channels appear under Subscriptions.

Matinee runs in the App Sandbox and reads only a file the person picks in its Open panel, so you prepare the files and they press the button. Settings opens with ⌘,.

## From YouTube (Google Takeout)

1. Walk the person through takeout.google.com while signed in: "Deselect all", tick "YouTube and YouTube Music", then under "Multiple formats" set history to **JSON**, and under "All YouTube data included" keep **history** and **subscriptions**. Export once, as a .zip. Takeout emails a link, often within minutes, sometimes hours.
2. Unzip it into a folder of its own, e.g. `~/Downloads/matinee-takeout/`.
3. Find the two files. Takeout translates folder and file names into the account's language, so search by content rather than by name:
   - **subscriptions**: the `.csv` whose rows start with a channel ID (`UC` + 22 characters), then the channel URL and the title.
   - **watch history**: the `.json` that is an array of objects with `titleUrl` and `time`. An `.html` file means history was exported as HTML; export again with JSON.
4. Tell the person the exact path of each, then have them press, in Settings:
   - "Import YouTube Subscriptions…" → the `.csv`. Existing subscriptions keep their name and avatar; re-importing adds nothing twice.
   - "Import YouTube History…" → the `.json`. It teaches For You and does not appear in History.

## From FreeTube

Subscriptions: in FreeTube, Settings → Data Settings → Export Subscriptions → **YouTube (.csv)**. Matinee's "Import YouTube Subscriptions…" reads that file the same way as Takeout's.

Subscriptions and watch history together: `matinee-import`, built from this repo (needs Xcode).

1. Quit FreeTube and Matinee. Copy FreeTube's data, leaving the live folder alone (the tool refuses to read it):
   `cp -R ~/Library/Application\ Support/FreeTube ~/Downloads/freetube-copy`
2. Build: `cd Matinee && xcodebuild -scheme matinee-import -configuration Release -derivedDataPath build build`
3. Run it against Matinee's database (Matinee must have been opened once, so the file exists):
   `build/Build/Products/Release/matinee-import ~/Downloads/freetube-copy ~/Library/Containers/local.kirakirag.matinee/Data/Library/Application\ Support/Matinee/matinee.sqlite`
   macOS may ask whether Terminal can access another app's data; the person allows it. Success prints `report: channels=… history=…` and exits 0. History imported this way appears in Matinee's History.
