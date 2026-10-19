import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/atomic_file.dart';

void main() {
  test('replaces_the_file_and_leaves_no_temp_file', () async {
    final dir = Directory.systemTemp.createTempSync('atomic');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}audio.json';
    await writeFileAtomic(path, '{"a":1}');
    await writeFileAtomic(path, '{"a":2}');
    expect(File(path).readAsStringSync(), '{"a":2}');
    expect(dir.listSync().length, 1);
  });

  test('overlapping_writes_each_land_whole', () async {
    final dir = Directory.systemTemp.createTempSync('atomic');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}devices.json';
    await Future.wait([for (var i = 0; i < 20; i++) writeFileAtomic(path, '{"n":$i}')]);
    expect(File(path).readAsStringSync(), matches(RegExp(r'^\{"n":\d+\}$')));
    expect(dir.listSync().length, 1);
  });

  test('a_failed_write_leaves_the_old_file_and_no_temp', () async {
    final dir = Directory.systemTemp.createTempSync('atomic');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}shell.json';
    await writeFileAtomic(path, 'old');
    File(path).deleteSync(); // a directory in its place cannot be replaced by a file
    Directory(path).createSync();
    await expectLater(writeFileAtomic(path, 'new'), throwsA(isA<FileSystemException>()));
    expect(dir.listSync().length, 1);
  });
}
