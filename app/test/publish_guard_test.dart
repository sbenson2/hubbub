import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/publish_guard.dart';

void main() {
  test('a_failed_second_publish_unpublishes_the_first_and_stops_every_track', () async {
    final log = <String>[];
    PublishStep step(String name, {bool fail = false}) => PublishStep(
          publish: () async {
            log.add('publish:$name');
            if (fail) throw StateError('no $name');
            return name;
          },
          stop: () async => log.add('stop:$name'),
        );
    await expectLater(
      publishAllOrNone([step('video'), step('audio', fail: true)],
          unpublish: (id) async => log.add('unpublish:$id')),
      throwsStateError,
    );
    expect(log, ['publish:video', 'publish:audio', 'unpublish:video', 'stop:video', 'stop:audio']);
  });

  test('all_publishes_succeeding_leaves_everything_running', () async {
    final log = <String>[];
    await publishAllOrNone([
      PublishStep(publish: () async => 'a', stop: () async => log.add('stop:a')),
    ], unpublish: (id) async => log.add('unpublish:$id'));
    expect(log, isEmpty);
  });
}
