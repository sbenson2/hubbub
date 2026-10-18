import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../hub_controller.dart';
import '../node_controller.dart';
import '../room_adapter.dart';
import '../src/rust/api/hubbub.dart';
import '../text_controller.dart';
import 'avatar.dart';
import 'channel_sidebar.dart';
import 'community_rail.dart';
import 'member_list.dart';
import 'text_channel_view.dart';
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
  }) : assert((controller == null) != (hub == null), 'give a controller or a hub');

  /// A single server (the pre-hub path); [hub] holds every server.
  final NodeController? controller;
  final HubController? hub;

  /// The rail's "+"; without it the "+" imports a community file.
  final VoidCallback? onAddServer;
  final RoomAdapter room;
  final Future<AppNodeConfig> Function() loadConfig;

  /// Replaces the wall clock for message times (tests).
  final DateTime Function()? clock;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scaffold = GlobalKey<ScaffoldState>();
  late final HubController _hub;
  late final NodeController _idle;
  final _texts = <String, TextController>{};
  final _views = <String, ChannelRef>{};
  final _attached = <NodeController>{};
  StreamSubscription<RoomSignal>? _signalSub;
  StreamSubscription<List<RoomParticipant>>? _peopleSub;
  List<RoomParticipant> _people = const [];

  /// The voice channel whose call we are in (and its server), and the one being joined.
  /// Switching server leaves the call running, as Discord does.
  _Call? _call;
  String? _joining;
  bool _muted = false;
  bool _deafened = false;
  bool _mutedBeforeDeafen = false;
  bool _memberList = true;
  bool _starting = false;
  String? _error;

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
    _attach();
    _signalSub = widget.room.signals.listen(_onSignal);
    _peopleSub = widget.room.participants.listen((p) => setState(() => _people = p));
    _openFirstChannel();
    if (widget.controller != null && !_node.started) {
      _starting = true;
      unawaited(_startIfConfigured());
    }
  }

  @override
  void dispose() {
    _hub.removeListener(_refresh);
    for (final n in _attached) {
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
      if (_attached.add(n)) n.addListener(_refresh);
    }
  }

  void _refresh() => setState(() {
        _attach();
        _openFirstChannel();
      });

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
    if (s is RoomDisconnected) setState(() => _call = null);
  }

  static String _describe(RoomSignal s) => switch (s) {
        RoomDisconnected() => 'disconnected',
        FirstRemoteAudio() => 'firstRemoteAudio',
        RoomStats() => 'stats',
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

  Future<void> _importCommunity() async {
    final pick = await FilePicker.pickFiles(type: FileType.any);
    if (pick.isEmpty) return;
    final path = pick.single.path;
    if (path == null) return;
    final cfg = await widget.loadConfig();
    await File(path).copy(cfg.communityFile);
    if (_node.started) {
      _toast('Community file imported. Restart Hubbub to load it.');
    } else {
      await _start(cfg);
    }
  }

  Future<void> _select(ChannelRef channel) async {
    if (_scaffold.currentState?.isDrawerOpen ?? false) _scaffold.currentState!.closeDrawer();
    setState(() => _views[_key] = channel);
    _text.open(channel.isVoice ? null : channel.name);
    // As in Discord, clicking a voice channel joins it.
    if (channel.isVoice && _callHere != channel.name) await _join(channel.name);
  }

  Future<void> _join(String channel) async {
    if (_joining != null) return;
    setState(() => _joining = channel);
    try {
      if (_call != null) await _leave();
      final node = _node;
      final key = _key;
      final c = await node.credentials(channel);
      await widget.room.connect(c.url, c.token, c.e2EeKey);
      await widget.room.setMicrophoneEnabled(!_muted);
      await widget.room.setDeafened(_deafened);
      if (mounted) setState(() => _call = _Call(key, channel, node));
    } catch (e) {
      _toast('Could not join $channel: $e');
    } finally {
      if (mounted) setState(() => _joining = null);
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
    if (_call == null) return;
    if (deafChanged) await widget.room.setDeafened(deafened);
    if (muteChanged || deafChanged) await widget.room.setMicrophoneEnabled(!muted);
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
          ),
      ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < narrowWidth;
      final nav = _navigation();
      final main = Column(children: [
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
      return Scaffold(
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
          onAdd: widget.onAddServer ?? _importCommunity,
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
                  connectedVoice: _callHere,
                  voiceMembers: _callHere == null ? const [] : _voiceMembers,
                  onSelect: _select,
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
                onSettings: () => showSettingsDialog(
                  context,
                  memberId: _node.memberId ?? '',
                  tag: _node.memberTag ?? '',
                  onImport: _importCommunity,
                ),
              ),
          ]),
        ),
      ]),
    );
  }

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
        onImport: _importCommunity,
      );
    }
    if (v.isVoice) {
      final here = _callHere == v.name;
      return VoiceChannelView(
        channel: v.name,
        participants: here ? _voiceMembers : const [],
        connected: here,
        connecting: _joining == v.name,
        muted: _muted,
        onToggleMute: _toggleMute,
        onLeave: _leave,
        onJoin: () => _join(v.name),
      );
    }
    return TextChannelView(
      channel: v.name,
      text: _text,
      nameOf: _nameOf,
      online: _node.host != null,
      clock: widget.clock,
    );
  }
}

/// No community yet: how to get one.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.starting, required this.error, required this.onImport});

  final bool starting;
  final String? error;
  final VoidCallback onImport;

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
              Text('Import the community file a friend sent you to join their community.',
                  textAlign: TextAlign.center,
                  style: HubText.message.copyWith(color: HubColors.interactive)),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!,
                  textAlign: TextAlign.center,
                  style: HubText.message.copyWith(color: HubColors.red)),
            ],
            const SizedBox(height: 20),
            if (!starting) HubButton(label: 'Import community file', onPressed: onImport),
          ]),
        ),
      );
}

/// The voice call in progress: its server's key, its channel, and the server's controller.
class _Call {
  const _Call(this.key, this.channel, this.node);

  final String key;
  final String channel;
  final NodeController node;
}
