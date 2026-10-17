import 'package:flutter/material.dart';

/// Palette tokens: approximations of Discord's dark theme.
abstract final class HubColors {
  static const rail = Color(0xFF1E1F22);
  static const sidebar = Color(0xFF2B2D31);
  static const main = Color(0xFF313338);
  static const tertiary = Color(0xFF383A40);
  static const hover = Color(0xFF35373C);
  static const selected = Color(0xFF404249);
  static const text = Color(0xFFDBDEE1);
  static const muted = Color(0xFF949BA4);
  static const header = Color(0xFFF2F3F5);
  static const accent = Color(0xFF5865F2);
  static const green = Color(0xFF23A55A);
  static const red = Color(0xFFF23F43);
  static const divider = Color(0xFF3F4147);

  // Further shades of the same theme.
  static const white = Color(0xFFFFFFFF);

  /// The user panel and Voice Connected bar under the channel list.
  static const panel = Color(0xFF232428);

  /// Channel glyphs (#, speaker) at rest.
  static const glyph = Color(0xFF80848E);

  /// Icon buttons at rest, and secondary text.
  static const interactive = Color(0xFFB5BAC1);
  static const messageHover = Color(0xFF2E3035);
  static const placeholder = Color(0xFF6D6F78);
  static const tooltip = Color(0xFF111214);
  static const yellow = Color(0xFFF0B232);

  /// The call stage and its participant tiles.
  static const stage = Color(0xFF000000);
  static const tile = Color(0xFF232428);

  /// Default avatar colours, picked by member id.
  static const avatars = [
    Color(0xFF5865F2),
    Color(0xFF757E8A),
    Color(0xFF3BA55C),
    Color(0xFFFAA61A),
    Color(0xFFED4245),
    Color(0xFFEB459F),
  ];
}

const hubFont = 'NotoSans';

/// The app's text styles; sizes and weights follow Discord's desktop client.
abstract final class HubText {
  static const message = TextStyle(
      fontFamily: hubFont, fontSize: 16, height: 1.375, color: HubColors.text);
  static const author = TextStyle(
      fontFamily: hubFont,
      fontSize: 16,
      height: 1.375,
      fontWeight: FontWeight.w600,
      color: HubColors.header);
  static const timestamp = TextStyle(
      fontFamily: hubFont,
      fontSize: 12,
      height: 1.375,
      fontWeight: FontWeight.w500,
      color: HubColors.muted);
  static const title = TextStyle(
      fontFamily: hubFont,
      fontSize: 16,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: HubColors.header);
  static const category = TextStyle(
      fontFamily: hubFont,
      fontSize: 12,
      height: 1.333,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      color: HubColors.muted);
  static const channel = TextStyle(
      fontFamily: hubFont,
      fontSize: 16,
      height: 1.25,
      fontWeight: FontWeight.w500,
      color: HubColors.muted);
  static const small = TextStyle(
      fontFamily: hubFont,
      fontSize: 14,
      height: 1.286,
      fontWeight: FontWeight.w500,
      color: HubColors.muted);
}

ThemeData hubbubTheme() {
  const scheme = ColorScheme.dark(
    primary: HubColors.accent,
    onPrimary: HubColors.white,
    secondary: HubColors.accent,
    surface: HubColors.main,
    onSurface: HubColors.text,
    error: HubColors.red,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: hubFont,
    scaffoldBackgroundColor: HubColors.main,
    canvasColor: HubColors.main,
    // Discord has no ink ripples: hover and press states are flat fills.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: HubColors.text,
      selectionColor: HubColors.accent.withValues(alpha: 0.5),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: HubColors.tooltip,
        borderRadius: BorderRadius.circular(5),
        boxShadow: const [BoxShadow(color: Color(0x3D000000), blurRadius: 16, offset: Offset(0, 8))],
      ),
      textStyle: const TextStyle(
          fontFamily: hubFont, fontSize: 14, fontWeight: FontWeight.w500, color: HubColors.text),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      waitDuration: const Duration(milliseconds: 300),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.all(const Color(0xFF1A1B1E)),
      trackColor: WidgetStateProperty.all(HubColors.sidebar),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: HubColors.main,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: HubColors.tooltip,
      contentTextStyle: TextStyle(fontFamily: hubFont, fontSize: 14, color: HubColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    iconTheme: const IconThemeData(color: HubColors.interactive),
  );
}
