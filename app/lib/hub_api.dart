import 'dart:async';

import 'node_controller.dart';

// The generated types are the app's own: one server, and what an invite says before it is
// accepted (`expiresMin` is the minutes until it expires; 0 = never).
export 'src/rust/api/hubbub.dart' show AppCommunity, AppInvitePreview;
import 'src/rust/api/hubbub.dart' show AppCommunity, AppInvitePreview;

/// Progress of joining a server from an invite link.
sealed class JoinEvent {
  const JoinEvent();
}

/// Looking for a member who is online.
class JoinTrying extends JoinEvent {
  const JoinTrying();
}

/// Nobody is online right now; the core keeps trying.
class JoinOffline extends JoinEvent {
  const JoinOffline();
}

class JoinDenied extends JoinEvent {
  const JoinDenied(this.reason);
  final String reason;
}

class JoinJoined extends JoinEvent {
  const JoinJoined(this.cid);
  final String cid;
}

/// Everything the app needs from the core's hub: the profile and every server. The real
/// implementation wraps the generated Rust bindings; tests use `FakeHub`.
abstract class HubApi {
  Future<void> open(String root, {required bool canHost, String? livekitBin});

  String get memberId;
  String get memberTag;

  String profileName();
  Future<void> setProfileName(String name);

  List<AppCommunity> communities();

  /// The per-server controller for [cid]. The hub caches it.
  NodeController node(String cid);

  Future<String> createCommunity(String name);

  /// [expiresMin] and [maxUses] of 0 mean never and unlimited.
  Future<String> inviteCreate(String cid, {required int expiresMin, required int maxUses});
  Future<void> inviteRevoke(String cid, String link);

  /// Reads an invite without joining; null when [text] is not an invite.
  AppInvitePreview? inviteParse(String text);

  Stream<JoinEvent> join(String link);
  Future<void> joinCancel();

  /// Leaves [cid] on this device only.
  Future<void> leave(String cid);

  Future<void> shutdown();
}
