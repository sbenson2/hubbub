import 'package:flutter/material.dart';

import 'audio_menus.dart';
import 'avatar.dart';
import 'channel_sidebar.dart';
import 'theme.dart';
import 'video_view.dart';

/// One person on the call stage: a 16:9 tile with their avatar, name and mic state.
class ParticipantTile extends StatelessWidget {
  ParticipantTile({required this.member}) : super(key: ValueKey('tile:${member.id}'));

  final VoiceMember member;

  @override
  Widget build(BuildContext context) {
    final m = member;
    return UserVolumeRegion(
        id: m.id, name: m.name, isMe: m.isMe, child: LayoutBuilder(builder: (context, box) {
      final avatar = (box.maxHeight * 0.4).clamp(40.0, 80.0);
      return Container(
        decoration: BoxDecoration(
          color: HubColors.tile,
          borderRadius: BorderRadius.circular(8),
        ),
        // The ring is always there, clear while quiet: a foreground decoration that comes and
        // goes changes the Container's tree, which remounts the video (a black flash per word).
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: m.speaking ? HubColors.green : Colors.transparent, width: 2),
        ),
        child: Stack(children: [
          if (m.camera != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: VideoView(feed: m.camera!, mirror: m.isMe),
              ),
            )
          else
            Center(
              child: Avatar(id: m.id, name: m.name, size: avatar, background: HubColors.tile),
            ),
          Positioned(
            left: 8,
            bottom: 8,
            right: 8,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0x99000000),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: hubFont,
                        fontSize: 14,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: HubColors.white,
                      ),
                    ),
                  ),
                  if (m.muted || m.deafened) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: m.deafened ? 'Deafened' : 'Muted',
                      child: Icon(
                        m.deafened ? Icons.headset_off_rounded : Icons.mic_off_rounded,
                        size: 16,
                        color: HubColors.red,
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ]),
      );
    }));
  }
}
