import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio_settings.dart';
import '../device_settings.dart';
import '../hub_controller.dart';
import '../install.dart';
import '../links.dart';
import '../node_controller.dart';
import '../room_adapter.dart';
import '../share_sources.dart';
import '../src/rust/api/hubbub.dart';
import '../text_controller.dart';
import '../video_options.dart';
import 'audio_menus.dart';
import 'avatar.dart';
import 'call_stage.dart';
import 'channel_sidebar.dart';
import 'community_rail.dart';
import 'dialogs/clipboard_banner.dart';
import 'dialogs/create_server_dialog.dart';
import 'dialogs/invite_dialog.dart';
import 'dialogs/join_dialog.dart';
import 'dialogs/leave_dialog.dart';
import 'dialogs/name_dialog.dart';
import 'dialogs/share_picker_dialog.dart';
import 'dialogs/update_banner.dart';
import 'member_list.dart';
import 'settings_dialog.dart';
import 'text_channel_view.dart';
import 'video_view.dart';
import 'theme.dart';
import 'user_panel.dart';
import 'voice_channel_view.dart';

/// Below this width the member list hides and the channel column becomes a drawer.
const narrowWidth = 700.0;

/// The Discord-style shell: community rail, channel column, the open channel, and the
/// member list.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.controller,
    this.hub,
    required this.room,
    required this.loadConfig,
    this.onAddServer,
    this.clock,
    this.linkSource,
    this.deviceStore,
    this.audioStore,
    this.updates,
    this.windowsSettings,
    this.shareSources = desktopShareSources,
    this.shareStillExists = desktopSourceExists,
    this.screenShareAvailable,
    this.setFullscreen = setWindowFullscreen,
  }) : assert((controller == null) != (hub == null), 'give a controller or a hub');

  /// A single server (the pre-hub path); [hub] holds every server.
  final NodeController? controller;
  final HubController? hub;

  /// Replaces the rail's "+" (Create a server); tests use it.
  final VoidCallback? onAddServer;
  final RoomAdapter room;

  /// What the Share Your Screen picker lists; tests give a fixed list.
  final ShareSourceLoader shareSources;

  /// Whether the shared screen or window is still there (it ends the share when it is not).
  final ShareSourceCheck shareStillExists;

  /// Whether this session can share a screen at all; null decides from the platform.
  final bool? screenShareAvailable;

  /// Puts the whole window in (or takes it out of) full screen for a focused stream.
  final Future<void> Function(bool) setFullscreen;
  final Future<AppNodeConfig> Function() loadConfig;

  /// Where `hubbub://` links come from; each opens the Join dialog once a name is set.
  final LinkSource? linkSource;

  /// Where the microphone, speaker and camera choices are kept; in memory when null (tests).
  final DevicePrefsStore? deviceStore;

  /// Where the output volumes are kept; in memory when null (tests).
  final AudioPrefsStore? audioStore;

  /// Self-update state for the "Update ready" banner; null when this build does not update.
  final UpdateController? updates;

  /// The Windows switches in User Settings (start at login); null elsewhere.
  final WindowsSettings? windowsSettings;

  /// Replaces the wall clock for message times (tests).
  final DateTime Function()? clock;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  late final HubController _hub;
  late final NodeController _idle;
  final _texts = <String, TextController>{};
  final _views = <String, ChannelRef>{};
  final _attached = <String, NodeController>{};
  late final DeviceSettings _devices;
  late final AudioSettings _audio;
  StreamSubscription<RoomSignal>? _signalSub;
  StreamSubscription<List<RoomParticipant>>? _peopleSub;
  List<RoomParticipant> _people = const [];

  /// The voice channel whose call we are in (and its server), and the one being joined.
  /// Switching server leaves the call running, as Discord does.
  _Call? get _call => _callValue;
  set _call(_Call? c) {
    final before = _callValue;
    _callValue = c;
    // Every member sees who is in voice. A rejoin after a host change keeps the same
    // channel, so it says nothing; any other end of a call says "none" to the old server.
    if (before != null && (c == null || c.node != before.node || c.channel != before.channel)) {
      before.node.setVoice(null);
    }
    if (c != null && (before == null || c.node != before.node || c.channel != before.channel)) {
      c.node.setVoice(c.channel, muted: _muted, deafened: _deafened);
    }
    // Camera and share belong to the call: a new call starts with both off.
    if (c == null) {
      _cameraOn = _sharing = false;
      _shareSource = null;
      _watching.clear();
      _requested.clear();
      _seenSharing.clear();
      _watchGrace?.cancel();
      _focus = null;
      _rx.clear();
    }
    _inCall.value = c != null;
    widget.updates?.callActive.value = c != null;
  }

  _Call? _callValue;

  /// Whether a call is up, for the settings dialog's mic meter.
  final _inCall = ValueNotifier<bool>(false);
  (String, String)? _joining;
  bool _muted = false;
  bool _deafened = false;
  bool _cameraOn = false;
  bool _sharing = false;

  /// The screen or window being shared, so a host change can share it again.
  String? _shareSource;

  /// Whose screen shares you clicked Watch on (member ids; a share's track id changes when
  /// the room does), the track ids already asked for, and which of them have been seen in
  /// this room. A watch whose stream is gone is forgotten, so a later share needs a new click.
  final _watching = <String>{};
  final _requested = <String>{};
  final _lastSid = <String, String>{};
  final _seenSharing = <String>{};
  Timer? _watchGrace;
  Timer? _shareWatch;

  /// The tile shown large (a [StageItem.key]), if any.
  String? _focus;

  /// The stream stats panel, and the latest received sample for the watched stream.
  bool _showStats = false;
  final _rx = <String, VideoRxSample>{};
  bool _cameraBusy = false;
  bool _shareBusy = false;
  bool _mutedBeforeDeafen = false;
  bool _memberList = true;
  bool _starting = false;
  String? _error;
  LinkRouter? _links;

  /// An unseen invite found on the clipboard, offered in a banner.
  AppInvitePreview? _offered;
  String? _offeredLink;
  final _seenLinks = <String>{};

  /// Only the multi-server hub can create, join and leave.
  bool get _multi => widget.hub != null;

  /// The selected server's controller; an unstarted placeholder when there is none.
  NodeController get _node => _hub.current ?? _idle;
  String get _key => _hub.selectedCid ?? '';
  ChannelRef? get _view => _views[_key];

  TextController get _text => _texts.putIfAbsent(_key, () {
        final n = _node;
        return TextController(
          service: n,
          events: n.events,
          me: () => n.memberId,
          clock: widget.clock,
        );
      });

  /// The call's voice channel, when it is in the server on screen.
  String? get _callHere => _call?.key == _key ? _call!.channel : null;

  @override
  void initState() {
    super.initState();
    _idle = NodeController();
    _hub = widget.hub ?? HubController.single(widget.controller!);
    _hub.addListener(_refresh);
    _devices = DeviceSettings(widget.room, widget.deviceStore ?? DevicePrefsStore.memory());
    unawaited(_devices.start());
    _audio = AudioSettings(widget.room, widget.audioStore ?? AudioPrefsStore.memory());
    unawaited(_audio.start());
    WidgetsBinding.instance.addObserver(this);
    _attach();
    _signalSub = widget.room.signals.listen(_onSignal);
    _peopleSub = widget.room.participants.listen((p) {
      setState(() => _people = p);
      _syncWatching(p);
    });
    _openFirstChannel();
    if (widget.controller != null && !_node.started) {
      _starting = true;
      unawaited(_startIfConfigured());
    }
    if (_multi) {
      final source = widget.linkSource;
      if (source != null) {
        _links = LinkRouter(source, _openLink);
        unawaited(_links!.start());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _askName();
        // Links that arrived before the name was asked for wait for it. If the person
        // dismissed the dialog or saving failed, they open anyway: the core has a default name.
        _links?.markReady();
        await _checkClipboard();
      });
    }
  }

  /// First run: nobody has a display name yet.
  Future<void> _askName() async {
    if (!mounted || _hub.profileName.isNotEmpty) return;
    final name = await showNameDialog(context);
    if (name == null) return;
    try {
      await _hub.setProfileName(name);
    } catch (e) {
      _toast('Could not save your name: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _multi) unawaited(_checkClipboard());
  }

  /// Offers an invite on the clipboard once; it never joins by itself.
  Future<void> _checkClipboard() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {
      return;
    }
    if (!mounted || text == null || text.isEmpty || _seenLinks.contains(text)) return;
    final preview = _hub.inviteParse(text);
    if (preview == null) return;
    // An invite to a server we are already in is our own (Copy in the Invite dialog).
    if (_hub.communities.any((c) => c.cid == preview.cid)) return;
    _seenLinks.add(text);
    setState(() {
      _offered = preview;
      _offeredLink = text;
    });
  }

  Future<void> _openLink(String link) async {
    if (!mounted) return;
    await showJoinDialog(context, _hub, link: link);
  }

  void _joinOffered() {
    final link = _offeredLink;
    setState(() => _offered = null);
    if (link != null) showJoinDialog(context, _hub, link: link);
  }

  void _invite() {
    final cid = _hub.selectedCid;
    if (cid == null) return;
    showInviteDialog(context, _hub, cid: cid, serverName: _node.communityName);
  }

  Future<void> _leaveServer() async {
    final cid = _hub.selectedCid;
    if (cid == null) return;
    if (!await confirmLeaveServer(context, _node.communityName)) return;
    try {
      await _hub.leave(cid);
    } catch (e) {
      _toast('Could not leave the server: $e');
    }
  }

  @override
  void dispose() {
    _devices.dispose();
    _audio.dispose();
    _inCall.dispose();
    _watchGrace?.cancel();
    _shareWatch?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _links?.dispose();
    _hub.removeListener(_refresh);
    for (final n in _attached.values) {
      n.removeListener(_refresh);
    }
    _signalSub?.cancel();
    _peopleSub?.cancel();
    for (final t in _texts.values) {
      t.dispose();
    }
    if (widget.hub == null) _hub.dispose();
    _idle.dispose();
    super.dispose();
  }

  /// Each server's controller notifies on its own, so listen to every one.
  void _attach() {
    for (final c in _hub.communities) {
      final n = _hub.node(c.cid);
      final old = _attached[c.cid];
      if (identical(old, n)) continue;
      old?.removeListener(_refresh);
      _attached[c.cid] = n;
      n.addListener(_refresh);
    }
  }

  /// Drops everything held for servers that are no longer in the hub, so re-joining the
  /// same cid starts fresh, and hangs up a call that was in one of them.
  void _prune() {
    final live = {for (final c in _hub.communities) c.cid};
    for (final cid in _attached.keys.where((k) => !live.contains(k)).toList()) {
      _attached.remove(cid)!.removeListener(_refresh);
      _texts.remove(cid)?.dispose();
      _views.remove(cid);
    }
    if (_call != null && !live.contains(_call!.key)) unawaited(_leave());
  }

  void _refresh() {
    setState(() {
      _prune();
      _attach();
      _openFirstChannel();
    });
    _followHost();
  }

  /// The call's media room lives on the server's host. When the host changes (including when
  /// we were the host), the old room is gone, so join the same channel on the new host.
  void _followHost() {
    final call = _call;
    if (call == null || _joining != null || _rejoining) return;
    final host = call.node.host;
    if (host == null || (host == call.host && call.node.term == call.term)) return;
    unawaited(_rejoin(call));
  }

  bool _rejoining = false;

  Future<void> _rejoin(_Call call) async {
    _rejoining = true;
    // The new room has new track ids: watches are asked for again as their streams show up,
    // and dropped if they do not within a few seconds.
    _requested.clear();
    _seenSharing.clear();
    _watchGrace?.cancel();
    if (_watching.isNotEmpty) {
      _watchGrace = Timer(const Duration(seconds: 15), () {
        if (mounted) setState(() => _watching.removeWhere((id) => !_seenSharing.contains(id)));
      });
    }
    try {
      final c = await call.node.credentials(call.channel);
      if (!mounted || _call != call) return;
      _requireIce(c);
      // The old room is gone: drop it first, so the device choices below are not applied to
      // (and capture restarted on) a room that is about to die anyway.
      await widget.room.disconnect();
      await _devices.applyForJoin();
      await _audio.applyForJoin();
      if (!mounted || _call != call) return;
      try {
        await widget.room.connect(c.url, c.token, c.e2EeKey, ice: c.ice);
      } catch (_) {
        // The new host's media server may be a moment late: one more try before giving up.
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted || _call != call) return;
        // Another host took over meanwhile, so these credentials are stale: the finally below
        // follows the new host instead. (With no host at all, retry as before.)
        final now = call.node.host;
        if (now != null && (now != c.host || call.node.term != c.term.toInt())) return;
        await widget.room.connect(c.url, c.token, c.e2EeKey, ice: c.ice);
      }
      await widget.room.setMicrophoneEnabled(!_muted);
      await widget.room.setDeafened(_deafened);
      if (mounted && _call == call) await _republishVideo();
      if (mounted && _call == call) {
        setState(() => _call = _Call(call.key, call.channel, call.node, c.host, c.term.toInt()));
      }
    } catch (e) {
      _toast('Could not rejoin ${call.channel}: $e');
      // Do not leave a half-connected room live while the UI shows no call.
      try {
        await widget.room.disconnect();
      } catch (_) {}
      if (mounted && _call == call) setState(() => _call = null);
    } finally {
      _rejoining = false;
      // A host change that landed meanwhile was skipped; check again.
      if (mounted) _followHost();
    }
  }

  /// A new room starts with nothing published: put back the camera that was on. A failure
  /// here must not end the call, so it turns the control off and says so.
  Future<void> _republishVideo() async {
    if (_cameraOn) {
      try {
        await widget.room.setCameraEnabled(true);
      } catch (e) {
        _toast('Could not turn the camera back on: $e');
        if (mounted) setState(() => _cameraOn = false);
      }
    }
    if (_sharing) {
      try {
        await widget.room.setScreenShareEnabled(true, sourceId: _shareSource);
      } catch (e) {
        _toast('Could not start sharing again: $e');
        if (mounted) setState(() => _sharing = false);
      }
    }
  }

  Future<void> _toggleCamera() async {
    if (_cameraBusy) return;
    _cameraBusy = true;
    final on = !_cameraOn;
    setState(() => _cameraOn = on);
    try {
      await widget.room.setCameraEnabled(on);
    } catch (e) {
      _toast('Could not turn the camera ${on ? 'on' : 'off'}: $e');
      if (mounted) setState(() => _cameraOn = !on);
    } finally {
      _cameraBusy = false;
    }
  }

  VideoFeed? _shareOf(String id) {
    for (final p in _people) {
      if (p.id == id) return p.share;
    }
    return null;
  }

  Future<void> _watch(VoiceMember m) async {
    final sid = m.share?.sid;
    if (sid == null) return;
    setState(() {
      _watching.add(m.id);
      _seenSharing.add(m.id);
      _focus = 'stream:${m.id}';
    });
    _lastSid[m.id] = sid;
    if (_requested.add(sid)) await widget.room.subscribeVideo(m.id, sid, true);
  }

  Future<void> _unwatch(String id) async {
    final sid = _shareOf(id)?.sid;
    setState(() {
      _watching.remove(id);
      _seenSharing.remove(id);
      if (_focus == 'stream:$id') _focus = null;
      _rx.remove(id);
    });
    if (sid != null) {
      _requested.remove(sid);
      await widget.room.subscribeVideo(id, sid, false);
    }
  }

  /// Keeps the watches in step with who is sharing: asks for a watched stream that has
  /// (re)appeared, and forgets one that has ended.
  void _syncWatching(List<RoomParticipant> people) {
    for (final id in _watching.toList()) {
      final sid = people.where((p) => p.id == id).firstOrNull?.share?.sid;
      if (sid != null) {
        _seenSharing.add(id);
        _lastSid[id] = sid;
        if (_requested.add(sid)) unawaited(widget.room.subscribeVideo(id, sid, true));
      } else if (_seenSharing.contains(id) && !_rejoining && _call != null) {
        setState(() {
          _watching.remove(id);
          _seenSharing.remove(id);
          _rx.remove(id);
          _requested.removeWhere((r) => r == _lastSid[id]);
          if (_focus == 'stream:$id') _focus = null;
        });
      }
    }
  }

  /// A camera focused is received at its best layer, and back at the grid's layer when closed.
  void _setFocus(String? key) {
    final old = _focus;
    setState(() => _focus = key);
    unawaited(_cameraQuality(old, high: false));
    unawaited(_cameraQuality(key, high: true));
  }

  Future<void> _cameraQuality(String? key, {required bool high}) async {
    if (key == null || !key.startsWith('user:')) return;
    final id = key.substring(5);
    for (final p in _people) {
      final sid = p.camera?.sid;
      if (p.id == id && !p.isLocal && sid != null) {
        await widget.room.setVideoQuality(id, sid, high: high);
      }
    }
  }

  void _closeFocused(StageItem item) {
    if (item.stream && !item.member.isMe) {
      unawaited(_unwatch(item.member.id));
    } else {
      _setFocus(null);
    }
  }

  /// The focused picture alone over the whole window, as Discord's full screen.
  Future<void> _openFullscreen(StageItem item) async {
    final feed = item.stream ? item.member.share : item.member.camera;
    if (feed == null) return;
    await widget.setFullscreen(true);
    if (!mounted) return;
    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => _FullscreenStream(
        feed: feed,
        mirror: !item.stream && item.member.isMe,
        updates: widget.room.participants,
        // The picture to show now: a rejoin gives it a new track, and the stream may end.
        current: (people) {
          for (final p in people) {
            if (p.id == item.member.id) return item.stream ? p.share : p.camera;
          }
          return null;
        },
      ),
    ));
    await widget.setFullscreen(false);
  }

  /// Stop Streaming, or open the picker and Go Live on what it returns.
  Future<void> _toggleShare() async {
    if (_shareBusy) return;
    _shareBusy = true;
    try {
      if (_sharing) return await _stopShare();
      final available = widget.screenShareAvailable ??
          screenShareSupported(isLinux: Platform.isLinux, env: Platform.environment);
      if (!available) return _toast(shareUnsupported);
      final source = await showSharePicker(context, widget.shareSources);
      if (source == null || !mounted || _call == null) return;
      setState(() {
        _sharing = true;
        _shareSource = source;
      });
      try {
        await widget.room.setScreenShareEnabled(true, sourceId: source);
        _watchShare(source);
      } catch (e) {
        _toast(defaultTargetPlatform == TargetPlatform.linux
            ? shareUnsupported
            : 'Could not start the stream: $e');
        if (mounted) setState(() => _sharing = false);
      }
    } finally {
      _shareBusy = false;
    }
  }

  /// The desktop plugin never says when a captured window closes, so look for it: when the
  /// shared screen or window is gone, the share is over.
  void _watchShare(String source) {
    _shareWatch?.cancel();
    var checking = false;
    _shareWatch = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (!mounted || !_sharing || _shareSource != source) return t.cancel();
      if (checking) return;
      checking = true;
      try {
        if (!await widget.shareStillExists(source) && mounted && _sharing && _shareSource == source) {
          _toast('The shared window closed, so the stream ended.');
          t.cancel();
          await _stopShare();
        }
      } catch (_) {
        // Listing failed this time: keep sharing and look again.
      } finally {
        checking = false;
      }
    });
  }

  Future<void> _stopShare() async {
    _shareWatch?.cancel();
    setState(() {
      _sharing = false;
      _shareSource = null;
    });
    try {
      await widget.room.setScreenShareEnabled(false);
    } catch (e) {
      _toast('Could not stop the stream: $e');
    }
  }

  /// Once the community is known, opens its first text channel.
  void _openFirstChannel() {
    if (_view != null || !_node.started) return;
    final text = _node.channels.text;
    if (text.isEmpty) return;
    _views[_key] = ChannelRef.text(text.first);
    _text.open(text.first);
  }

  void _onSignal(RoomSignal s) {
    // One line per signal for the automated multi-machine check; samples are too chatty.
    if (s is! RoomStats && s is! RoomVideoRx) debugPrint('hubbub: ${_describe(s)}');
    if (s is ShareEnded && _sharing) unawaited(_stopShare());
    if (s is RoomVideoRx) {
      // Every sample (every 2 s while a stream is watched) goes to the journal.
      debugPrint('hubbub: ${formatVideoRx(s.sample)}');
      final from = s.sample.participantId;
      if (mounted && from != null) setState(() => _rx[from] = s.sample);
    }
    if (s is! RoomDisconnected || _rejoining) return;
    final call = _call;
    final host = call?.node.host;
    // The room died because the host changed: follow it rather than dropping the call.
    if (call != null && host != null && (host != call.host || call.node.term != call.term)) {
      unawaited(_rejoin(call));
    } else if (call != null) {
      // The connection dropped and no host change explains it: say so; the user can rejoin
      // from the channel list.
      _toast('Disconnected from ${call.channel}. Click it to rejoin.');
      setState(() => _call = null);
    }
  }

  static String _describe(RoomSignal s) => switch (s) {
        RoomDisconnected() => 'disconnected',
        FirstRemoteAudio() => 'firstRemoteAudio',
        RoomStats() => 'stats',
        ShareEnded() => 'shareEnded',
        RoomVideoRx() => 'videoRx',
      };

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startIfConfigured() async {
    try {
      final cfg = await widget.loadConfig();
      if (File(cfg.communityFile).existsSync()) await _start(cfg);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _start(AppNodeConfig cfg) async {
    try {
      await _node.start(cfg);
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = 'Could not start: $e');
    }
  }

  Future<void> _select(ChannelRef channel) async {
    if (_scaffold.currentState?.isDrawerOpen ?? false) _scaffold.currentState!.closeDrawer();
    setState(() => _views[_key] = channel);
    _text.open(channel.isVoice ? null : channel.name);
    // As in Discord, clicking a voice channel joins it.
    if (channel.isVoice && _callHere != channel.name) await _join(channel.name);
  }

  /// Call media reaches the host only through the node's TURN shim. Credentials without it
  /// (the machine has no usable network address) could join a room that never gets audio, so
  /// fail the join with a clear message instead.
  void _requireIce(AppVoiceCredentials c) {
    if (c.ice != null) return;
    debugPrint('hubbub: voice credentials carry no ICE server (no network address for media); not joining');
    throw const _NoMediaAddress();
  }

  Future<void> _join(String channel) async {
    if (_joining != null) return;
    setState(() => _joining = (_key, channel));
    var connecting = false;
    try {
      if (_call != null) await _leave();
      final node = _node;
      final key = _key;
      final c = await node.credentials(channel);
      _requireIce(c);
      await _devices.applyForJoin();
      await _audio.applyForJoin();
      if (!mounted) return;
      connecting = true;
      await widget.room.connect(c.url, c.token, c.e2EeKey, ice: c.ice);
      await widget.room.setMicrophoneEnabled(!_muted);
      await widget.room.setDeafened(_deafened);
      // The server may have been left while connecting: no call to a removed node.
      if (!mounted || !_hub.communities.any((x) => x.cid == key)) {
        connecting = false;
        await widget.room.disconnect();
        return;
      }
      connecting = false;
      setState(() => _call = _Call(key, channel, node, c.host, c.term.toInt()));
    } catch (e) {
      _toast('Could not join $channel: $e');
      // Nothing said we were in it, but make sure no stale "in voice" is left on the server.
      _node.setVoice(null);
    } finally {
      // Anything that failed after connect started must not leave a live room behind while
      // the UI shows no call.
      if (connecting) {
        try {
          await widget.room.disconnect();
        } catch (_) {}
      }
      if (mounted) setState(() => _joining = null);
      if (mounted) _followHost();
    }
  }

  Future<void> _leave() async {
    await widget.room.disconnect();
    if (mounted) setState(() => _call = null);
  }

  /// Unmuting while deafened also undeafens, as in Discord.
  Future<void> _toggleMute() =>
      _deafened ? _setVoice(muted: false, deafened: false) : _setVoice(muted: !_muted, deafened: false);

  /// Deafening also mutes; undeafening restores the mute chosen before.
  Future<void> _toggleDeafen() {
    if (_deafened) return _setVoice(muted: _mutedBeforeDeafen, deafened: false);
    _mutedBeforeDeafen = _muted;
    return _setVoice(muted: true, deafened: true);
  }

  Future<void> _setVoice({required bool muted, required bool deafened}) async {
    final deafChanged = deafened != _deafened;
    final muteChanged = muted != _muted;
    setState(() {
      _muted = muted;
      _deafened = deafened;
    });
    // Out of a call these settings apply on the next join.
    final call = _call;
    if (call == null) return;
    call.node.setVoice(call.channel, muted: muted, deafened: deafened);
    var deafApplied = false;
    try {
      if (deafChanged) {
        await widget.room.setDeafened(deafened);
        deafApplied = true;
      }
      if (muteChanged || deafChanged) await widget.room.setMicrophoneEnabled(!muted);
    } catch (e) {
      // The room did not take it: show what is really on (a deafen that went through stays).
      _toast('Could not ${muted ? 'mute' : 'unmute'}: $e');
      if (mounted) {
        setState(() {
          _muted = !muteChanged ? _muted : !muted;
          _deafened = !deafChanged || deafApplied ? _deafened : !deafened;
        });
        if (_call == call) call.node.setVoice(call.channel, muted: _muted, deafened: _deafened);
      }
    }
  }

  String _nameOf(String id, [NodeController? node]) {
    for (final m in (node ?? _node).members) {
      if (m.id == id) return m.name.isEmpty ? m.tag : m.name;
    }
    return shortTag(id);
  }

  /// The people in the call, named from the call's server.
  List<VoiceMember> get _voiceMembers => [
        for (final p in _people)
          VoiceMember(
            id: p.id,
            name: _nameOf(p.id, _call?.node),
            speaking: p.speaking,
            muted: p.isLocal ? _muted : p.muted,
            deafened: p.isLocal && _deafened,
            hosting: p.id == (_call?.node ?? _node).host,
            isMe: p.isLocal,
            camera: p.camera,
            share: p.share,
          ),
      ];

  /// Who is in each voice channel of the server on screen. For the call we are in this is the
  /// room's own list (speaking, camera, share); for the others it is what the core reports.
  Map<String, List<VoiceMember>> get _voiceByChannel {
    final node = _node;
    final here = _callHere;
    return {
      for (final ch in node.channels.voice)
        ch: ch == here
            ? _voiceMembers
            : [
                for (final p in node.voiceIn(ch))
                  VoiceMember(
                    id: p.member,
                    name: _nameOf(p.member, node),
                    muted: p.muted,
                    deafened: p.deafened,
                    hosting: p.member == node.host,
                  ),
              ],
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < narrowWidth;
      final nav = _navigation();
      final main = Column(children: [
        if (widget.updates != null) UpdateBanner(updates: widget.updates!),
        if (_offered != null)
          ClipboardBanner(
            preview: _offered!,
            onJoin: _joinOffered,
            onDismiss: () => setState(() => _offered = null),
          ),
        _header(narrow: narrow),
        Expanded(
          child: Row(children: [
            Expanded(child: _content()),
            if (!narrow && _memberList && _view != null && !_view!.isVoice)
              SizedBox(
                width: 240,
                child: MemberList(
                  members: _node.members,
                  me: _node.memberId,
                  online: _node.online,
                  host: _node.host,
                ),
              ),
          ]),
        ),
      ]);
      return AudioScope(
        audio: _audio,
        child: Scaffold(
          key: _scaffold,
          backgroundColor: HubColors.main,
          drawer: narrow
              ? Drawer(
                  width: 312,
                  backgroundColor: HubColors.sidebar,
                  shape: const RoundedRectangleBorder(),
                  child: nav,
                )
              : null,
          body: narrow ? main : Row(children: [nav, Expanded(child: main)]),
        ),
      );
    });
  }

  /// The rail and the channel column, with the call bar and user panel at its foot.
  Widget _navigation() {
    final started = _node.started;
    final channels = _node.channels;
    return SizedBox(
      width: 312,
      child: Row(children: [
        CommunityRail(
          communities: [for (final c in _hub.communities) c.name],
          selected: _hub.communities.indexWhere((c) => c.cid == _hub.selectedCid) < 0
              ? null
              : _hub.communities.indexWhere((c) => c.cid == _hub.selectedCid),
          onSelect: (i) => _hub.select(_hub.communities[i].cid),
          onAdd: widget.onAddServer ??
              (_multi ? () => showCreateServerDialog(context, _hub) : () {}),
        ),
        SizedBox(
          width: 240,
          child: Column(children: [
            Expanded(
              child: ListenableBuilder(
                listenable: _text,
                builder: (context, _) => ChannelSidebar(
                  communityName: started ? _node.communityName : 'Hubbub',
                  textChannels: channels.text,
                  voiceChannels: channels.voice,
                  selected: _view,
                  isUnread: _text.isUnread,
                  voiceByChannel: _voiceByChannel,
                  onSelect: _select,
                  onInvite: _multi && started ? _invite : null,
                  onLeave: _multi && started ? _leaveServer : null,
                ),
              ),
            ),
            if (_call != null)
              VoiceConnectedBar(
                channel: _call!.channel,
                community: _call!.node.communityName,
                onDisconnect: _leave,
              ),
            if (started)
              UserPanel(
                id: _node.memberId ?? '',
                name: _nameOf(_node.memberId ?? ''),
                tag: _node.memberTag ?? '',
                muted: _muted,
                deafened: _deafened,
                onToggleMute: _toggleMute,
                onToggleDeafen: _toggleDeafen,
                devices: _devices,
                audio: _audio,
                onVoiceSettings: () => _openSettings(voice: true),
                onSettings: _openSettings,
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _openSettings({bool voice = false}) => showSettingsDialog(
        context,
        memberId: _node.memberId ?? '',
        tag: _node.memberTag ?? '',
        devices: _devices,
        audio: _audio,
        inCall: _inCall,
        windows: widget.windowsSettings,
        voice: voice,
      );

  Widget _header({required bool narrow}) {
    final v = _view;
    return HeaderBar(
      color: v != null && v.isVoice ? HubColors.stage : HubColors.main,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        if (narrow)
          PanelButton(
            tooltip: 'Channels',
            onPressed: () => _scaffold.currentState?.openDrawer(),
            child: const Icon(Icons.menu_rounded, size: 24),
          ),
        if (v != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(v.isVoice ? Icons.volume_up_rounded : Icons.tag_rounded,
                size: 24, color: HubColors.glyph),
          ),
          Expanded(
            child: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: HubText.title),
          ),
          if (!v.isVoice && !narrow)
            PanelButton(
              tooltip: _memberList ? 'Hide Member List' : 'Show Member List',
              onPressed: () => setState(() => _memberList = !_memberList),
              child: Icon(Icons.people_alt_rounded,
                  size: 24, color: _memberList ? HubColors.header : null),
            ),
        ],
      ]),
    );
  }

  Widget _content() {
    final v = _view;
    if (!_node.started || v == null) {
      return _EmptyState(
        starting: _starting,
        error: _error,
        onCreate: _multi ? () => showCreateServerDialog(context, _hub) : null,
        onJoin: _multi ? () => showJoinDialog(context, _hub) : null,
      );
    }
    if (v.isVoice) {
      final here = _callHere == v.name;
      return VoiceChannelView(
        channel: v.name,
        participants: here ? _voiceMembers : const [],
        connected: here,
        connecting: _joining == (_key, v.name),
        muted: _muted,
        cameraOn: _cameraOn,
        sharing: _sharing,
        onToggleMute: _toggleMute,
        onToggleCamera: _toggleCamera,
        onToggleShare: _toggleShare,
        onLeave: _leave,
        onJoin: () => _join(v.name),
        stage: StageActions(
          watching: _watching,
          focusKey: _focus,
          onWatch: _watch,
          onFocus: _setFocus,
          onClose: _closeFocused,
          onFullscreen: _openFullscreen,
          showStats: _showStats,
          onToggleStats: () => setState(() => _showStats = !_showStats),
          rx: _focus?.startsWith('stream:') ?? false ? _rx[_focus!.substring(7)] : null,
        ),
      );
    }
    return TextChannelView(
      channel: v.name,
      text: _text,
      nameOf: _nameOf,
      online: _node.host != null,
      clock: widget.clock,
      onInvite: _multi ? _invite : null,
    );
  }
}

/// No community yet: how to get one.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.starting,
    required this.error,
    this.onCreate,
    this.onJoin,
  });

  final bool starting;
  final String? error;
  final VoidCallback? onCreate;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(starting ? 'Connecting to your community…' : 'No community yet',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: hubFont,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: HubColors.header,
                )),
            const SizedBox(height: 8),
            if (!starting)
              Text(onCreate == null
                  ? 'Waiting for a community.'
                  : 'Create a server, or join one with an invite from a friend.',
                  textAlign: TextAlign.center,
                  style: HubText.message.copyWith(color: HubColors.interactive)),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!,
                  textAlign: TextAlign.center,
                  style: HubText.message.copyWith(color: HubColors.red)),
            ],
            const SizedBox(height: 20),
            if (!starting && onCreate != null)
              Row(mainAxisSize: MainAxisSize.min, children: [
                HubButton(label: 'Create My Own', onPressed: onCreate),
                const SizedBox(width: 8),
                HubButton(
                  label: 'Join a Server',
                  color: HubColors.tertiary,
                  hoverColor: HubColors.selected,
                  onPressed: onJoin,
                ),
              ]),
          ]),
        ),
      );
}

