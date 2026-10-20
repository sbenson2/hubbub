import 'dart:async';
import 'dart:typed_data';

import 'package:hubbub/app_shell.dart';
import 'package:hubbub/capture_options.dart';
import 'package:hubbub/hub_api.dart';
import 'package:hubbub/links.dart';
import 'package:hubbub/node_controller.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/share_sources.dart';
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
    super.membersChanged,
  })  : text = text ?? FakeTextService(),
        super(eventsOverride: events.stream);

  final AppMember me;
  final List<AppMember> roster;
  bool _refreshed = false;
  final List<String> textChannels;
  final List<String> voiceChannels;
  final String name;
  final FakeTextService text;
  final credentialRequests = <String>[];

  /// When set, `credentials` waits for it, then throws if it completed with an error.
  Completer<void>? credentialsGate;

  /// Every `setVoice` call, as `channel muted deafened` (`-` for no channel).
  final voiceCalls = <String>[];
  @override
  void setVoice(String? channel, {bool muted = false, bool deafened = false}) =>
      voiceCalls.add('${channel ?? '-'} $muted $deafened');

  /// The ICE server the next credentials carry, as the core's TURN shim would hand out.
  AppIceServer? ice = const AppIceServer(
      url: 'turn:192.168.1.5:50000?transport=udp', username: 'hbuser', credential: 'secret');

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
  // The roster is what the core would report; the UI only sees changes after a refresh.
  @override
  List<AppMember> get members => _refreshed ? super.members : List.of(roster);
  @override
  List<AppMember> loadMembers() {
    _refreshed = true;
    return List.of(roster);
  }

  @override
  Future<AppVoiceCredentials> credentials(String room) async {
    credentialRequests.add(room);
    await credentialsGate?.future;
    return AppVoiceCredentials(
      url: 'ws://127.0.0.1:7880',
      token: 'token',
      e2EeKey: Uint8List(32),
      host: host ?? '',
      term: BigInt.from(term),
      ice: ice,
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

  /// When set, a connect waits for this to complete.
  Completer<void>? connectGate;

  /// When set, a connect fails with this after the gate.
  Object? connectError;

  /// Every device call, as `input:<id>`, `output:<id>`, `camera:<id>` (`default` for null);
  /// kept apart from [calls] so call-flow tests stay exact.
  final deviceCalls = <String>[];
  List<MediaDeviceInfo> devices = const [];

  /// When set, switching the output device fails with this.
  Object? outputError;
  final _devicesChanged = StreamController<void>.broadcast();

  /// What the last connect had chosen as input and output.
  String? inputId, outputId, cameraId, inputAtConnect;

  /// The ICE server the last `connect` was given.
  AppIceServer? iceAtConnect;

  void plugDevices(List<MediaDeviceInfo> d) {
    devices = d;
    _devicesChanged.add(null);
  }

  @override
  Future<List<MediaDeviceInfo>> listDevices() async => devices;
  @override
  Stream<void> get devicesChanged => _devicesChanged.stream;
  @override
  Future<void> setInputDevice(String? id) async {
    inputId = id;
    deviceCalls.add('input:${id ?? 'default'}');
  }

  @override
  Future<void> setOutputDevice(String? id) async {
    if (outputError != null) throw outputError!;
    outputId = id;
    deviceCalls.add('output:${id ?? 'default'}');
  }

  @override
  Future<void> setCameraDevice(String? id) async {
    cameraId = id;
    deviceCalls.add('camera:${id ?? 'default'}');
  }

  /// What the room was last told, as the adapter keeps it across calls.
  double masterVolume = 1;
  final userVolumes = <String, double>{};
  final localMutes = <String>{};

  /// Every volume call in order, as `master:<v>`, `volume:<id>:<v>`, `mute:<id>:<bool>`.
  final volumeCalls = <String>[];

  /// The gain the real adapter would give [id]'s track.
  double effectiveFor(String id) =>
      effectiveVolume(masterVolume, userVolumes[id] ?? 1, localMutes.contains(id));

  @override
  Future<void> setMasterVolume(double v) async {
    masterVolume = v;
    volumeCalls.add('master:$v');
  }

  @override
  Future<void> setParticipantVolume(String id, double v) async {
    userVolumes[id] = v;
    volumeCalls.add('volume:$id:$v');
  }

  @override
  Future<void> setLocalMuteFor(String id, bool muted) async {
    muted ? localMutes.add(id) : localMutes.remove(id);
    volumeCalls.add('mute:$id:$muted');
  }

  final _levels = StreamController<MicLevels>.broadcast();
  void emitLevels(MicLevels l) => _levels.add(l);

  /// A window whose pre-gain peak is [pre], sent at [post] after gain.
  void emitPeak(double pre, {double? post, double clip = 0, double speech = -1}) =>
      _levels.add(MicLevels(pre: pre, post: post ?? pre, clip: clip, speech: speech));
  @override
  Stream<MicLevels> get micLevels => _levels.stream;

  /// What the room was last told about the microphone, and every such call in order.
  double inputGain = 1;
  NoiseSuppression noiseSuppression = NoiseSuppression.rnnoise;
  final micCalls = <String>[];
  @override
  Future<void> setInputGain(double v) async {
    inputGain = v;
    micCalls.add('gain:$v');
  }

  @override
  Future<void> setNoiseSuppression(NoiseSuppression ns) async {
    noiseSuppression = ns;
    micCalls.add('ns:${ns.name}');
  }

  void emitParticipants(List<RoomParticipant> p) => _participants.add(p);
  void emitSignal(RoomSignal s) => _signals.add(s);

  @override
  Stream<RoomSignal> get signals => _signals.stream;
  @override
  Stream<List<RoomParticipant>> get participants => _participants.stream;

  @override
  Future<void> connect(String url, String token, Uint8List e2eeKey, {AppIceServer? ice}) async {
    calls.add('connect');
    iceAtConnect = ice;
    inputAtConnect = inputId;
    await connectGate?.future;
    if (connectError != null) throw connectError!;
    if (connectFailures > 0) {
      connectFailures--;
      throw StateError('not up yet');
    }
    connected = true;
    _participants.add(onConnect);
  }

  /// The next this-many connects fail, then connects work again.
  int connectFailures = 0;

  /// Whether a room is up. As in the real adapter, a disconnect with no room says nothing.
  bool connected = false;

  /// Makes the microphone call fail, as a refused capture or a publisher timeout does.
  Object? micError;

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    if (!connected) return;
    connected = false;
    _participants.add(const []);
  }

  @override
  Future<void> setMicrophoneEnabled(bool on) async {
    calls.add('mic:$on');
    if (micError != null) throw micError!;
  }
  @override
  Future<void> setDeafened(bool on) async => calls.add('deafened:$on');
  @override
  Future<void> setCameraEnabled(bool on) async => calls.add('camera:$on');
  @override
  Future<void> setScreenShareEnabled(bool on, {String? sourceId}) async =>
      calls.add(on ? 'screen:true:${sourceId ?? ''}' : 'screen:false');
  @override
  Future<void> subscribeVideo(String participantId, String trackSid, bool on) async =>
      calls.add('video:$participantId:$trackSid:$on');
  @override
  Future<void> setVideoQuality(String participantId, String trackSid, {required bool high}) async =>
      calls.add('quality:$participantId:$trackSid:${high ? 'high' : 'low'}');
}

