import 'dart:async';

import 'package:flutter/foundation.dart';

import 'hub_api.dart';
import 'node_controller.dart';

/// The profile and every server this app is in: one [NodeController] per server, and
/// which one is on screen.
class HubController extends ChangeNotifier {
  HubController(this._api);

  /// A hub of one fixed server, for callers that hold a bare [NodeController].
  factory HubController.single(NodeController node) = _SingleHub;

  final HubApi? _api;

  List<AppCommunity> _communities = const [];
  String? _selected;
  StreamSubscription<JoinEvent>? _joinSub;
  StreamController<JoinEvent>? _joinOut;

  List<AppCommunity> get communities => _communities;
  String? get selectedCid => _selected;
  String get memberId => _api!.memberId;
  String get memberTag => _api!.memberTag;
  String get profileName => _api!.profileName();

  /// The selected server's controller, or null when there is none.
  NodeController? get current => _selected == null ? null : node(_selected!);

  NodeController node(String cid) => _api!.node(cid);

  Future<void> open(String root, {required bool canHost, String? livekitBin}) async {
    await _api!.open(root, canHost: canHost, livekitBin: livekitBin);
    refresh();
  }

  /// Re-reads the server list and keeps the selection valid.
  void refresh() {
    _communities = _api!.communities();
    if (!_communities.any((c) => c.cid == _selected)) {
      _selected = _communities.isEmpty ? null : _communities.first.cid;
    }
    notifyListeners();
  }

  void select(String cid) {
    if (_selected == cid || !_communities.any((c) => c.cid == cid)) return;
    _selected = cid;
    notifyListeners();
  }

  Future<void> setProfileName(String name) async {
    await _api!.setProfileName(name);
    notifyListeners();
  }

  /// Creates a server and opens it.
  Future<String> create(String name) async {
    final cid = await _api!.createCommunity(name);
    refresh();
    select(cid);
    return cid;
  }

  /// Joins from an invite link; a successful join selects the new server. Starting another
  /// join, cancelling, or cancelling the returned stream ends this one; the stream is closed.
  Stream<JoinEvent> join(String link) {
    _endJoin();
    final out = StreamController<JoinEvent>();
    _joinOut = out;
    final sub = _api!.join(link).listen((e) {
      if (e is JoinJoined) {
        refresh();
        select(e.cid);
      }
      if (!out.isClosed) out.add(e);
    }, onError: (Object e, StackTrace st) {
      if (!out.isClosed) out.addError(e, st);
    }, onDone: () {
      if (identical(_joinOut, out)) _joinOut = null;
      if (!out.isClosed) out.close();
    });
    _joinSub = sub;
    // The caller dropping the stream stops the inner join too (not awaited: see joinCancel).
    out.onCancel = () {
      if (identical(_joinSub, sub)) _joinSub = null;
      if (identical(_joinOut, out)) _joinOut = null;
      unawaited(sub.cancel());
    };
    return out.stream;
  }

  /// Stops the running join and closes its output stream, so listeners see it end.
  void _endJoin() {
    // Not awaited: cancelling a single-subscription stream can wait for the source to close.
    final sub = _joinSub;
    final out = _joinOut;
    _joinSub = null;
    _joinOut = null;
    if (sub != null) unawaited(sub.cancel());
    if (out != null && !out.isClosed) {
      out.onCancel = null;
      unawaited(out.close());
    }
  }

  Future<void> joinCancel() async {
    _endJoin();
    await _api!.joinCancel();
  }

  AppInvitePreview? inviteParse(String text) => _api!.inviteParse(text);

  Future<String> inviteCreate(String cid, {required int expiresMin, required int maxUses}) =>
      _api!.inviteCreate(cid, expiresMin: expiresMin, maxUses: maxUses);

  Future<void> inviteRevoke(String cid, String link) => _api!.inviteRevoke(cid, link);

  Future<void> leave(String cid) async {
    await _api!.leave(cid);
    refresh();
  }

  Future<void> shutdown() async {
    _endJoin();
    await _api?.shutdown();
  }
}

/// Wraps one existing controller as a hub with a single, fixed server.
class _SingleHub extends HubController {
  _SingleHub(this._only) : super(null) {
    _only.addListener(notifyListeners);
  }

  final NodeController _only;
  static const _cid = 'local';

  @override
  List<AppCommunity> get communities => [
        if (_only.started) AppCommunity(cid: _cid, name: _only.communityName, isOwner: false),
      ];
  @override
  String? get selectedCid => _only.started ? _cid : null;
  @override
  NodeController? get current => _only;
  @override
  NodeController node(String cid) => _only;
  @override
  String get memberId => _only.memberId ?? '';
  @override
  String get memberTag => _only.memberTag ?? '';
  @override
  void select(String cid) {}
  @override
  void refresh() {}

  @override
  Future<void> shutdown() => _only.shutdown();

  @override
  void dispose() {
    _only.removeListener(notifyListeners);
    super.dispose();
  }
}
