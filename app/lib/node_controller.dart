import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'src/rust/api/hubbub.dart';
import 'src/rust/frb_generated.dart';
import 'text_controller.dart';

/// Owns the in-process core node and exposes the election state, the community and its
/// text channels to the UI.
class NodeController extends ChangeNotifier implements TextService {
  /// [eventsOverride] replaces the core's event stream (tests).
  NodeController({Stream<AppNodeEvent>? eventsOverride}) {
    if (eventsOverride != null) _listen(eventsOverride);
  }

  AppNode? _node;
  String? _memberId;
  String? _memberTag;
  String? _host;
  int _term = 0;
  bool _isHost = false;
  String? _communityName;
  AppChannels _channels = const AppChannels(text: [], voice: []);
  List<AppMember> _members = const [];
  final _online = <String>{};
  StreamSubscription<AppNodeEvent>? _sub;
  final _events = StreamController<AppNodeEvent>.broadcast();

  String? get memberId => _memberId;
  String? get memberTag => _memberTag;
  String? get host => _host;
  int get term => _term;
  bool get isHost => _isHost;
  bool get started => _node != null;
  Stream<AppNodeEvent> get events => _events.stream;

  /// The community file's name.
  String get communityName => _communityName ?? 'Hubbub';
  AppChannels get channels => _channels;

  /// Every member of the community, this node included.
  List<AppMember> get members => _members;

  /// Members with a live link to this node (PeerUp without a later PeerDown).
  Set<String> get online => Set.unmodifiable(_online);

  Future<void> start(AppNodeConfig cfg) async {
    if (_node != null) return;
    final node = await startNode(cfg: cfg);
    _node = node;
    _memberId = nodeMemberId(n: node);
    _memberTag = nodeMemberTag(n: node);
    _channels = nodeChannels(n: node);
    _members = nodeMembers(n: node);
    _communityName = _readCommunityName(cfg.communityFile);
    _listen(nodeEvents(n: node));
    notifyListeners();
  }

  Future<AppVoiceCredentials> credentials(String room) =>
      nodeVoiceCredentials(n: _started(), room: room);

  @override
  Future<BigInt> sendText(String channel, String body) =>
      nodeSendText(n: _started(), channel: channel, body: body);

  @override
  Future<List<AppTextMessage>> textHistory(String channel, int limit) =>
      nodeTextHistory(n: _started(), channel: channel, limit: limit);

  AppNode _started() {
    final node = _node;
    if (node == null) throw StateError('node not started');
    return node;
  }

  /// The core does not expose the name, so it is read from the same file the node loaded.
  static String? _readCommunityName(String path) {
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      final name = json is Map<String, dynamic> ? json['name'] : null;
      return name is String && name.trim().isNotEmpty ? name : null;
    } catch (e) {
      debugPrint('community name unreadable: $e');
      return null;
    }
  }

  void _listen(Stream<AppNodeEvent> stream) {
    _sub = stream.listen(_onEvent);
  }

  void _onEvent(AppNodeEvent ev) {
    // One line per event, for the automated multi-machine check.
    debugPrint('hubbub: ${_describe(ev)}');
    switch (ev) {
      case AppNodeEvent_HostChanged(:final host, :final term, :final isMe):
        _host = host;
        _term = term.toInt();
        _isHost = isMe;
      case AppNodeEvent_PeerUp(:final member):
        _online.add(member);
      case AppNodeEvent_PeerDown(:final member):
        _online.remove(member);
      case AppNodeEvent_Text():
        break;
    }
    _events.add(ev);
    notifyListeners();
  }

  static String _describe(AppNodeEvent ev) => switch (ev) {
        AppNodeEvent_HostChanged(:final host, :final term, :final isMe) =>
          'HostChanged host=$host term=$term isMe=$isMe',
        AppNodeEvent_PeerUp(:final member, :final direct) =>
          'PeerUp member=$member direct=$direct',
        AppNodeEvent_PeerDown(:final member) => 'PeerDown member=$member',
        AppNodeEvent_Text(:final message) =>
          'Text #${message.channel} from=${_tag(message.from)} '
              'seq=${message.term}.${message.seq}',
      };

  /// A member id's short tag, as the core makes it: the first 4 hex characters, uppercase.
  static String _tag(String memberId) =>
      memberId.substring(0, memberId.length < 4 ? memberId.length : 4).toUpperCase();

  /// Leaves the community and stops the media host. Safe to call twice. Bounded,
  /// so a hung node cannot block quitting.
  Future<void> shutdown({Duration timeout = const Duration(seconds: 3)}) async {
    final node = _node;
    _node = null;
    if (node == null) return;
    await nodeShutdown(n: node).timeout(timeout, onTimeout: () {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _events.close();
    unawaited(shutdown());
    super.dispose();
  }
}

/// Loads the Rust library once; call before [NodeController.start].
Future<void> initCore() => RustLib.init();
