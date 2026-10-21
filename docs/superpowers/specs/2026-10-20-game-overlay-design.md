# Game overlay (Windows) — design

Status: draft for the owner's approval, 2026-10-20.

## Why

When the owner and a friend play a game together in a Hubbub voice call, the game covers the whole screen, so the owner can't see who's talking without leaving the game. Discord solves this with its game overlay. Hubbub should do the same, and it should look and behave like Discord's.

The owner's words (2026-10-20):
- > "next lets add the game overlay feature so i can see the user bubbles appear in game and highlight when someone is speaking"
- > "like discord, small bubbles top left that light up green"
- > "it needs to work with any app in fullscreen, borderless windowed etc"
- > "the modern apporah with teh floating window, maximum campatibility without going overboard"
- > "yes, only when a game is in front"
- > "exactly like discord"

A standing owner rule from earlier sessions: the app looks exactly like Discord, without Discord's trademarks.

## Goals

- **What it shows:** while the user is in a voice call and a game is in front, a small stack of round avatar bubbles appears in the top-left corner of the game, one per person in the call.
- **Speaking:** a bubble lights up with the green speaking ring the moment that person talks.
- **Look:** the same look and behaviour as Discord's voice overlay widget (see "Look" below).
- **Compatibility:** it works in windowed games, borderless-fullscreen games, and the "fullscreen" mode of modern games that Windows 10/11 runs through fullscreen optimizations, i.e. as many games as a floating window can reach.

## Non-goals (not now)

- **True exclusive fullscreen.** That needs code injected into the game. If a specific game the owner plays doesn't show the overlay, that game gets its own decision later.
- **The interactive overlay:** Discord's Shift+` lock mode, dragging the widget, clicking inside the overlay.
- **Notifications in the overlay:** text-chat messages and join toasts.
- **A corner picker.** Top-left only.
- **Mac and Linux.**

## Anti-goals (failure even if it "works")

- Anything that injects into, hooks, or reads the memory of a game process. Anti-cheat could block it or ban the player.
- **Taking input or focus:**
  - stealing focus from the game;
  - ever taking a mouse click or key press;
  - minimising a fullscreen game.
- **Costing frame rate:**
  - a measurable frame-rate cost;
  - a window bigger than the bubbles. A full-screen transparent window forces Windows to compose the game every frame, which can turn off G-Sync/FreeSync.
- Showing up in screen shares or recordings. The friend watching a shared game must not see the overlay.
- Showing over the desktop, a browser, or Hubbub itself.
- Using Discord's name, logo or artwork.

## Look (match Discord's voice widget)

Draw each detail from the current Discord overlay. Check reference screenshots of Discord's 2025+ voice widget before finalising; where Discord and this list disagree, Discord wins. My understanding:
- **Layout:** a vertical list in the top-left corner of the game window's client area (for borderless and fullscreen games, the monitor's corner), with a small margin from the edges. One row per person, in the same order as the voice channel's member list in Hubbub's sidebar (`VoiceMember` list, `app/lib/ui/home_page.dart` `_voiceMembers`).
- **Row:** a round avatar on the left, then the display name in a small rounded, dark, semi-transparent tag.
  - Avatars are Hubbub's own `Avatar` (`app/lib/ui/avatar.dart`): the coloured circle with a letter.
  - The speaking ring is the same green as the app's.
- **Speaking state:**
  - **Speaking:** the avatar gets the green ring and the row is fully opaque.
  - **Not speaking:** the row is drawn dimmer, as Discord does. Check how much against Discord.
- **Muted and deafened:** the same mic and headphone crossed-out icons the sidebar shows, inside or next to the name tag.
- **Who is listed:** the local user is in the list, like Discord.

## Settings (Discord's set, minus what's out of scope)

A "Game Overlay" section in Hubbub's settings dialog (`app/lib/ui/settings_dialog.dart`):

| Setting | Values | Default |
|---|---|---|
| Enable in-game overlay | on / off | on |
| Avatar size | Large / Small | Large |
| Display names | Always / Only while speaking / Never | Always |
| Display users | Always / Only while speaking | Always |

The section also shows one help line: the overlay shows in windowed and borderless games, and some exclusive-fullscreen games need their display mode set to borderless. Store the settings the way the other app settings are stored. Changes apply live.

## When it shows

All of these must hold:
1. The user is connected to a voice call (a voice channel; Hubbub has no other call type).
2. The overlay setting is on.
3. **A game is in front.** The foreground window belongs to another process, and either:
   - (a) its executable is one Windows itself recognises as a game. Windows keeps this list for Game Bar and Game Mode; the builder confirms where it lives (believed to be `HKCU\System\GameConfigStore\Children\*\MatchedExeFullPath`) and that it's reliable. Or:
   - (b) the window covers its whole monitor (fullscreen or borderless), and it's not the desktop/shell, not a browser, and not a video player. Use a short exclusion list by executable name.
