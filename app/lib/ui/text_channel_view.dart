import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_controller.dart';
import 'avatar.dart';
import 'theme.dart';
import 'user_panel.dart';

/// Consecutive messages from one author within this window share one header.
const groupWindow = Duration(minutes: 7);

/// Longest message the core accepts, in characters.
const maxMessageChars = 4000;

sealed class MessageRow {
  const MessageRow();
}

/// "October 17, 2026" between messages of different days.
class DayDivider extends MessageRow {
  const DayDivider(this.day);
  final DateTime day;
}

class MessageLine extends MessageRow {
  const MessageLine(this.message, {required this.startsGroup});
  final ChatMessage message;

  /// Shows the avatar, name and time; otherwise the message is compact.
  final bool startsGroup;
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Discord's grouping, over messages in arrival order: a day divider before each new day,
/// and a new group for another author, a new day, or a gap over [groupWindow].
List<MessageRow> groupMessages(List<ChatMessage> messages) {
  final rows = <MessageRow>[];
  ChatMessage? prev;
  for (final m in messages) {
    final newDay = prev == null || !_sameDay(prev.sentAt, m.sentAt);
    if (newDay) rows.add(DayDivider(DateTime(m.sentAt.year, m.sentAt.month, m.sentAt.day)));
    final starts = newDay ||
        prev.from != m.from ||
        m.sentAt.difference(prev.sentAt).abs() > groupWindow;
    rows.add(MessageLine(m, startsGroup: starts));
    prev = m;
  }
  return rows;
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "3:14 PM".
String clockTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${_two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "Today at 3:14 PM", "Yesterday at 3:14 PM" or "10/15/2026 3:14 PM".
String messageTimestamp(DateTime t, DateTime now) {
  if (_sameDay(t, now)) return 'Today at ${clockTime(t)}';
  if (_sameDay(t, DateTime(now.year, now.month, now.day - 1))) {
    return 'Yesterday at ${clockTime(t)}';
  }
  return '${_two(t.month)}/${_two(t.day)}/${t.year} ${clockTime(t)}';
}

/// "October 17, 2026".
String dayDividerLabel(DateTime day) => '${_months[day.month - 1]} ${day.day}, ${day.year}';

/// A text channel: its messages, grouped the Discord way, and the composer.
class TextChannelView extends StatelessWidget {
  const TextChannelView({
    super.key,
    required this.channel,
    required this.text,
    required this.nameOf,
    required this.online,
    this.clock,
    this.onInvite,
  });

  final String channel;
  final TextController text;

  /// Display name of a member id.
  final String Function(String memberId) nameOf;

  /// Whether a host is up; without one, messages wait and a banner says so.
  final bool online;
  final DateTime Function()? clock;

  /// When given, an empty channel's welcome card offers "Invite your friends".
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: HubColors.main,
      child: Column(children: [
        Expanded(
          child: ListenableBuilder(
            listenable: text,
            builder: (context, _) => _MessageList(
              channel: channel,
              rows: groupMessages(text.messages(channel)),
              reachedStart: text.reachedStart(channel),
              nameOf: nameOf,
              now: (clock ?? DateTime.now)(),
              onInvite: onInvite,
            ),
          ),
        ),
        if (!online) const _OfflineBanner(),
        _Composer(
          key: ValueKey('composer:$channel'),
          channel: channel,
          onSend: (body) => text.send(channel, body),
          attached: !online,
        ),
      ]),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.channel,
    required this.rows,
    required this.reachedStart,
    required this.nameOf,
    required this.now,
    this.onInvite,
  });

  final VoidCallback? onInvite;
  final String channel;
  final List<MessageRow> rows;
  final bool reachedStart;
  final String Function(String) nameOf;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final count = rows.length + (reachedStart ? 1 : 0);
    // Reversed, so the newest message sits on the composer and the list grows upward.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: count,
      itemBuilder: (context, i) {
        final index = rows.length - 1 - i;
        if (index < 0) return _ChannelWelcome(channel: channel, onInvite: rows.isEmpty ? onInvite : null);
        final row = rows[index];
        return switch (row) {
          DayDivider(:final day) => _DayDividerView(label: dayDividerLabel(day)),
          MessageLine(:final message, :final startsGroup) => _MessageTile(
              message: message,
              startsGroup: startsGroup,
              afterDivider: index > 0 && rows[index - 1] is DayDivider,
              name: nameOf(message.from),
              now: now,
            ),
        };
      },
    );
  }
}

class _ChannelWelcome extends StatelessWidget {
  const _ChannelWelcome({required this.channel, this.onInvite});

