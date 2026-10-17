import 'dart:async';

import 'package:flutter/foundation.dart';

import 'src/rust/api/hubbub.dart';

/// What the text views need from the core, so tests can fake it.
abstract interface class TextService {
  /// Queues [body] for [channel] and returns its client id.
  Future<BigInt> sendText(String channel, String body);

  /// The last [limit] stored messages of [channel], in arrival order.
  Future<List<AppTextMessage>> textHistory(String channel, int limit);
}

enum Delivery { pending, delivered, failed }

/// One message as the views show it.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.from,
    required this.clientId,
    required this.body,
    required this.sentAt,
    this.delivery = Delivery.delivered,
  });

  ChatMessage.fromApp(AppTextMessage m)
      : from = m.from,
        clientId = m.clientId,
        body = m.body,
        sentAt = DateTime.fromMillisecondsSinceEpoch(m.sentMs.toInt()),
        delivery = Delivery.delivered;

  /// The sender's full member id.
  final String from;

  /// Null while our own send has not returned its id yet.
  final BigInt? clientId;
  final String body;
  final DateTime sentAt;
  final Delivery delivery;

  /// `(from, clientId)` names a message (R35). Client id 0 marks a message stored before
  /// client ids were kept, which has no usable identity.
  (String, BigInt)? get key =>
      clientId == null || clientId == BigInt.zero ? null : (from, clientId!);

  ChatMessage copyWith({BigInt? clientId, Delivery? delivery}) => ChatMessage(
        from: from,
        clientId: clientId ?? this.clientId,
        body: body,
        sentAt: sentAt,
        delivery: delivery ?? this.delivery,
      );
}

class _ChannelLog {
  final messages = <ChatMessage>[];
  bool historyLoading = false;
  bool historyLoaded = false;
  bool reachedStart = false;

  int indexOfKey((String, BigInt) key) => messages.indexWhere((m) => m.key == key);
}

/// Every text channel's messages, in arrival order (never sorted by term and seq: terms
/// restart after a full community restart), plus which channels have unseen messages.
class TextController extends ChangeNotifier {
  TextController({
    required this._service,
    required Stream<AppNodeEvent> events,
    required this._me,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _sub = events.listen(_onEvent);
  }

  static const historyLimit = 200;

  final TextService _service;
  final String? Function() _me;
  final DateTime Function() _clock;
  late final StreamSubscription<AppNodeEvent> _sub;
  final _logs = <String, _ChannelLog>{};
  final _unread = <String>{};
  String? _active;
  bool _disposed = false;

  _ChannelLog _log(String channel) => _logs.putIfAbsent(channel, _ChannelLog.new);

  List<ChatMessage> messages(String channel) => List.unmodifiable(_log(channel).messages);

  /// Whether the history shown goes back to the channel's first message.
  bool reachedStart(String channel) => _log(channel).reachedStart;

  bool isUnread(String channel) => _unread.contains(channel);

  /// The text channel on screen, or null.
  String? get active => _active;

  /// Shows [channel] (null: no text channel on screen), clearing its unread mark and
  /// loading its history the first time.
  void open(String? channel) {
    _active = channel;
    if (channel == null) return;
    final changed = _unread.remove(channel);
    unawaited(_loadHistory(channel));
    if (changed) notifyListeners();
  }

  Future<void> _loadHistory(String channel) async {
    final log = _log(channel);
    if (log.historyLoaded || log.historyLoading) return;
    log.historyLoading = true;
    try {
      final history = await _service.textHistory(channel, historyLimit);
      if (_disposed) return;
      _mergeHistory(log, history.map(ChatMessage.fromApp).toList());
      log.historyLoaded = true;
      log.reachedStart = history.length < historyLimit;
      notifyListeners();
    } catch (e) {
      debugPrint('text history of #$channel failed: $e');
    } finally {
      log.historyLoading = false;
    }
  }

  /// History first, then whatever arrived live meanwhile and is not in it (R35).
  void _mergeHistory(_ChannelLog log, List<ChatMessage> history) {
    final seen = <(String, BigInt)>{};
    final merged = <ChatMessage>[];
    for (final m in history) {
      final k = m.key;
      if (k != null && !seen.add(k)) continue;
      merged.add(m);
    }
    for (final m in log.messages) {
      final k = m.key;
      if (k != null && seen.contains(k)) continue;
      merged.add(m);
    }
    log.messages
      ..clear()
      ..addAll(merged);
  }

  void _onEvent(AppNodeEvent ev) {
    if (ev is! AppNodeEvent_Text) return;
    final m = ChatMessage.fromApp(ev.message);
    final channel = ev.message.channel;
    final log = _log(channel);
    final key = m.key;
    final at = key == null ? -1 : log.indexOfKey(key);
    if (at >= 0) {
      // Our own pending message, delivered: it keeps its place. Anything else is a repeat.
      if (log.messages[at].delivery != Delivery.pending) return;
      log.messages[at] = log.messages[at].copyWith(delivery: Delivery.delivered);
    } else {
      // Includes our own message delivered before node_send_text returned its id.
      log.messages.add(m);
      if (m.from != _me() && channel != _active) _unread.add(channel);
    }
    notifyListeners();
  }

  /// Shows [body] at once as pending, then matches it to its delivery by client id.
  Future<void> send(String channel, String body) async {
    final log = _log(channel);
    final pending = ChatMessage(
      from: _me() ?? '',
      clientId: null,
      body: body,
      sentAt: _clock(),
      delivery: Delivery.pending,
    );
    log.messages.add(pending);
    notifyListeners();
    BigInt? clientId;
    try {
      clientId = await _service.sendText(channel, body);
    } catch (e) {
      debugPrint('send to #$channel failed: $e');
    }
    if (_disposed) return;
    final at = log.messages.indexWhere((m) => identical(m, pending));
    if (at < 0) return;
    if (clientId == null) {
      log.messages[at] = pending.copyWith(delivery: Delivery.failed);
    } else if (log.indexOfKey((pending.from, clientId)) >= 0) {
      // Its delivery came first and is already shown.
      log.messages.removeAt(at);
    } else {
      log.messages[at] = pending.copyWith(clientId: clientId);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
    super.dispose();
  }
}
