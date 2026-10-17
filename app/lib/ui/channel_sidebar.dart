import 'package:flutter/material.dart';

import 'avatar.dart';
import 'theme.dart';

enum ChannelKind { text, voice }

/// A channel of the community, text or voice.
@immutable
class ChannelRef {
  const ChannelRef.text(this.name) : kind = ChannelKind.text;
  const ChannelRef.voice(this.name) : kind = ChannelKind.voice;

  final ChannelKind kind;
  final String name;

  bool get isVoice => kind == ChannelKind.voice;

  @override
  bool operator ==(Object other) =>
      other is ChannelRef && other.kind == kind && other.name == name;

  @override
  int get hashCode => Object.hash(kind, name);

  @override
  String toString() => '${kind.name}:$name';
}

/// Someone in the voice call, as the sidebar and the call stage show them.
@immutable
class VoiceMember {
  const VoiceMember({
    required this.id,
    required this.name,
    this.speaking = false,
    this.muted = false,
    this.deafened = false,
    this.hosting = false,
  });

  final String id;
  final String name;
  final bool speaking;
  final bool muted;
  final bool deafened;
  final bool hosting;
}

/// The community header, collapsible text and voice categories, and the people in the
/// voice channel we are connected to.
class ChannelSidebar extends StatefulWidget {
  const ChannelSidebar({
    super.key,
    required this.communityName,
    required this.textChannels,
    required this.voiceChannels,
    required this.selected,
    required this.isUnread,
    required this.connectedVoice,
    required this.voiceMembers,
    required this.onSelect,
  });

  final String communityName;
  final List<String> textChannels;
  final List<String> voiceChannels;
  final ChannelRef? selected;
  final bool Function(String textChannel) isUnread;

  /// The voice channel we are in, whose [voiceMembers] are listed under it.
  final String? connectedVoice;
  final List<VoiceMember> voiceMembers;
  final ValueChanged<ChannelRef> onSelect;

  @override
  State<ChannelSidebar> createState() => _ChannelSidebarState();
}

class _ChannelSidebarState extends State<ChannelSidebar> {
  bool _textCollapsed = false;
  bool _voiceCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final rows = <Widget>[
      _Category(
        label: 'TEXT CHANNELS',
        collapsed: _textCollapsed,
        onTap: () => setState(() => _textCollapsed = !_textCollapsed),
      ),
      for (final name in w.textChannels)
        if (!_textCollapsed || w.selected == ChannelRef.text(name))
          _ChannelRow(
            channel: ChannelRef.text(name),
            selected: w.selected == ChannelRef.text(name),
            unread: w.isUnread(name),
            onTap: () => w.onSelect(ChannelRef.text(name)),
          ),
      _Category(
        label: 'VOICE CHANNELS',
        collapsed: _voiceCollapsed,
        onTap: () => setState(() => _voiceCollapsed = !_voiceCollapsed),
      ),
      for (final name in w.voiceChannels)
        if (!_voiceCollapsed ||
            w.selected == ChannelRef.voice(name) ||
            w.connectedVoice == name) ...[
          _ChannelRow(
            channel: ChannelRef.voice(name),
            selected: w.selected == ChannelRef.voice(name),
            unread: false,
            onTap: () => w.onSelect(ChannelRef.voice(name)),
          ),
          if (w.connectedVoice == name)
            for (final m in w.voiceMembers) _VoiceMemberRow(member: m),
        ],
    ];
    return ColoredBox(
      color: HubColors.sidebar,
      child: Column(children: [
        _CommunityHeader(name: w.communityName),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 0, bottom: 8, right: 8),
            children: rows,
          ),
        ),
      ]),
    );
  }
}

/// A 48 px bar with a hairline shadow, as at the top of every Discord column.
class HeaderBar extends StatelessWidget {
  const HeaderBar({super.key, required this.child, this.color = HubColors.sidebar, this.padding});