  final String channel;
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(color: Color(0xFF41434A), shape: BoxShape.circle),
            child: const Icon(Icons.tag_rounded, size: 44, color: HubColors.white),
          ),
          const SizedBox(height: 8),
          Text('Welcome to #$channel!',
              style: const TextStyle(
                fontFamily: hubFont,
                fontSize: 32,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: HubColors.header,
              )),
          const SizedBox(height: 8),
          Text('This is the start of the #$channel channel.',
              style: HubText.message.copyWith(color: HubColors.interactive)),
          if (onInvite != null) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: HubButton(
                label: 'Invite your friends',
                color: HubColors.green,
                hoverColor: const Color(0xFF1A7F44),
                onPressed: onInvite,
              ),
            ),
          ],
        ]),
      );
}

class _DayDividerView extends StatelessWidget {
  const _DayDividerView({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 14, 8),
        child: SizedBox(
          height: 13,
          child: Stack(alignment: Alignment.center, children: [
            const Divider(height: 1, thickness: 1, color: HubColors.divider),
            Container(
              color: HubColors.main,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(label,
                  style: const TextStyle(
                    fontFamily: hubFont,
                    fontSize: 12,
                    height: 1.08,
                    fontWeight: FontWeight.w600,
                    color: HubColors.muted,
                  )),
            ),
          ]),
        ),
      );
}

class _MessageTile extends StatefulWidget {
  const _MessageTile({
    required this.message,
    required this.startsGroup,
    required this.afterDivider,
    required this.name,
    required this.now,
  });

  final ChatMessage message;
  final bool startsGroup;
  final bool afterDivider;
  final String name;
  final DateTime now;

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final body = Text(
      m.body,
      style: HubText.message.copyWith(
        color: switch (m.delivery) {
          Delivery.pending => HubColors.text.withValues(alpha: 0.5),
          Delivery.failed => HubColors.red,
          Delivery.delivered => HubColors.text,
        },
      ),
    );
    final Widget content;
    if (widget.startsGroup) {
      content = Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: -56,
          top: 2,
          child: Avatar(id: m.from, name: widget.name, size: 40, background: HubColors.main),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(text: widget.name, style: HubText.author),
              const WidgetSpan(child: SizedBox(width: 6)),
              TextSpan(text: messageTimestamp(m.sentAt, widget.now), style: HubText.timestamp),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          body,
        ]),
      ]);
    } else {
      content = Stack(clipBehavior: Clip.none, children: [
        if (_hover)
          Positioned(
            left: -72,
            top: 0,
            width: 56,
            child: Text(
              clockTime(m.sentAt),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: hubFont,
                fontSize: 11,
                height: 2,
                fontWeight: FontWeight.w500,
                color: HubColors.muted,
              ),
            ),
          ),
        body,
      ]);
    }
    return Padding(
      padding: EdgeInsets.only(top: widget.startsGroup && !widget.afterDivider ? 17 : 0),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          width: double.infinity,
          color: _hover ? HubColors.messageHover : null,
          constraints: BoxConstraints(minHeight: widget.startsGroup ? 44 : 0),
          padding: const EdgeInsets.fromLTRB(72, 2, 48, 2),
          child: content,
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: const BoxDecoration(
          color: HubColors.sidebar,
          borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        ),
        child: const Row(children: [
          Icon(Icons.cloud_off_rounded, size: 16, color: HubColors.yellow),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              "Community offline — messages send when a member's PC is online.",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: hubFont,
                fontSize: 14,
                height: 1.3,
                fontWeight: FontWeight.w500,
                color: HubColors.interactive,
              ),
            ),
          ),
        ]),
      );
}

class _Composer extends StatefulWidget {
  const _Composer({
    super.key,
    required this.channel,
    required this.onSend,
    required this.attached,
  });

  final String channel;
  final Future<void> Function(String body) onSend;

  /// Squares the top corners to sit under the offline banner.
  final bool attached;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _input = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Enter sends; Shift+Enter adds a newline. Enter while an input method is composing
  /// belongs to the input method.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final enter =
        e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || e is KeyUpEvent) return KeyEventResult.ignored;
    if (_input.value.composing.isValid) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertNewline();
    } else if (e is KeyDownEvent) {
      _send();
    }
    return KeyEventResult.handled;
  }

  void _insertNewline() {
    final v = _input.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    if (v.text.length - (sel.end - sel.start) + 1 > maxMessageChars) return;
    _input.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, '\n'),
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  void _send() {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    _input.clear();
    widget.onSend(body);
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        decoration: BoxDecoration(
          color: HubColors.tertiary,
          borderRadius: widget.attached
              ? const BorderRadius.vertical(bottom: Radius.circular(8))
              : BorderRadius.circular(8),
        ),
        child: TextField(
          key: const ValueKey('composer'),
          controller: _input,
          focusNode: _focus,
          autofocus: true,
          minLines: 1,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          maxLength: maxMessageChars,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
          cursorColor: HubColors.text,
          cursorWidth: 1.5,
          style: HubText.message,
          decoration: InputDecoration.collapsed(
            hintText: 'Message #${widget.channel}',
            hintStyle: HubText.message.copyWith(color: HubColors.placeholder),
          ),
        ),
      );
}
