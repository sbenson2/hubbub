import 'package:flutter/material.dart';

import '../audio_diagnostics.dart';
import '../audio_settings.dart';
import 'theme.dart';

/// The red "Recording audio" badge. Mandatory whenever the diagnostics recorder is on: it is
/// in the header and above the user panel, so it is on screen in every view and in a call.
class RecordingIndicator extends StatelessWidget {
  const RecordingIndicator({super.key, required this.audio, this.compact = false});

  final AudioSettings audio;

  /// Smaller, for the channel column.
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: audio,
        builder: (context, _) {
          if (!audio.recordDiagnostics) return const SizedBox.shrink();
          return Semantics(
            label: 'Recording audio',
            child: Container(
              key: const Key('recording-indicator'),
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 4 : 5),
              decoration: BoxDecoration(color: HubColors.red, borderRadius: BorderRadius.circular(4)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text('Recording audio',
                    style: TextStyle(
                        fontFamily: hubFont,
                        fontSize: compact ? 12 : 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ]),
            ),
          );
        },
      );
}

/// Shown when a recording ends: where the files are, with an action that opens the folder.
Future<void> showRecordingSavedDialog(
  BuildContext context,
  AudioDiagnosticsReport report, {
  Future<void> Function(String directory) open = openFolder,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('recording-saved'),
        backgroundColor: HubColors.panel,
        title: const Text('Audio recording saved', style: HubText.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(report.directory, key: const Key('recording-folder'), style: HubText.message),
          const SizedBox(height: 8),
          Text(report.files.join('\n'),
              style: const TextStyle(fontFamily: hubFont, fontSize: 13, color: HubColors.muted)),
        ]),
        actions: [
          TextButton(
            key: const Key('recording-open-folder'),
            onPressed: () => open(report.directory),
            child: const Text('Open folder'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