/// The screens and windows the share picker offers; [error] makes the platform refuse.
class FakeShareSources {
  List<ShareSource> sources = [
    const ShareSource(id: 'screen:0:0', name: 'Screen 1', kind: ShareKind.screen),
    const ShareSource(id: 'window:42:0', name: 'Doom Eternal', kind: ShareKind.window),
    const ShareSource(id: 'window:43:0', name: 'Spotify', kind: ShareKind.window),
  ];
  Object? error;
  int loads = 0;

  int checks = 0;

  Future<bool> exists(String id) async {
    checks++;
    if (error != null) throw error!;
    return sources.any((s) => s.id == id);
  }

  Future<List<ShareSource>> load() async {
    loads++;
    if (error != null) throw error!;
    return List.of(sources);
  }
}

/// The Wayland share prompt: [gate] holds the pick back until the test completes it; without
/// one the pick comes at once. [error] makes the wait fail.
class FakePortalSource {
  String id = 'portal-1';
  Object? error;
  Completer<String?>? gate;
  int calls = 0;
  PortalCancel? lastCancel;

  Future<String?> call(PortalCancel cancel) {
    calls++;
    lastCancel = cancel;
    if (error != null) return Future.error(error!);
    return gate?.future ?? Future.value(id);
  }
}

/// An in-memory hub: servers are [FakeNode]s the test registers; create, join and leave
/// behave like the core's.
class FakeHub implements HubApi {
  FakeHub({this.name = 'Shawn', Map<String, FakeNode>? nodes, List<AppCommunity>? servers})
      : _nodes = nodes ?? {},
        _servers = servers ?? [];

