import 'package:flutter/material.dart';

import '../theme.dart';

/// Shows [builder] in Discord's modal: a dimmed barrier and a centred card.
Future<T?> showHubDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      barrierColor: const Color(0xD9000000),
      builder: builder,
    );

/// The card every dialog shares: a [title], an optional [subtitle], the [child], and a
/// [footer] row on the darker strip at the bottom.
class HubDialogCard extends StatelessWidget {
  const HubDialogCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.body,
    this.footer,
    this.width = 440,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? footer;
  final double width;

  @override
  Widget build(BuildContext context) => Dialog(
        // The footer strip is square; the rounded card must clip it.
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: hubFont,
                        fontSize: 24,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: HubColors.header,
                      )),
                  if (subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(subtitle!,
                        style: HubText.message.copyWith(color: HubColors.interactive)),
                  ],
                  const SizedBox(height: 16),
                  body,
                ]),
              ),
              if (footer != null)
                Container(
                  width: double.infinity,
                  color: HubColors.sidebar,
                  padding: const EdgeInsets.all(16),
                  child: footer,
                ),
            ]),
          ),
        ),
      );
}

/// A flat text button, as Discord's "Cancel" and "Back".
class HubLinkButton extends StatelessWidget {
  const HubLinkButton(this.label, this.onPressed, {super.key});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        child: Text(label,
            style: const TextStyle(
                fontFamily: hubFont,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: HubColors.header)),
      );
}

/// A small caps field label above an input.
class HubFieldLabel extends StatelessWidget {
  const HubFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: HubText.category),
      );
}

/// Discord's dark rounded text field.
InputDecoration hubFieldDecoration({String? hint}) => InputDecoration(
      isDense: true,
      filled: true,
      fillColor: HubColors.rail,
      hintText: hint,
      hintStyle: HubText.message.copyWith(color: HubColors.placeholder),
      contentPadding: const EdgeInsets.all(10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: BorderSide.none,
      ),
    );

