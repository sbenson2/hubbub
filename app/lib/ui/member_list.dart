import 'package:flutter/material.dart';

import '../src/rust/api/hubbub.dart';
import 'avatar.dart';
import 'theme.dart';

/// The right-hand member list: yourself and members with a live link first, the rest
/// of the community dimmed below.
class MemberList extends StatelessWidget {
  const MemberList({
    super.key,
    required this.members,
    required this.me,
    required this.online,
    required this.host,
  });

  final List<AppMember> members;
  final String? me;

  /// Members with an active PeerUp.
  final Set<String> online;
  final String? host;

  bool _isOnline(AppMember m) => m.id == me || online.contains(m.id);

  @override
  Widget build(BuildContext context) {
    int byName(AppMember a, AppMember b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    final up = members.where(_isOnline).toList()..sort(byName);
    final down = members.where((m) => !_isOnline(m)).toList()..sort(byName);
    return ColoredBox(
      color: HubColors.sidebar,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 20),
        children: [
          _GroupHeader('ONLINE — ${up.length}'),
          for (final m in up) _MemberRow(member: m, online: true, hosting: m.id == host),
          if (down.isNotEmpty) ...[
            _GroupHeader('OFFLINE — ${down.length}'),
            for (final m in down)
              Opacity(
                opacity: 0.3,
                child: _MemberRow(member: m, online: false, hosting: m.id == host),
              ),
          ],
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(16, 24, 8, 0),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HubText.category.copyWith(fontWeight: FontWeight.w600)),
      );
}

class _MemberRow extends StatefulWidget {
  _MemberRow({required this.member, required this.online, required this.hosting})
      : super(key: ValueKey('member:${member.id}'));

  final AppMember member;
  final bool online;
  final bool hosting;

  @override
  State<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends State<_MemberRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final name = m.name.isEmpty ? m.tag : m.name;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        height: 42,
        margin: const EdgeInsets.only(left: 8, right: 8, bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _hover ? HubColors.hover : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          Avatar(
            id: m.id,
            name: name,
            size: 32,
            presence: widget.online ? Presence.online : Presence.offline,
            background: _hover ? HubColors.hover : HubColors.sidebar,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HubText.channel.copyWith(
                color: _hover ? HubColors.text : HubColors.interactive,
              ),
            ),
          ),
          if (widget.hosting) ...[
            const SizedBox(width: 4),
            const HostCrown(),
          ],
        ]),
      ),
    );
  }
}