  final Widget child;
  final Color color;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Container(
        height: 48,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: color,
          boxShadow: const [
            BoxShadow(color: Color(0x33040405), offset: Offset(0, 1)),
            BoxShadow(color: Color(0x0D060607), offset: Offset(0, 1.5)),
            BoxShadow(color: Color(0x0D040405), offset: Offset(0, 2)),
          ],
        ),
        child: child,
      );
}

class _CommunityHeader extends StatelessWidget {
  const _CommunityHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => HeaderBar(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: HubText.title),
        ),
      );
}

class _Category extends StatefulWidget {
  const _Category({required this.label, required this.collapsed, required this.onTap});

  final String label;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<_Category> createState() => _CategoryState();
}

class _CategoryState extends State<_Category> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? HubColors.text : HubColors.muted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.only(top: 16, left: 2, bottom: 4),
          child: Row(children: [
            AnimatedRotation(
              turns: widget.collapsed ? -0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.keyboard_arrow_down_rounded, size: 14, color: color),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HubText.category.copyWith(color: color)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ChannelRow extends StatefulWidget {
  const _ChannelRow({
    required this.channel,
    required this.selected,
    required this.unread,
    required this.onTap,
  });

  final ChannelRef channel;
  final bool selected;
  final bool unread;
  final VoidCallback onTap;

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final Color fill = w.selected
        ? HubColors.selected
        : _hover
            ? HubColors.hover
            : Colors.transparent;
    final Color nameColor = w.selected || w.unread
        ? HubColors.white
        : _hover
            ? HubColors.text
            : HubColors.muted;
    final Color glyphColor = w.selected || w.unread || _hover ? HubColors.text : HubColors.glyph;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: w.onTap,
        child: SizedBox(
          height: 34,
          child: Stack(clipBehavior: Clip.none, children: [
            if (w.unread && !w.selected)
              Positioned(
                left: 0,
                top: 13,
                child: Container(
                  width: 4,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: HubColors.white,
                    borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
                  ),
                ),
              ),
            Container(
              height: 32,
              margin: const EdgeInsets.only(left: 8, top: 1, bottom: 1),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(4)),
              child: Row(children: [
                Icon(
                  w.channel.isVoice ? Icons.volume_up_rounded : Icons.tag_rounded,
                  size: 20,
                  color: glyphColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    w.channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HubText.channel.copyWith(
                      color: nameColor,
                      fontWeight: w.unread && !w.selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _VoiceMemberRow extends StatefulWidget {
  _VoiceMemberRow({required this.member}) : super(key: ValueKey('voice:${member.id}'));

  final VoiceMember member;

  @override
  State<_VoiceMemberRow> createState() => _VoiceMemberRowState();
}

class _VoiceMemberRowState extends State<_VoiceMemberRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final bg = _hover ? HubColors.hover : HubColors.sidebar;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        height: 30,
        margin: const EdgeInsets.only(left: 36, bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _hover ? HubColors.hover : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          Avatar(id: m.id, name: m.name, size: 24, speaking: m.speaking, background: bg),
          const SizedBox(width: 8),
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(
                  m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HubText.small.copyWith(
                    color: m.speaking || _hover ? HubColors.header : HubColors.muted,
                  ),
                ),
              ),
              if (m.hosting) ...[
                const SizedBox(width: 4),
                const HostCrown(size: 14),
              ],
            ]),
          ),
          if (m.muted && !m.deafened)
            Tooltip(
              message: 'Muted',
              child: CrossedIcon(Icons.mic_rounded,
                  size: 16, color: HubColors.glyph, strike: HubColors.red, background: bg),
            ),
          if (m.deafened) ...[
            Tooltip(
              message: 'Muted',
              child: CrossedIcon(Icons.mic_rounded,
                  size: 16, color: HubColors.glyph, strike: HubColors.red, background: bg),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Deafened',
              child: CrossedIcon(Icons.headphones_rounded,
                  size: 16, color: HubColors.glyph, strike: HubColors.red, background: bg),
            ),
          ],
        ]),
      ),
    );
  }
}
