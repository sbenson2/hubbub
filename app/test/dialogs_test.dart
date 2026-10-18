import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/hub_api.dart';
import 'package:hubbub/hub_controller.dart';
import 'package:hubbub/links.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/dialogs/invite_dialog.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support/fakes.dart';

void main() {
  final dialogField = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
  late FakeHub hub;
  late HubController controller;
  late FakeRoom room;
  String? clipboard;

  // Built inside each test body so the fakes' streams run in the test's fake-async zone.
  void arrange(WidgetTester tester, {String name = 'Shawn', bool withServer = true}) {
    hub = FakeHub(name: name);
    if (withServer) {
      final me = member('aaaa', 'Shawn');
      final ev = StreamController<AppNodeEvent>.broadcast();
      final node = FakeNode(
          events: ev, me: me, roster: [me], name: 'Game Night', textChannels: ['general'],
          voiceChannels: ['lobby']);
      hub.add('c1', 'Game Night', node, isOwner: true);
      addTearDown(() async {
        node.dispose();
        await ev.close();
      });
    }
    room = FakeRoom();
    controller = HubController(hub)..refresh();
    addTearDown(controller.dispose);
    clipboard = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return clipboard == null ? null : {'text': clipboard};
      }
      return null;
    });
    addTearDown(() =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<void> pump(WidgetTester tester, {LinkSource? links}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: HomePage(
        hub: controller,
        room: room,
        loadConfig: () => throw StateError('a hub needs no config'),
        linkSource: links,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a_launch_link_opens_the_join_dialog_for_it', (tester) async {
    arrange(tester);
    hub.scriptedPreview = const AppInvitePreview(cid: 'x', name: 'Quiet Club', expiresMin: 0);
    final links = FakeLinks(initialLink: 'hubbub://join/x');
    await pump(tester, links: links);

    expect(find.textContaining('Quiet Club'), findsWidgets);
    expect(dialogField, findsOneWidget);
  });

  testWidgets('a_link_before_a_name_waits_for_the_name', (tester) async {
    arrange(tester, name: '');
    hub.scriptedPreview = const AppInvitePreview(cid: 'x', name: 'Quiet Club', expiresMin: 0);
    final links = FakeLinks(initialLink: 'hubbub://join/x');
    await pump(tester, links: links);

    expect(find.text('What should everyone call you?'), findsOneWidget);
    expect(find.textContaining('Quiet Club'), findsNothing);
    await tester.enterText(dialogField, 'Ada');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Quiet Club'), findsWidgets);
  });

  testWidgets('first_run_asks_for_a_name_and_saves_it', (tester) async {
    arrange(tester, name: '');
    await pump(tester);

    expect(find.text('What should everyone call you?'), findsOneWidget);
    await tester.enterText(dialogField, 'Ada');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(hub.name, 'Ada');
    expect(find.text('What should everyone call you?'), findsNothing);
  });

  testWidgets('a_known_name_skips_the_prompt', (tester) async {
    arrange(tester);
    await pump(tester);
    expect(find.text('What should everyone call you?'), findsNothing);
  });

  testWidgets('plus_leads_to_create_my_own_which_creates_and_selects_a_server',
      (tester) async {
    arrange(tester);
    await pump(tester);

    await tester.tap(find.byTooltip('Add a Server'));
    await tester.pumpAndSettle();
    expect(find.text('Create a server'), findsOneWidget);
    expect(find.text('Have an invite already?'), findsOneWidget);
    expect(find.text('Join a Server'), findsOneWidget);

    await tester.tap(find.text('Create My Own'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(dialogField);
    expect(field.controller!.text, "Shawn's server");

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(controller.communities.map((c) => c.name), ['Game Night', "Shawn's server"]);
    expect(controller.selectedCid, 'cid-2');
    expect(find.text('Create a server'), findsNothing);
    expect(find.byTooltip("Shawn's server"), findsOneWidget);
  });

  testWidgets('invite_people_copies_the_link_and_shows_a_qr_code', (tester) async {
    arrange(tester);
    await pump(tester);

    await tester.tap(find.byTooltip('Server Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Leave Server'), findsOneWidget);
    await tester.tap(find.text('Invite People'));
    await tester.pumpAndSettle();

    expect(hub.calls, contains('invite:c1:10080:0'));
    expect(find.text('hubbub://join/c1'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(clipboard, 'hubbub://join/c1');
    expect(find.text('Copied'), findsOneWidget);

    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.text('Show QR code'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('edit_invite_link_changes_the_limits_and_revoke_makes_a_fresh_link',
      (tester) async {
    arrange(tester);
    await pump(tester);
    await tester.tap(find.text('Invite your friends'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit invite link'));
    await tester.pumpAndSettle();
    expect(expiryChoices.map((c) => c.$1), ['30 minutes', '1 hour', '1 day', '7 days', 'Never']);
    expect(useChoices.map((c) => c.$1), ['No limit', '1 use', '5 uses', '10 uses']);

    await tester.tap(find.byKey(const ValueKey('uses')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 uses').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate a New Link'));
    await tester.pumpAndSettle();
    expect(hub.calls, contains('invite:c1:10080:5'));

    await tester.tap(find.text('Revoke link'));
    await tester.pumpAndSettle();
    expect(hub.calls, containsAllInOrder(['revoke:c1', 'invite:c1:10080:5']));
  });

  testWidgets('join_shows_the_preview_then_progress_and_selects_the_server', (tester) async {
    arrange(tester);
    final me = member('aaaa', 'Shawn');
    final ev = StreamController<AppNodeEvent>.broadcast();
    final node = FakeNode(events: ev, me: me, roster: [me], name: 'Book Club');
    addTearDown(() async {
      node.dispose();
      await ev.close();
    });
    hub.willJoin('hubbub://join/book', 'c9', 'Book Club', node);
    await pump(tester);

    await tester.tap(find.byTooltip('Add a Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join a Server'));
    await tester.pumpAndSettle();

    await tester.enterText(dialogField, 'nonsense');
    await tester.pump();
    expect(find.text('That is not a valid invite.'), findsOneWidget);

    await tester.enterText(dialogField, 'hubbub://join/book');
    await tester.pump();
    expect(find.text('Book Club'), findsOneWidget);

    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(controller.selectedCid, 'c9');
    expect(find.text('Joining Book Club'), findsNothing);
    expect(find.byTooltip('Book Club'), findsOneWidget);
  });

  testWidgets('join_reports_offline_and_denied', (tester) async {
    arrange(tester);
    final offline = StreamController<JoinEvent>();
    hub
      ..scriptedJoin = offline.stream
      ..scriptedPreview = const AppInvitePreview(cid: 'x', name: 'Quiet Club', expiresMin: 0);
    await pump(tester);

    await tester.tap(find.byTooltip('Add a Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join a Server'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogField, 'hubbub://join/x');
    await tester.pump();
    await tester.tap(find.text('Join'));
    await tester.pump();
    offline.add(const JoinTrying());
    await tester.pump();
    expect(find.text('Looking for someone from Quiet Club…'), findsOneWidget);

    offline.add(const JoinOffline());
    await tester.pump();
    expect(find.text('Nobody from Quiet Club is online right now; Hubbub will keep trying.'),
        findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(hub.calls, contains('joinCancel'));
  });

  testWidgets('leave_server_removes_it_from_the_rail', (tester) async {
    arrange(tester);
    await pump(tester);
    expect(find.byTooltip('Game Night'), findsOneWidget);

    await tester.tap(find.byTooltip('Server Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave Server').last);
    await tester.pumpAndSettle();

    expect(controller.communities, isEmpty);
    expect(find.byTooltip('Game Night'), findsNothing);
    expect(find.text('Import community file'), findsNothing);
    expect(find.text('Create My Own'), findsOneWidget);
  });

  testWidgets('the_clipboard_banner_offers_an_unseen_invite_and_never_joins', (tester) async {
    arrange(tester);
    final me = member('aaaa', 'Shawn');
    final ev = StreamController<AppNodeEvent>.broadcast();
    final node = FakeNode(events: ev, me: me, roster: [me], name: 'Book Club');
    addTearDown(() async {
      node.dispose();
      await ev.close();
    });
    hub.willJoin('hubbub://join/book', 'c9', 'Book Club', node);
    await pump(tester);
    expect(find.textContaining('You copied an invite'), findsNothing);

    clipboard = 'hubbub://join/book';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('You copied an invite to Book Club.'), findsOneWidget);
    expect(controller.communities, hasLength(1), reason: 'the banner never joins by itself');

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('You copied an invite'), findsNothing,
        reason: 'a seen invite is not offered again');
  });

  testWidgets('copying_your_own_invite_does_not_raise_the_banner_on_resume', (tester) async {
    arrange(tester);
    await pump(tester);
    hub.scriptedPreview = const AppInvitePreview(cid: 'c1', name: 'Game Night', expiresMin: 0);

    await tester.tap(find.text('Invite your friends'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('You copied an invite'), findsNothing);
  });

  testWidgets('the_invite_footnote_describes_the_link_not_the_unsaved_dropdowns',
      (tester) async {
    arrange(tester);
    await pump(tester);
    await tester.tap(find.text('Invite your friends'));
    await tester.pumpAndSettle();
    final before = find.textContaining('expires in 7 days');
    expect(before, findsOneWidget);

    await tester.tap(find.text('Edit invite link'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uses')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 uses').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('5 uses at most'), findsNothing);
    expect(before, findsOneWidget);

    await tester.tap(find.text('Generate a New Link'));
    await tester.pumpAndSettle();
    expect(find.textContaining('5 uses at most'), findsOneWidget);
  });

  testWidgets('a_failed_leave_or_name_save_shows_a_snackbar', (tester) async {
    arrange(tester);
    await pump(tester);
    hub.failWrites = true;
    await tester.tap(find.byTooltip('Server Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave Server').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not leave the server'), findsOneWidget);
    expect(controller.communities, hasLength(1));
  });

  testWidgets('a_failed_name_save_shows_a_snackbar', (tester) async {
    arrange(tester, name: '');
    hub.failWrites = true;
    await pump(tester);
    await tester.enterText(dialogField, 'Ada');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save your name'), findsOneWidget);
  });

  testWidgets('a_link_still_opens_when_the_name_cannot_be_saved', (tester) async {
    arrange(tester, name: '');
    hub
      ..failWrites = true
      ..scriptedPreview = const AppInvitePreview(cid: 'x', name: 'Quiet Club', expiresMin: 0);
    await pump(tester, links: FakeLinks(initialLink: 'hubbub://join/x'));
    await tester.enterText(dialogField, 'Ada');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Quiet Club'), findsWidgets);
  });

  testWidgets('dialog_cards_clip_the_footer_to_the_rounded_corners', (tester) async {
    arrange(tester);
    await pump(tester);
    await tester.tap(find.byTooltip('Add a Server'));
    await tester.pumpAndSettle();
    expect(tester.widget<Dialog>(find.byType(Dialog)).clipBehavior, Clip.antiAlias);
  });
}
