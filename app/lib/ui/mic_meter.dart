import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// The bar length (0 to 1) for a mic level. Speech sits low on a linear scale, so the bar
/// follows the square root, which is closer to how loud it sounds.
double meterFill(double level) => math.sqrt(level.clamp(0.0, 1.0));

/// Flags a mic that sits at full scale: that is a mic clipping at the source, which the far
/// side hears as a buzz. A level of [near] or more for [run] samples in a row (about 0.6 s at
/// ten samples a second) counts; a single loud peak does not.
class ClipDetector {
  static const near = 0.9;
  static const run = 6;
  int _count = 0;

  /// Feeds one sample; true while the mic is clipping.
  bool add(double level) {
    _count = level >= near ? _count + 1 : 0;
    return _count >= run;
  }
}

/// Level meter under the input device: a bar, and a red clipping warning. Out of a call there
/// is no peer connection to read a level from, so it says so instead of showing a fake one.
class MicMeter extends StatelessWidget {
  const MicMeter({super.key, required this.levels, required this.inCall});
  final Stream<double> levels;
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
  final Stream<double> levels;

  @override
  State<_LiveMeter> createState() => _LiveMeterState();
}

class _LiveMeterState extends State<_LiveMeter> {
  final _clip = ClipDetector();
  StreamSubscription<double>? _sub;
  double _level = 0;
  bool _clipping = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.levels.listen((l) {
      if (!mounted) return;
      setState(() {
        _level = l;
        _clipping = _clip.add(l);
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
