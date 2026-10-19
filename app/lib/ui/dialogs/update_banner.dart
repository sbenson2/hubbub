import 'package:flutter/material.dart';

import '../../install.dart';
import '../theme.dart';
import '../user_panel.dart';

/// "Update ready - Restart", shown once a newer Hubbub has been downloaded. During a call there is
/// no button: restarting would drop the call, so it waits for the call to end (or for a quit).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updates});

  final UpdateController updates;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([updates, updates.callActive]),
        builder: (context, _) {
          if (!updates.ready) return const SizedBox.shrink();
          final canRestart = updates.canRestartNow;
          final version = updates.version;
          return Container(
            color: HubColors.green,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.system_update_alt_rounded, size: 20, color: HubColors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  canRestart
                      ? 'Update ready${version == null ? '' : ' ($version)'}.'
                      : 'Update ready. Restart after your call, or it installs when you quit.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HubText.message.copyWith(color: HubColors.white),
                ),
              ),
              if (canRestart)
                HubButton(
                  label: 'Restart',
                  color: HubColors.white.withValues(alpha: 0.2),
                  hoverColor: HubColors.white.withValues(alpha: 0.3),
                  onPressed: () => updates.restart(),
                ),
            ]),
          );
        },
      );
}