  String name;
  final Map<String, FakeNode> _nodes;
  final List<AppCommunity> _servers;
  final calls = <String>[];

  /// Registers a server that is already joined.
  void add(String cid, String name, FakeNode node, {bool isOwner = false}) {
    _nodes[cid] = node;
    _servers.add(AppCommunity(cid: cid, name: name, isOwner: isOwner));
  }

  /// Makes a join of [link] succeed with this server once the test lets it.
  void willJoin(String link, String cid, String name, FakeNode node) {
    _joinable[link] = (cid, name, node);
  }

  final _joinable = <String, (String, String, FakeNode)>{};

  /// When set, every join follows this stream and every link parses to this preview.
  Stream<JoinEvent>? scriptedJoin;
  AppInvitePreview? scriptedPreview;

  /// Makes setProfileName and leave throw.
  bool failWrites = false;

  @override
  Future<void> open(String root, {required bool canHost, String? livekitBin}) async =>
      calls.add('open:$root');
  @override
  String get memberId => memberIdFor('aaaa');
  @override
  String get memberTag => 'AAAA';
  @override
  String profileName() => name;
  @override
  Future<void> setProfileName(String n) async {
    if (failWrites) throw StateError('disk full');
    name = n;
  }
  @override
  List<AppCommunity> communities() => List.of(_servers);
  @override
  NodeController node(String cid) => _nodes[cid]!;

  @override
  Future<String> createCommunity(String n) async {
    final cid = 'cid-${_servers.length + 1}';
    final me = member('aaaa', name);
    add(cid, n, FakeNode(events: StreamController<AppNodeEvent>.broadcast(), me: me, roster: [me], name: n),
        isOwner: true);
    return cid;
  }

  @override
  Future<String> inviteCreate(String cid, {required int expiresMin, required int maxUses}) async {
    calls.add('invite:$cid:$expiresMin:$maxUses');
    return 'hubbub://join/$cid';
  }

  @override
  Future<void> inviteRevoke(String cid, String link) async => calls.add('revoke:$cid');

  @override
  AppInvitePreview? inviteParse(String text) {
    if (scriptedPreview != null && text.startsWith('hubbub://')) return scriptedPreview;
    final j = _joinable[text];
    return j == null ? null : AppInvitePreview(cid: j.$1, name: j.$2, expiresMin: 0);
  }

  @override
  Stream<JoinEvent> join(String link) => scriptedJoin ?? _join(link);

  Stream<JoinEvent> _join(String link) async* {
    yield const JoinTrying();
    final j = _joinable[link];
    if (j == null) {
      yield const JoinDenied('invalid invite');
      return;
    }
    add(j.$1, j.$2, j.$3);
    yield JoinJoined(j.$1);
  }

  @override
  Future<void> joinCancel() async => calls.add('joinCancel');
  @override
  Future<void> leave(String cid) async {
    if (failWrites) throw StateError('offline');
    _servers.removeWhere((c) => c.cid == cid);
    _nodes.remove(cid);
  }

  @override
  Future<void> shutdown() async => calls.add('shutdown');
}

/// A link source the test feeds: [initial] is the launch link, [send] a link to the running app.
class FakeLinks implements LinkSource {
  FakeLinks({this.initialLink});

  final String? initialLink;
  final _stream = StreamController<String>.broadcast();

  void send(String link) => _stream.add(link);

  @override
  Future<String?> initial() async => initialLink;

  @override
  Stream<String> get stream => _stream.stream;
}

/// A window and tray the test drives: [closeWindow] is the user's X, [trayOpen]/[trayQuit] the
/// tray's click and "Quit Hubbub". [calls] records what the app asked of the window.
class FakeAppShell implements AppShell {
  FakeAppShell({this.hasTray = true});

  @override
  bool hasTray;
  final calls = <String>[];
  bool visible = true;
  void Function()? _close, _open, _quit;
  Future<void> Function()? _session;

  @override
  set onCloseRequested(void Function() cb) => _close = cb;
  @override
  set onTrayOpen(void Function() cb) => _open = cb;
  @override
  set onTrayQuit(void Function() cb) => _quit = cb;

  @override
  set onSessionEnd(Future<void> Function() cb) => _session = cb;

  Future<void> endSession() => _session!();
  void closeWindow() => _close!();
  void trayOpen() => _open!();
  void trayQuit() => _quit!();

  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> hideWindow() async {
    visible = false;
    calls.add('hide');
  }

  @override
  Future<void> showWindow() async {
    visible = true;
    calls.add('show');
  }

  @override
  Future<void> exitApp() async => calls.add('exit');
}
