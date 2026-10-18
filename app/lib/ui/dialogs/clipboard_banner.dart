import 'package:flutter/material.dart';

import '../../hub_api.dart';
import '../theme.dart';
import '../user_panel.dart';

/// Offers an invite found on the clipboard. It only offers: pressing Join opens the Join
/// dialog, and nothing joins by itself.
class ClipboardBanner extends StatelessWidget {
  const ClipboardBanner({
    super.key,
    required this.preview,
    required this.onJoin,
    required this.onDismiss,
  });

  final AppInvitePreview preview;
  final VoidCallback onJoin;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        color: HubColors.accent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          const Icon(Icons.content_paste_rounded, size: 20, color: HubColors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text('You copied an invite to ${preview.name}.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HubText.message.copyWith(color: HubColors.white)),
          ),
          HubButton(
            label: 'Join',
            color: HubColors.white.withValues(alpha: 0.2),
            hoverColor: HubColors.white.withValues(alpha: 0.3),
            onPressed: onJoin,
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 20, color: HubColors.white),
          ),
        ]),
      );
}