4. The foreground window isn't minimised.

**Placement:** at the top-left of the game window's client area, in that monitor's DPI.

**Moving out:** when the game leaves the foreground, the overlay hides at once. When the game comes back, it reappears. When the game window moves or resizes, the overlay follows. Windowed games are in scope (they come in through rule 3a), so following the window matters.

**False positives (my call):** rule 3b also fires for any other fullscreen app that isn't excluded.
- The exclusion list covers the common ones: browsers, video players, PowerPoint's slideshow, remote desktop (`mstsc.exe`), and video-call apps (Teams, Zoom).
- There's no per-app "never show here" override for now. The settings switch is the escape hatch, and an override can come later if false positives annoy.

**What detection may read:** only window-level facts and the executable path (`QueryFullProcessImageNameW` with `PROCESS_QUERY_LIMITED_INFORMATION`). It never opens a game process with read or debug rights, and never lists its modules, because that is exactly what anti-cheat watches for.

## How it's built

**Owner decisions:**
- A separate, see-through window floating on top of the game: Discord's current approach. No injection or hooks into any game. Windows only.

**My calls (owner can veto):**
- **The window itself:**
  - It belongs to the existing Hubbub process (the Windows runner, `app/windows/runner/`), not a new exe.
  - It's a Win32 layered popup with per-pixel alpha: always on top, click-through, never activated, no taskbar entry.
  - It's only as big as the bubbles.
  - It's hidden from capture: `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, Windows 10 2004+. Elsewhere, show it anyway.
  - When the game comes to the front, re-assert the window's topmost position without activating it.
- **Rendering:**
  - Flutter draws the overlay image with the app's own widgets, fonts and colours, so it matches the app exactly. The image goes to the native window over a new method channel.
  - Redraw only when something visible changes: speaking, mute, join/leave, settings, DPI.
  - It must work while the main window is hidden in the tray. That is the normal case during a game, and the first thing to prove, because Flutter's rendering of a hidden window is not guaranteed.
  - The likely route is `dart:ui` `PictureRecorder` → `Picture.toImage`, which doesn't need the window on screen.
  - If that can't be made to work, fall back to native drawing: Direct2D and DirectWrite with the app's bundled font, colours and sizes. The requirement is Discord's look, and native drawing can match it.
  - Don't add a second Flutter engine or window.
- **Game detection:**
  - The native side reports raw facts on foreground changes and window moves: process path, window and monitor rectangles, window class, minimised, own process. Use `SetWinEventHook`, not polling.
  - Dart applies the rules above, so the decision logic is unit-testable in `flutter test`.
- **Developer switch:** a switch, set by environment variable or debug flag, that leaves the overlay capturable. Without it, screenshots can't verify the overlay.
- **Ships in the next normal release (0.1.2), with the speaking-indicator speed fix, from `main`.** Owner, 2026-10-20: "one main branch with one series of builds, no beta etc". It is built from `main` and published as the latest release, so every install auto-updates to it, including the 0.1.2-beta.1 testers.

## Left to the builder

- **Native rendering:** the exact native drawing path, whether `UpdateLayeredWindow` or DirectComposition.
- **Dart image pipeline:** how Dart produces the image, e.g. `PictureRecorder` or an offscreen widget, as long as it works with the window hidden.
- **Data plumbing:**
  - the method-channel shape;
  - where the game-detection rules live in `app/lib`;
  - how the overlay gets the voice member list and settings.
- **The browser and video-player exclusion list,** and how to treat Windows' game list if it proves unreliable.
- **Reacting to changes:** monitor hot-plug and DPI changes.

## Verification

- **Unit tests:**
  - the show/hide rules over the reported facts;
  - which rows are shown under each setting, their order, speaking, mute and deafen.
- **Golden images** of the overlay in both avatar sizes, speaking and not. Goldens are rendered on Windows.
- **Real app on the Windows desktop**, with the developer capture switch on:
  - The overlay appears over a borderless and over a fullscreen test window, and over a real game if one is installed.
  - It hides over the desktop, a browser and Hubbub.
  - It follows the speaking ring in a call.
  - With the switch off, a screenshot does not contain it.
- **Owner and friend:** their usual games, the frame rate with the overlay on and off, and G-Sync behaviour if they use it.
  - *My call:* this is feedback on the 0.1.2 release, not a gate before it ships.
  - The overlay ships on by default, as Discord's does. A bad result means a fix, or off by default, in the next build.
