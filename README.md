# 🟣 TwitchUnblock

[![Discord](https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?logo=discord&logoColor=white)](https://discord.gg/cEsMRdxsVq)
[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FMXFia19%2FTwitchUnblock%2Fmaster%2Fapps.json&query=%24.apps%5B0%5D.version&label=version&color=9146ff)](https://github.com/MXFia19/TwitchUnblock/releases)

> 💬 **Join the Discord — https://discord.gg/cEsMRdxsVq** — news, help, bug reports and ideas.

**TwitchUnblock** is an open-source Twitch client that lets you watch VODs and
live streams without a subscription, at full quality. Native iOS app built with
SwiftUI — also available [in your browser](https://twitchunblock.vercel.app).

> 🤖 **Vibe-coded project.** TwitchUnblock is built with AI coding assistants
> (prompted, reviewed and tested by a human). Expect rough edges: bug reports
> on Discord help a lot.

**Install it and it works.** There is nothing to configure, no server to set up,
no key to paste. The backend is already hosted and shared by every install.

| | |
|---|---|
| **iOS** | SwiftUI, iOS 16+, sideloaded |
| **Web** | [twitchunblock.vercel.app](https://twitchunblock.vercel.app) — source in [TwitchUnblock-Web](https://github.com/MXFia19/TwitchUnblock-Web) |
| **Setup needed** | None — sign in with Twitch and watch |

---

## ✨ Features

### Watching

* 🚫 **No subscription required** — watch any VOD or live stream at full quality.
* 🎬 **Immersive player** — custom controls drawn over the picture, the way
  Twitch does it. Play/pause, scrubbing, quality, refresh, orientation. Apple's
  native player stays available as a fallback in Settings.
* ⏩ **Double-tap to skip ±10 s** — consecutive taps add up, so three taps read
  "+30 s" instead of three separate "+10 s". On a live there's nothing to skip
  ahead to: in landscape, double-tap shows or hides the chat instead, and once
  you fall behind (pause, network drop) a red **Live** button with the delay
  brings you back to the edge.
* 📺 **Picture-in-Picture** — keep watching while you use other apps.
* ⚙️ **Quality selector** — every resolution the channel broadcasts, Source
  included.
* 🛡 **Ad-free lives, in the source order you pick** — lives come from ad-free
  sources (Luminous Asia, an Albania proxy based on TTV.LOL, Luminous Europe)
  or official Twitch (with ads), tried one after the other until one answers.
  Reorder them in Settings → Player; picking a source from the player's ⋯
  menu (which also shows the source in use) moves it to the top. Channels that
  stream with multiple encodes (Enhanced Broadcasting) keep each quality's own
  name on every source.
* ⏪ **Rewind a live stream (DVR)** — when the channel archives its broadcasts,
  the progress bar covers the *whole* stream, not just the rewindable window.
  Scrub past that window and the recording takes over at that exact moment.
  A **Back to live** button brings you back.
* ⚡ **Low latency mode** — stays as close to the live edge as the connection
  allows.
* 🖥 **Fill the screen** — crops the video to remove the black bars in
  landscape. Cuts off the top and bottom: 16:9 in a phone screen can't do both.
* 🌙 **Sleep timer** — presets or a custom duration, with the countdown shown
  right in the player.
* 📡 **AirPlay** — send the stream to an Apple TV or a compatible TV.
* 🎧 **Spatial audio (AirPods)** — turn it off in the app, head tracking
  included (Settings → Player). iOS doesn't let apps pick "Fixed" or "Head
  Tracked": that choice stays in Control Center.
* 🧭 **VOD chapters** — game changes marked on the progress bar; tap the current
  chapter to jump to another.
* 🔇 **Muted parts** — passages Twitch muted for copyrighted music show in orange
  on the progress bar, with a notice and a **Skip** button. For a day or two
  after a stream, Twitch's CDN still serves the original sound: the app puts it
  back automatically (Settings → Player; not over AirPlay).
* 🗂 **Unlisted & deleted broadcasts** — streams whose VOD is hidden or was
  deleted show up among the channel's VODs as "Unlisted VOD", rebuilt from
  Twitch's CDN as long as it still has them (stream IDs from `vodvod.top`,
  third party).
* ✂️ **Clips** — a Clips tab on every channel (24 h, 7 days, 30 days, all time),
  played with the original chat replayed.
* 📥 **Offline downloads** — download a whole VOD or just a part of it (from one
  time to another, from where you are, the next 10 minutes) in the quality you
  pick, then watch it without a connection from the My VODs tab. With the app
  open, the app downloads the segments itself (four at a time, any error shown
  under the download); when you leave it, what's left goes to iOS's background
  downloads, in batches, and keeps going even with the app closed (resumed if
  you swipe it away). Parts muted for copyrighted music keep their original sound when
  Twitch still has it (a day or two after the stream). The chat can be kept
  too and is replayed offline, emotes included. Export a download as a single
  file (Files, AirDrop, VLC). Pause, resume and delete from the list.
* 🧩 **Multi-live** — up to four lives side by side, on iPad as on iPhone:
  long-press a live card (or use the player's ⋯ menu) to add it — a “+” then
  shows on every card — and tap **Watch** in the bar at the bottom. Tap a
  stream to hear it, open any of them with its chat, add a channel by name.
  Side by side in landscape, stacked in portrait. On iPad (or a large iPhone
  in landscape), the chat of the stream you hear shows on the right — a
  button in the mosaic and Settings → Player turn it on or off.

### Chat

* 💬 **Full live chat** — read and send, with replies.
* 😀 **Emotes** — Twitch, BetterTTV, FrankerFaceZ and 7TV, global and
  per-channel, animated.
* 🏅 **Badges** — global and channel-specific, resolved through Helix.
* 🕘 **Recent messages** — Twitch sends nothing from before you join, so the
  last messages are fetched from `recent-messages.robotty.de` (third party) and
  marked with a clock.
* ⌨️ **Autocomplete** — emotes and names suggested as you type.
* 🗑 **Deleted messages** — optionally kept struck through instead of vanishing.
* 🎨 **Username colour** — changed through Helix (needs a re-login after the
  permission was added).
* 👤 **Tap a message** — opens the person: their avatar, everything they wrote
  in this session, reply, mention, copy.
* 📌 **Pinned messages** — compact banner with badges, emotes, who pinned it and
  a countdown; collapse it to a chip.
* 📊 **Polls, predictions, hype train** — vote, bet channel points on a
  prediction, see the countdown, the results and the winning outcome.
* 🚀 **Raids** — follow the streamer to the raided channel automatically;
  incoming raids shown with a link to the raider. Each of these can be switched off.
* 🔦 **Highlights & filters** — messages mentioning you or containing your words
  stand out; hide bots, `!commands`, muted words or someone in particular.
* 🔥 **Watch streak** and a **follow / unfollow** button.
* 🎁 **Channel points** — balance, rewards, and automatic bonus chest claiming.
* ⏱ **Auto-sync chat delay** — delays the chat by how far behind live you are,
  measured from the stream's timestamps so it doesn't drift each time the
  playlist reloads. Still off on a given stream? Nudge it by ±1 s from the ⏱
  badge above the chat, or in Settings.
* 📼 **VOD chat** — replayed in sync with playback position.

### Drops

* 🎁 **Drops page** (Settings → Drops) — your campaigns in progress with their
  progress bars, every open campaign (all games) with its rewards, a **Claim**
  button and automatic claiming, a step-by-step guide, and a live status that
  tells you whether the stream you're watching counts.
* 📈 **Progress while you watch** — since October 2026, Twitch only counts drops
  when your own account loads the stream. During a live with drops, the app does
  that with small requests, without downloading the video a second time.
* 🔔 **Notifications** — told when a drop is ready to claim, or when the app
  has claimed it for you (Settings → Drops → Notify me).
* Needs the Twitch web session, like channel points. Game accounts must be
  linked: Twitch no longer grants rewards without it.

### Chat layout

* 📐 **Resizable** — drag the divider between video and chat; the width is
  remembered.
* 🪟 **Three landscape layouts** — a column on the right, translucent over the
  picture, or folded away. The player's buttons shift with the chat's width so
  nothing is ever covered.
* 🔠 **Sizing** — font size, message spacing, badge and emote scale,
  timestamps, with a live preview.

### Finding things

* 🏠 **Home** — your followed channels that are live, top streams (France or
  worldwide).
* 🎮 **Categories** — browse by game, then the live channels in it, filtered
  by language if you like (all, or a single one — kept for every category).
  Search puts the exact match first ("valorant" → VALORANT), with sharp box
  art.
* 🏷 **Stream tags** — language, DropsEnabled… under each live stream, like on
  Twitch.
* 🔍 **Search** — by streamer name, channel link, or VOD ID.
* ℹ️ **About** — a channel's description, followers, social links and panels.
* 🕒 **History** — recently watched VODs and channels, each removable.
* 🔄 **Cloud sync** — watch progress and history follow your Twitch account, so
  you pick up where you left off on another device.
* ⬆️ **Update check** — the app tells you when a new version is out on the
  source, with a shortcut to Feather / SideStore / AltStore.
* 🔔 **Live notifications** — be told when a followed channel goes live
  (checked in the background, as often as iOS allows). For instant ones, even
  with the app closed, turn on **ntfy** (Settings → Features in testing): the
  app creates a secret topic, you add it in the free
  [ntfy](https://apps.apple.com/app/ntfy/id1625396347) app, and the backend
  posts there within a minute or two of a stream starting — tapping it opens
  the stream in TwitchUnblock.

### Look & feel

* 🎨 **Themes** — 7 accent colours and 3 backgrounds (dark, OLED black, slate),
  in Settings → General → Appearance.
* 🖼️ **App icons** — six to pick from in Settings → General → Appearance
  (Classic, Purple, Night, Light, Contrast, Neon); the default one has dark
  and tinted versions, and “Contrast” stays the sharpest with iOS 26's clear
  and tinted icons. Drawn by `assets/icons/make_icons.py`; the alternate ones
  ship as separate PNG files (added by `buildipa.sh`), which is what works
  for apps installed with Feather. If the app was signed with a certificate's
  generic identifier (`TEAMID.*`, what Feather 2.9 and KSign 1.6 do with the
  generic profile of a purchased certificate), iOS refuses to change the icon:
  the app reads its own signature and says so. Feather's next version adds a
  **Merge Entitlements** option that fixes the signature.
* 🫧 **Liquid Glass** — optional on iOS 26: a floating tab bar and glass buttons
  over the picture.

### The rest

* 🧰 **Your own Worker** — Settings → Other → Expert settings: if the official
  Workers go down (or the project disappears), give the address of your own
  (deployed from the [website's repository](https://github.com/MXFia19/TwitchUnblock-Web),
  on Cloudflare or with Docker). It's checked, then tried first for lives,
  VODs and playlists; **Send everything through this Worker** also moves
  history backups, feedback, announcements, ntfy notifications and the usage
  count there (your Twitch token is then sent to it — only for a Worker you
  host yourself).
* 🌍 **Four languages** — English (default), French, Spanish and Russian. The
  Russian translation was made with AI: the app says so next to the language
  picker, with a button to report a mistake.
* 🐞 **Bug reports & ideas** — a form in the header, in Settings and in the
  player menu, screenshots included. **My reports** shows where each one stands
  (received, seen, accepted, in progress, done, declined) and the developer's reply,
  and lets you answer back; a badge flags new replies, and open conversations
  refresh on their own.
* 👥 **Switch account** — sign in with another Twitch account from Settings.
  After logging out, the next sign-in asks which account to use instead of
  quietly reusing the previous one.
* 🔐 **Web session check** — the Twitch web session has no known expiry date;
  it's verified at launch, and you're told when it needs restoring instead of
  channel points silently going quiet. It must also be the app's account:
  another account is refused at sign-in (and disconnected if found later), so
  points, drops and predictions never go to the wrong account.
* 📊 **Usage count** — logged in, your Twitch account (counted once across the
  app and the website); logged out, a random install ID. Plus the app version,
  the app language, iPhone or iPad, the iOS version and how many lives and
  VODs were started (which source served a live, failures — counters only),
  at most once an hour. No channels watched, no IP address. Switching it off
  erases it server-side. Public numbers: [/stats](https://twitchunblock.vercel.app/stats). See
  [`Sources/Services/UsageService.swift`](Sources/Services/UsageService.swift).
* 🪵 **System logs** — everything the app does, visible in Settings.

---

## 📲 Installation

TwitchUnblock isn't on the App Store, so it has to be sideloaded.

### AltStore / SideStore / Feather (recommended)

Automatic nightly builds, straight from your sideloader:

1. Open AltStore, SideStore or Feather.
2. Go to **Sources**.
3. Add:
   ```
   https://raw.githubusercontent.com/MXFia19/TwitchUnblock/master/apps.json
   ```
4. Install **TwitchUnblock** from there.

### Manual

Download the latest `TwitchUnblock.ipa` from the
[Releases](https://github.com/MXFia19/TwitchUnblock/releases) page and install it
with Sideloadly, AltStore, or TrollStore if your device supports it.

---

## 📺 Apple TV (test)

A first Apple TV app lives in `TV/` (target `TwitchUnblockTV`, tvOS 16+),
built on its own by `.github/workflows/build-tvos.yml` and published as an
unsigned `tv-test-N` pre-release:

* Followed channels (sign in with a code or a QR code on twitch.tv/activate),
  top streams, categories, search, a channel's VODs.
* tvOS's native player, with Quality, **Chat** and, for lives, Source in its
  bar: the chat (read-only, no account needed) sits on the right of the
  picture — live, or a VOD's chat replayed in sync — with Twitch, BTTV, FFZ
  and 7TV emotes.
* Cards that grow when focused stay above their neighbours; the app has its
  own layered icon and Top Shelf banners (`TV/make_tv_icons.py`, drawn from
  the iPhone app's logo).

Installing it needs a Mac with Xcode and the Apple TV paired with it
(AltStore, SideStore and Feather don't handle tvOS).

---

## 🌐 Web version

**No install? Use it in your browser: https://twitchunblock.vercel.app**

The website has its own repository, [TwitchUnblock-Web](https://github.com/MXFia19/TwitchUnblock-Web),
and shares this app's backend (the Cloudflare Worker, which now lives there too).

What you get on the web:

* Top streams without logging in, followed channels once logged in
* Ad-free lives from the source you pick (settings, or the player's ⚙ menu),
  a few seconds behind live
* Live and VOD player with quality picker, speed, ±10 s, picture in picture, mini player
* Native chat: Twitch, BTTV, FFZ and 7TV emotes, badges, chat history, pinned message, replies
* VOD chat replayed in sync with the video
* Stream tags, clips, categories, Twitch-style links (`/xqc`, `/videos/…`)
* Resume VODs where you left off, history synced with your Twitch account
* English, French, Spanish and Russian

Channel points, drops and betting on predictions are **not** in the web version
and cannot be: they need the `twitch.tv` session cookie, which no third-party
site can read. For those, use the app.

---

## 🛠️ Building from source

**Requirements:** macOS, Xcode 16+, iOS 16.0 deployment target.

```bash
git clone https://github.com/MXFia19/TwitchUnblock.git
cd TwitchUnblock
open TwitchUnblock.xcodeproj
```

Pick your development team under *Signing & Capabilities*, then build the
`TwitchUnblock` scheme onto your device.

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen): run `xcodegen` after adding
files. GitHub Actions builds and publishes nightly IPAs from `master`.

### Versioning

Versions look like `1.1.4`. The first two numbers come from the
[`VERSION`](VERSION) file; the last one counts the builds since that file last
changed, and starts again at 0 when you bump it (edit `VERSION` to `1.2` for a
new series). The internal build number (`CFBundleVersion`) is the CI run number:
it only ever goes up, and it is what the app compares to detect an update.

### Backend

Playlist resolution, cloud sync and the usage count go through a Cloudflare
Worker that this project hosts. Nothing to do if you are just building the app —
it points at the shared instance out of the box.

If you **fork** the project and want your own backend, the Worker code and
deployment notes are in [`worker/`](worker/); change `kAPIURL` in
[`Sources/Constants.swift`](Sources/Constants.swift) to point at it.

---

## ⚠️ Disclaimer

Made for educational and personal use. **TwitchUnblock is not affiliated with,
endorsed by, or sponsored by Twitch Interactive, Inc.** All trademarks and
company names belong to their respective owners.

Support your favourite creators whenever you can.

## 📜 License

MIT — see [`LICENSE`](LICENSE). Do what you want with the code, keep the
copyright notice, and don't hold anyone liable.

This covers the code in this repository, and nothing else: Twitch's
trademarks, its API terms of service and the content on it are not ours to
license.
