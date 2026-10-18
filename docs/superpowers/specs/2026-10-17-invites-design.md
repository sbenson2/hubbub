# Hubbub — Create a server, invite by link, several servers at once (design)

Status: approved by the owner 2026-10-17 (session 4, Windows). Builds on `2026-10-16-hubbub-design.md` §3.1, §3.2, §4.5 and replaces spike 1's hand-made community files.

## Context
Today the app's only way in is "Import community file": a file built by hand with the CLI.
- Every member's ID must already be listed in it, and existing members reject anyone who isn't listed (`core/src/net.rs:150`).
- A fresh app can't even show its own ID before it's in a community (`core/src/node.rs:145`).
- Texting the file would leak the community's secret key.

Spike 1 used this file as a stand-in, and its plan says the product must remove it. The owner wants Discord's flow (2026-10-17): "i create it, copy a link and send it via text or some other means, using the plus button i make the server and i can occupy it while i wait for my friends just like in discord."

## Owner decisions (2026-10-17)
- **Pure peer to peer links:** `hubbub://join/<code>`, with no web page or domain. Friends paste the link into **Join a Server**, or Hubbub notices it on the clipboard. Where an app makes the link clickable, it opens Hubbub. The owner accepted that most chat apps won't make it tappable.
- **Anyone with a valid link gets in automatically,** let in by whichever member's app is online. If nobody is online, the friend waits: "server isn't online".
- **Several servers at once** on the left rail.
- **Order:** build this before the T8c fixes and T9–T14. The T14 friend tests then use real invites.
- Settled earlier:
  - the creator is the owner;
  - new members see messages only from when they join;
  - Windows is the primary target, macOS second, phones later (T11).

## What the user sees (Discord-like)
1. **First launch:** "What should everyone call you?" asks for a display name, with an initials avatar. No email and no password.
2. **The rail's "+"** opens "Create a server". It has **Create My Own** (name prefilled "<name>'s server") and, at the bottom, "Have an invite already? **Join a Server**".
3. **The new server opens** with `#general` and the `lobby` voice channel, and your PC hosts it. `#general` shows Discord's welcome card with an **Invite your friends** button. You can sit in voice alone.
4. **Invite People** is reached from the server-name dropdown (new chevron menu), the welcome card, or a channel's invite icon. It shows the link with **Copy** (which changes to "Copied"), a **QR code** toggle, and **Edit invite link** for expiry and max uses.
5. **Join a Server** (or pasting or clicking a link) shows the server's name, then **Join**. If no member is online, it says "Nobody from <server> is online right now; Hubbub will keep trying." Once in, you're there for everyone, with no restarts.
6. **Leave Server** is in the same dropdown, and is local only.
7. **"Import community file" is removed everywhere.**

