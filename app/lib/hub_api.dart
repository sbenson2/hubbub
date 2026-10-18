import 'dart:async';

import 'node_controller.dart';

/// One server this app is a member of.
class AppCommunity {
  const AppCommunity({required this.cid, required this.name, required this.isOwner});

  final String cid;
  final String name;
  final bool isOwner;

  @override
  int get hashCode => Object.hash(cid, name, isOwner);

  @override
  bool operator ==(Object other) =>
      other is AppCommunity && cid == other.cid && name == other.name && isOwner == other.isOwner;
}

/// What a pasted invite says before it is accepted.
class AppInvitePreview {
  const AppInvitePreview({required this.cid, required this.name, required this.expiresMin});

  final String cid;
  final String name;

  /// Minutes until the invite expires; 0 = never.
  final int expiresMin;

  @override
  int get hashCode => Object.hash(cid, name, expiresMin);

  @override
  bool operator ==(Object other) =>
      other is AppInvitePreview &&
      cid == other.cid &&
      name == other.name &&
      expiresMin == other.expiresMin;
}

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
