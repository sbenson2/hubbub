import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// An overlay image: premultiplied RGBA, top-down, in physical px.
class OverlayBitmap {
  const OverlayBitmap({required this.rgba, required this.width, required this.height});
  final Uint8List rgba;
  final int width, height;
}

/// Renders [child] at its own size (up to 1000×2000 logical px) into an [OverlayBitmap] at
/// [pixelRatio] physical px per logical px; pixels the child doesn't paint are fully transparent.
///
/// The tree is detached from the app's and never schedules a frame: while the main window is
/// hidden in the tray, the binding turns frames off, so nothing here may wait for one. Nothing is
/// kept between calls.
Future<OverlayBitmap> renderOverlayImage(Widget child, {required double pixelRatio}) async {
  final boundary = RenderRepaintBoundary();
  final positioned = RenderPositionedBox(alignment: Alignment.topLeft, child: boundary);
  final view = RenderView(
    view: WidgetsBinding.instance.platformDispatcher.implicitView!,
    child: positioned,
    configuration: ViewConfiguration(
      logicalConstraints: const BoxConstraints(maxWidth: 1000, maxHeight: 2000),
      devicePixelRatio: pixelRatio,
    ),
  );
  final pipeline = PipelineOwner()..rootNode = view;
  view.prepareInitialFrame();
  final focus = FocusManager();
  final build = BuildOwner(focusManager: focus);
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  ).attachToRenderTree(build);
  try {
    build
      ..buildScope(root)
      ..finalizeTree();
    pipeline
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      // rawRgba is premultiplied (see ImageByteFormat in dart:ui).
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return OverlayBitmap(
        rgba: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  } finally {
    // Unmount the child so its states and render objects dispose, then release the rest; the
    // focus manager in particular registers a lifecycle observer on the binding.
    RenderObjectToWidgetAdapter<RenderBox>(container: boundary).attachToRenderTree(build, root);
    build
      ..buildScope(root)
      ..finalizeTree();
    focus.dispose();
    pipeline
      ..rootNode = null
      ..dispose();
    boundary.dispose();
    positioned.dispose();
    view.dispose();
  }
}
