import 'dart:async';
import 'dart:typed_data';

import 'package:hubbub/node_controller.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/text_controller.dart';

/// A full 64-hex member id whose tag is [tag].
String memberIdFor(String tag) => '${tag.toLowerCase()}${'0' * (64 - tag.length)}';

AppMember member(String tag, String name) =>
    AppMember(id: memberIdFor(tag), tag: tag.toUpperCase(), name: name);

AppTextMessage textMessage({
  required String from,
  required int clientId,
  String channel = 'general',
  String body = 'hi',
  DateTime? at,
  int term = 1,
  int seq = 1,
}) =>
    AppTextMessage(
      channel: channel,
      term: BigInt.from(term),
      seq: BigInt.from(seq),
      from: from,
      sentMs: BigInt.from((at ?? DateTime(2026, 10, 17, 12)).millisecondsSinceEpoch),
      body: body,
      clientId: BigInt.from(clientId),
    );

/// Records sends and serves a fixed history; each send's client id comes from [nextClientId]
/// unless a test holds it back with [holdSends].
class FakeTextService implements TextService {
  final sent = <(String, String)>[];
  final history = <String, List<AppTextMessage>>{};
  int nextClientId = 100;
  bool holdSends = false;
  final held = <Completer<BigInt>>[];

  @override
  Future<BigInt> sendText(String channel, String body) {
    sent.add((channel, body));
    final id = BigInt.from(nextClientId++);
    if (!holdSends) return Future.value(id);
    final c = Completer<BigInt>();
    held.add(c);
    return c.future.then((_) => id);
  }

  @override
  Future<List<AppTextMessage>> textHistory(String channel, int limit) async =>
      List.of(history[channel] ?? const []);
}

/// A started node without the Rust library: fixed identity, community and history.
class FakeNode extends NodeController {
  FakeNode({
    required StreamController<AppNodeEvent> events,
    required this.me,
    required this.roster,
    this.textChannels = const ['general'],
    this.voiceChannels = const ['lobby'],
    this.name = 'Game Night',
    FakeTextService? text,
  })  : text = text ?? FakeTextService(),
        super(eventsOverride: events.stream);

  final AppMember me;
  final List<AppMember> roster;
  final List<String> textChannels;
  final List<String> voiceChannels;
  final String name;
  final FakeTextService text;
  final credentialRequests = <String>[];

  @override
  bool get started => true;
  @override
  String? get memberId => me.id;
  @override
  String? get memberTag => me.tag;
  @override
  String get communityName => name;
  @override
  AppChannels get channels => AppChannels(text: textChannels, voice: voiceChannels);
  @override
  List<AppMember> get members => roster;

  @override
  Future<AppVoiceCredentials> credentials(String room) async {
    credentialRequests.add(room);
    return AppVoiceCredentials(
      url: 'ws://127.0.0.1:7880',
      token: 'token',
      e2EeKey: Uint8List(32),
      host: host ?? '',
      term: BigInt.from(term),
    );
  }

  @override
  Future<BigInt> sendText(String channel, String body) => text.sendText(channel, body);

  @override
  Future<List<AppTextMessage>> textHistory(String channel, int limit) =>
      text.textHistory(channel, limit);
}

/// Records every media call; participants and signals are pushed by the test.
class FakeRoom implements RoomAdapter {
  final calls = <String>[];
  final _signals = StreamController<RoomSignal>.broadcast();
  final _participants = StreamController<List<RoomParticipant>>.broadcast();

  /// What a connect publishes as the call's participants.
  List<RoomParticipant> onConnect = const [];

  void emitParticipants(List<RoomParticipant> p) => _participants.add(p);
  void emitSignal(RoomSignal s) => _signals.add(s);

  @override
  Stream<RoomSignal> get signals => _signals.stream;
  @override
  Stream<List<RoomParticipant>> get participants => _participants.stream;

  @override
  Future<void> connect(String url, String token, Uint8List e2eeKey) async {
    calls.add('connect');
    _participants.add(onConnect);
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    _participants.add(const []);
  }

  @override
  Future<void> setMicrophoneEnabled(bool on) async => calls.add('mic:$on');
  @override
  Future<void> setDeafened(bool on) async => calls.add('deafened:$on');
  @override
  Future<void> setCameraEnabled(bool on) async => calls.add('camera:$on');
  @override
  Future<void> setScreenShareEnabled(bool on, {String? sourceId}) async =>
      calls.add('screen:$on');
  @override
  Future<void> subscribeVideo(String participantId, String trackSid, bool on) async =>
      calls.add('video:$participantId:$on');
}
