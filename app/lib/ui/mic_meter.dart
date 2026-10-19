import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../room_adapter.dart' show MicLevels;
import 'theme.dart';

/// The bar length (0 to 1) for a mic level. Speech sits low on a linear scale, so the bar
/// follows the square root, which is closer to how loud it sounds.
double meterFill(double level) => math.sqrt(level.clamp(0.0, 1.0));

/// Flags a mic that clips at the source, which the far side hears as a buzz. The capture path
/// reports, about every 50 ms, the share of its 10 ms blocks whose pre-gain peak reached 0.98 of
/// full scale ([MicLevels.clip]); the mic is clipping while more than 1% of the blocks over the
/// last 500 ms (ten reports) did. The pre-gain peak is the device's own level, so a boost from
/// the input volume slider never shows as clipping.
class ClipWindow {
  static const threshold = 0.01;
  static const reports = 10;
  final _recent = <double>[];

  /// Feeds one report's clipped share; true while the mic is clipping.
  bool add(double clip) {
    _recent.add(clip);
    if (_recent.length > reports) _recent.removeAt(0);
    final mean = _recent.reduce((a, b) => a + b) / _recent.length;
    return mean > threshold;
  }
}

/// Level meter under the input device: a bar of the peak that is sent (after the input volume),
/// and a red clipping warning from the pre-gain peak. Out of a call nothing captures, so it says
/// so instead of showing a fake level.
class MicMeter extends StatelessWidget {
  const MicMeter({super.key, required this.levels, required this.inCall});
  final Stream<MicLevels> levels;
  final ValueListenable<bool> inCall;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: inCall,
        builder: (context, connected, _) => connected
            ? _LiveMeter(levels: levels)
            : const Text('Join a voice channel to test your mic',
                style: TextStyle(
                    fontFamily: hubFont, fontSize: 14, height: 1.286, color: HubColors.muted)),
      );
}

class _LiveMeter extends StatefulWidget {
  const _LiveMeter({required this.levels});
  final Stream<MicLevels> levels;

  @override
  State<_LiveMeter> createState() => _LiveMeterState();
}

class _LiveMeterState extends State<_LiveMeter> {
  final _clip = ClipWindow();
  StreamSubscription<MicLevels>? _sub;
  double _level = 0;
  bool _clipping = false;
  int _samples = 0;

  @override
  void initState() {
    super.initState();
    _sub = widget.levels.listen((l) {
      if (!mounted) return;
      // about once a second at twenty reports a second; kept so real journals show the peaks
      if (_samples++ % 20 == 0) {
        debugPrint('hubbub: micLevel ${l.post} pre=${l.pre} post=${l.post} clip=${l.clip} '
            'speech=${l.speech}');
      }
      setState(() {
        _level = l.post;
        _clipping = _clip.add(l.clip);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 8,
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: HubColors.rail,
              borderRadius: BorderRadius.circular(4),
            ),
            child: FractionallySizedBox(
              key: const Key('mic-level'),
              widthFactor: meterFill(_level),
              child: Container(
                decoration: BoxDecoration(
                  color: _clipping ? HubColors.red : HubColors.green,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          if (_clipping)
            const Padding(
              key: Key('mic-clipping'),
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Your microphone is clipping. Lower its volume in your system sound settings.',
                style: TextStyle(
                    fontFamily: hubFont, fontSize: 12, height: 1.33, color: HubColors.red),
              ),
            ),
        ],
      );
}