/// The voice call in progress: its server's key, its channel, and the server's controller.
class _Call {
  const _Call(this.key, this.channel, this.node, this.host, this.term);

  final String key;
  final String channel;
  final NodeController node;

  /// The host and term whose media room this call is in.
  final String host;
  final int term;
}

/// A stream (or camera) filling the window; Esc or the button goes back, and so does the
/// picture ending.
class _FullscreenStream extends StatefulWidget {
  const _FullscreenStream({
    required this.feed,
    required this.mirror,
    required this.updates,
    required this.current,
  });

  final VideoFeed feed;
  final bool mirror;
  final Stream<List<RoomParticipant>> updates;
  final VideoFeed? Function(List<RoomParticipant>) current;

  @override
  State<_FullscreenStream> createState() => _FullscreenStreamState();
}

class _FullscreenStreamState extends State<_FullscreenStream> {
  late VideoFeed _feed = widget.feed;
  StreamSubscription<List<RoomParticipant>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.updates.listen((people) {
      final f = widget.current(people);
      if (f == null) {
        if (mounted) Navigator.of(context).maybePop();
      } else if (mounted) {
        setState(() => _feed = f);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop()},
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            key: const ValueKey('fullscreen'),
            color: Colors.black,
            child: Stack(children: [
              Positioned.fill(child: VideoView(feed: _feed, contain: true, mirror: widget.mirror)),
              Positioned(
                top: 12,
                right: 12,
                child: Tooltip(
                  message: 'Exit Full Screen',
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(color: Color(0xB3000000), shape: BoxShape.circle),
                      child: const Icon(Icons.fullscreen_exit_rounded, color: HubColors.white),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
}

class _NoMediaAddress implements Exception {
  const _NoMediaAddress();

  @override
  String toString() => "Couldn't start voice: no network address for media";
}
