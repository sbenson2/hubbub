import 'dart:async';

import 'package:flutter/material.dart';

import '../../share_sources.dart';
import '../theme.dart';
import '../user_panel.dart';
import 'dialog_shell.dart';

/// How often the open picker re-reads the screens and windows (new windows, new titles,
/// fresher thumbnails).
const sharePickerRefresh = Duration(seconds: 3);

const shareUnsupported = "Screen sharing isn't supported on this desktop yet";

/// Discord's "Share Your Screen": Screens and Applications tabs with thumbnails, then Go Live.
/// Returns the chosen source id, or null when cancelled.
Future<String?> showSharePicker(BuildContext context, ShareSourceLoader load) =>
    showHubDialog<String>(context, builder: (_) => _SharePicker(load: load));

class _SharePicker extends StatefulWidget {
  const _SharePicker({required this.load});

  final ShareSourceLoader load;

  @override
  State<_SharePicker> createState() => _SharePickerState();
}

class _SharePickerState extends State<_SharePicker> {
  List<ShareSource>? _sources;
  bool _failed = false;
  bool _loading = false;
  ShareKind _tab = ShareKind.screen;
  String? _selected;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(sharePickerRefresh, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final list = await widget.load();
      if (!mounted) return;
      final first = _sources == null;
      setState(() {
        _sources = list;
        // Nothing to offer at the start (not even a screen) means no desktop capture here.
        _failed = first && list.isEmpty;
        if (_selected != null && !list.any((s) => s.id == _selected)) _selected = null;
      });
    } catch (e) {
      debugPrint('hubbub: share sources failed: $e');
      // A failure after a good listing keeps that listing; a failure at the start is final.
      if (mounted && _sources == null) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return HubDialogCard(
        title: 'Share Your Screen',
        body: Text(shareUnsupported,
            style: HubText.message.copyWith(color: HubColors.interactive)),
        footer: Row(children: [
          const Spacer(),
          HubButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
        ]),
      );
    }
    final shown = [for (final s in _sources ?? const <ShareSource>[]) if (s.kind == _tab) s];
    return HubDialogCard(
      title: 'Share Your Screen',
      width: 720,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _Tab('Screens', _tab == ShareKind.screen, () => setState(() => _tab = ShareKind.screen)),
          const SizedBox(width: 8),
          _Tab('Applications', _tab == ShareKind.window, () => setState(() => _tab = ShareKind.window)),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 300,
          child: _sources == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : shown.isEmpty
                  ? Center(
                      child: Text(
                          _tab == ShareKind.screen ? 'No screens found.' : 'No open windows found.',
                          style: HubText.message.copyWith(color: HubColors.interactive)))
                  : SingleChildScrollView(
                      child: Wrap(spacing: 12, runSpacing: 12, children: [
                        for (final s in shown)
                          _SourceCell(
                            source: s,
                            selected: s.id == _selected,
                            onTap: () => setState(() => _selected = s.id),
                          ),
                      ]),
                    ),
        ),
      ]),
      footer: Row(children: [
        const Spacer(),
        HubLinkButton('Cancel', () => Navigator.of(context).pop()),
        const SizedBox(width: 8),
        HubButton(
          label: 'Go Live',
          color: HubColors.green,
          hoverColor: const Color(0xFF1A8B4C),
          onPressed: _selected == null ? null : () => Navigator.of(context).pop(_selected),
        ),
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.label, this.active, this.onTap);

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: active ? HubColors.selected : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style: TextStyle(
                  fontFamily: hubFont,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: active ? HubColors.header : HubColors.interactive,
                )),
          ),
        ),
      );
}

class _SourceCell extends StatelessWidget {
  const _SourceCell({required this.source, required this.selected, required this.onTap});

  final ShareSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumb = source.thumbnail;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: selected ? HubColors.selected : HubColors.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? HubColors.accent : Colors.transparent, width: 2),
          ),
          child: Column(children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: thumb == null
                    ? const ColoredBox(
                        color: HubColors.rail,
                        child: Icon(Icons.desktop_windows_rounded, color: HubColors.glyph))
                    : Image.memory(thumb, fit: BoxFit.contain, gaplessPlayback: true),
              ),
            ),
            const SizedBox(height: 6),
            Text(source.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HubText.message.copyWith(
                    fontSize: 13, color: selected ? HubColors.header : HubColors.interactive)),
          ]),
        ),
      ),
    );
  }
}
