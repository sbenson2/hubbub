import 'dart:async';

import 'hub_api.dart';
import 'node_controller.dart';
import 'src/rust/api/hubbub.dart' as rust;

/// The real [HubApi]: the generated bindings over the Rust core's hub. `AppCommunity` and
/// `AppInvitePreview` are the generated types themselves (see hub_api.dart).
class FrbHub implements HubApi {
  final _nodes = <String, NodeController>{};

  @override
  Future<void> open(String root, {required bool canHost, String? livekitBin}) =>
      rust.hubOpen(root: root, canHost: canHost, livekitBin: livekitBin);

  @override
  String get memberId => rust.hubMemberId();

  @override
  String get memberTag => rust.hubMemberTag();

  /// The core names a fresh profile after the member tag. That is not a name the person
  /// chose, so it reads as unset and the app asks for one.
  @override
  String profileName() {
    final name = rust.profileName();
    return name == rust.hubMemberTag() ? '' : name;
  }

  @override
  Future<void> setProfileName(String name) async => rust.setProfileName(name: name);

  @override
  List<AppCommunity> communities() => rust.hubCommunities();

  /// One controller per server, kept until the server is left (the core allows one event
  /// stream per node handle).
  @override
  NodeController node(String cid) => _nodes.putIfAbsent(cid, () {
        return NodeController.fromNode(rust.hubNode(cid: cid));
      });

  @override
  Future<String> createCommunity(String name) => rust.communityCreate(name: name);

  @override
  Future<String> inviteCreate(String cid, {required int expiresMin, required int maxUses}) async =>
      rust.nodeInviteCreate(n: _handle(cid), expiresMin: expiresMin, maxUses: maxUses);

  @override
  Future<void> inviteRevoke(String cid, String link) async =>
      rust.nodeInviteRevoke(n: _handle(cid), link: link);

  rust.AppNode _handle(String cid) => node(cid).rawNode!;

  @override
  AppInvitePreview? inviteParse(String text) => rust.inviteParse(text: text);

  @override
  Stream<JoinEvent> join(String link) async* {
    await for (final e in rust.hubJoin(link: link)) {
      yield switch (e) {
        rust.AppJoinEvent_Trying() => const JoinTrying(),
        rust.AppJoinEvent_Offline() => const JoinOffline(),
        rust.AppJoinEvent_Denied(:final reason) => JoinDenied(reason),
        rust.AppJoinEvent_Joined(:final cid) => JoinJoined(cid),
      };
    }
  }

  @override
  Future<void> joinCancel() async => rust.hubJoinCancel();

  @override
  Future<void> leave(String cid) async {
    // Detach the controller first: the core stops the node and drops its event stream.
    _nodes.remove(cid)?.dispose();
    await rust.hubLeave(cid: cid);
  }

  @override
  Future<void> shutdown() async {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _nodes.clear();
    await rust.hubShutdown().timeout(const Duration(seconds: 5), onTimeout: () {});
  }
}