My calls (owner can override):
- Invites expire after 7 days by default, with no use limit (Discord's default). The editor offers 30 minutes, 1 hour, 1 day, 7 days or never, and 1, 5, 10 uses or no limit.
- The clipboard banner only offers; it never joins on its own.
- Renaming yourself or the server, kicking, roles beyond owner, and deleting a server for everyone come later.

## How it works (core)
Validated against the code and iroh 1.3.0.

- **Hub (one per device), new `core/src/hub.rs`:**
  - It owns the identity and **one** iroh endpoint. Two endpoints with one key would clash at the relay and in discovery.
  - It holds `profile.json` and a `hub.lock` taken with `File::try_lock`, so two processes can't share a folder.
  - It holds `communities/<cid>/` per server: state, `text/`, and the LiveKit work dir.
  - Routing uses one ALPN pair per server, `hubbub/ctl/1/<cid>` and `hubbub/sig/1/<cid>`, kept current with `Endpoint::set_alpns`. The session, election and tunnel code stay as they are.
  - `Node::shutdown` closes only its own connections, never the endpoint (`node.rs:311`).
- **Community state v2, `core/src/community.rs`:**
  - Fields: `id`, `name`, `owner`, `secret_hex` (still the shared E2EE and text key; MLS comes later), `channels`, `revoked:[invite_id]`, and `members[{id, name, can_host, door, via_invite, admitted_by, sig}]`.
  - **Member entries are signed** with the iroh `SecretKey::sign` that's re-exported, so no new crate. The owner signs its own entry; the admitting member signs each new one. That lets a newcomer prove membership to members who missed the update (`Rejoin`), which avoids a deadlock between them.
  - The merge is a grow-only union by member ID, so any member can admit and states converge.
  - Saves are atomic (temp file + rename).
  - The full `StateSync`, minus the secret, is sent on every session start and every change. A test checks that 150 members fit the 64 KiB frame.
- **Live membership, `node.rs`, `net.rs`, `proto.rs`:**
  - `tokio::sync::watch<Arc<CommunityState>>` replaces the frozen file at `node.rs:145,151,225,270,453,468,924` and the accept check at `net.rs:150`.
  - A state change spawns dial loops for new members.
  - Adds `NodeEvent::MembersChanged` and `CtlMsg::StateSync`.
  - The protocol version goes to v1, because `read_loop` is exhaustive (`node.rs:671`).
- **Joining through a "door," new `core/src/join.rs`:**
  - Each hub runs a second, **relay-only** endpoint, `clear_ip_transports()`, with a key derived from the identity. It accepts only `hubbub/join/1`.
  - That keeps strangers from ever learning a member's IP address (spec security requirement). A rejected stranger dialing the main endpoint would still get address exchange.
  - The door is rate-limited globally.
  - Requests: `JoinRequest{cid, link, name, can_host}` gets back `JoinAccepted{state + secret}` or `JoinDenied{expired | revoked | used_up | unknown_inviter}`.
  - An existing member is simply accepted again.
- **Invite link, new `core/src/invite.rs`:**
  - Contents: version, cid, invite id, expiry, max uses, server name (≤24 bytes), up to 3 door IDs (the inviter first), and the inviter's signature.
  - That's about 216 bytes, or roughly 300 characters base64url, which is an easy QR.
  - The rules live in the signed link, so any member can check an invite it never saw. Uses are counted from `via_invite`.
  - Max uses can be exceeded if members admit while cut off from each other; this is documented.
  - Links are created offline. The parser tolerates surrounding text, whitespace and trailing punctuation.
- **Media for several servers:** one LiveKit per machine, in a new `SharedMedia` (`core/src/node/hosting.rs` plus a new module).
  - The first server to host starts it and maps UPnP once; the last to release stops it.
  - The host names rooms `<cid>.<channel>` when minting tokens, so one server's members can't enter another's rooms. The app keeps sending bare channel names.
  - `media_host.rs` is unchanged, and `handover.rs:219,317` expect the prefixed names.
- **Old spike community files are dropped.** No users have them, and they can't be signed retroactively.
  - The test helpers build signed v2 state.
  - The CLI gets `id`, `profile name`, `community new|list`, `invite <cid> [--hours --uses]`, `join <link>` and `run [--community <cid>]`, with `--root` required on Windows.

## App changes
- **FRB API, `app/rust/src/api/hubbub.rs`:**
  - `AppNode` stays per server, holding `Arc<Node>`, so the existing `node_*` calls and `NodeController` survive.
  - Adds `hub_open`, `hub_member_id/tag`, `profile_name/set_profile_name`, `hub_communities`, `hub_node(cid)`, `community_create`, `node_invite_create`, `invite_parse` (sync), `hub_join(link, StreamSink<AppJoinEvent{Trying, Offline, Denied, Joined}>)`, `hub_join_cancel`, `hub_leave` and `hub_shutdown`.
  - Bindings are regenerated with `flutter_rust_bridge_codegen generate` in `app/`, which pins FRB 2.13.0.
- **Dart:**
  - New `hub_controller.dart` holds a `NodeController` per server. `home_page.dart` builds the rail from every server and keys calls by (server, channel).
  - `community_rail.dart`'s "+" opens the create dialog, replacing `onImport`. `channel_sidebar.dart` gets the header chevron menu.
  - Dialogs reuse `showSettingsDialog`'s shell, `HubButton` (`user_panel.dart:211-282`) and `HubColors`.
  - The clipboard check runs when the app gains focus.
- **Windows:**
  - `app_links 7.2.2` handles links at cold start and from a running app.
  - `windows/runner/main.cpp` calls `SendAppLinkToInstance()`, so a second launch focuses the running window and passes the link on.
  - The runner registers `HKCU\Software\Classes\hubbub` (`URL Protocol` plus `"<exe>" "%1"`) on every launch, and adds a named mutex keyed by data folder.
  - A `HUBBUB_ROOT` environment override lets two instances run side by side for testing.
- **macOS:** `CFBundleURLTypes` in `Info.plist`.
- **New dependencies** (pinned, need owner approval): `app_links 7.2.2` (MIT) and `qr_flutter 4.1.0` (BSD-3).

## Tasks (detail in docs/superpowers/plans/2026-10-17-invites.md)
They run in order, one heavy agent at a time, and each task gets a fresh implementer, a review, and a local commit:
1. **State v2 and signing.** Tests cover the signature chain, forgery, merge order-independence, owner mismatch, and 150 members fitting in a frame.
2. **Link codec.** Tests cover round-trip, tampering, ≤310 characters, and messy pasted text.
3. **Live membership.** A new `core/tests/membership.rs` checks that a member added at runtime connects without a restart and that three nodes converge.
4. **Hub.** Tests use `MemoryLookup`: two hubs share two servers, a third hub is in only one, and leaving drops the ALPN.
5. **SharedMedia.** Tests check that FakeHost starts once, rooms get the prefix, and UPnP is mapped once and unmapped on the last release.
6. **Door and join.** Tests cover accepted; expired, revoked, max-uses and unknown-inviter denials; an existing member; offline then online; and `Rejoin` healing the deadlock.
7. **CLI,** plus a local two-folder smoke test: create, invite, join and text.
8. **Two-machine CLI smoke test,** Windows and the Mac, run from the main session.
9. **FRB API,** codegen and Rust unit tests.
10. **Dart hub controller and multi-server rail.** Widget tests with a fake hub.
11. **Dialogs:** display name, "+" create/join, Invite People (copy and QR), join progress, clipboard banner, and Leave. The goldens are re-rendered on Windows, and the real app is shown after each UI change.
12. **Windows link handling:** single instance, scheme registration and `HUBBUB_ROOT`.
13. **macOS URL scheme.**
14. **End to end** (below).
15. **Then resume spike 1:** the T8c fix round, then T9–T14.

The spike-1 ledger records T8c's "voice roster" fix as building on `MembersChanged`.

**Process:**
- This session is about 210k tokens, so after approval it:
  1. commits the pending session-4 work locally, as two commits: the `.gitignore`, then the logo plus Windows LiveKit;
  2. writes this design to `docs/superpowers/specs/2026-10-17-invites-design.md` and the task plan to `docs/superpowers/plans/2026-10-17-invites.md` (committed);
  3. updates `HANDOFF.md` and the ledger.
- Implementation then starts in a fresh session using `subagent-driven-development`.
- Builds over 4 minutes run in the main session in the background:
  - the first `cargo test` on Windows;
  - a cold `flutter build windows --release`, about 4 minutes;
  - the Mac build.
- Everything stays local. Nothing is pushed.

## Verification
- **Core:**
  - `cargo test -p hubbub-core --features test-util` on Windows. The baseline is lib 77 passed and 4 ignored, handover 10, text 5, all of which should still pass.
  - Plus the new membership, hub, door and join, and invite tests, all hermetic.
- **App:** `flutter analyze lib test` is clean, and `flutter test` passes on Windows, including the new widget tests and the re-rendered goldens.
- **End to end on this PC:** two instances with `HUBBUB_ROOT=A` and `B`.
  1. A sets a name, clicks **+**, creates "Shawn's server", and sits in `lobby` alone.
  2. A clicks Invite People, then Copy.
  3. B gets the link three ways: pasted into Join a Server, picked up from the clipboard banner, and run as `start hubbub://join/...` with B both closed and open.
  4. Both see each other online, and text works both ways.
  5. B joins `lobby` with A, and the e2ee track shows up.
  6. Closing A hands hosting to B, and the call resumes.
  7. An expired link and a revoked link are refused with clear messages.
  8. With nobody online, B shows the waiting message, then joins when A starts.
- **Several servers:** B creates its own server and invites A. Both rails show two servers, and one machine hosts both at once with a single `livekit-server.exe`.
- **Two machines:** the Mac app joins the Windows server by pasted link; text and voice work. Screenshots of each step go to the owner.
