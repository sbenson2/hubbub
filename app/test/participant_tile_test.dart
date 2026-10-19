import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/ui/channel_sidebar.dart';
import 'package:hubbub/ui/participant_tile.dart';
import 'package:hubbub/ui/theme.dart';
import 'package:hubbub/ui/video_view.dart';

void main() {
  testWidgets('speaking_does_not_remount_the_camera_video', (tester) async {
    Future<void> pump({required bool speaking}) => tester.pumpWidget(MaterialApp(
          theme: hubbubTheme(),
          home: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: ParticipantTile(
                member: VoiceMember(id: 'aaaa', name: 'Alice', speaking: speaking, camera: const VideoFeed('cam')),
              ),
            ),
          ),
        ));

    await pump(speaking: false);
    final quiet = tester.element(find.byType(VideoView));
    await pump(speaking: true);
    expect(identical(tester.element(find.byType(VideoView)), quiet), isTrue,
        reason: 'a remounted renderer shows black until its first frame');
    await pump(speaking: false);
    expect(identical(tester.element(find.byType(VideoView)), quiet), isTrue);
  });
}
