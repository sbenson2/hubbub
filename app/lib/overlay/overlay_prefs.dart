import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../atomic_file.dart';

enum OverlayAvatarSize { large, small }

enum OverlayNames { always, whileSpeaking, never }

enum OverlayUsers { always, whileSpeaking }

T _named<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// What the in-game overlay shows (on by default: Large avatars, names and users always).
@immutable
class OverlayPrefs {
  const OverlayPrefs({
    this.enabled = true,
    this.avatarSize = OverlayAvatarSize.large,
    this.names = OverlayNames.always,
    this.users = OverlayUsers.always,
  });
  final bool enabled;
  final OverlayAvatarSize avatarSize;
  final OverlayNames names;
  final OverlayUsers users;

  OverlayPrefs copyWith({
    bool? enabled,
    OverlayAvatarSize? avatarSize,
    OverlayNames? names,
    OverlayUsers? users,
  }) =>
      OverlayPrefs(
        enabled: enabled ?? this.enabled,
        avatarSize: avatarSize ?? this.avatarSize,
        names: names ?? this.names,
        users: users ?? this.users,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'avatarSize': avatarSize.name,
        'names': names.name,
        'users': users.name,
      };

  /// A missing or unknown value falls back to its default.
  static OverlayPrefs fromJson(Object? j) {
    if (j is! Map) return const OverlayPrefs();
    return OverlayPrefs(
      enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      avatarSize: _named(OverlayAvatarSize.values, j['avatarSize'], OverlayAvatarSize.large),
      names: _named(OverlayNames.values, j['names'], OverlayNames.always),
      users: _named(OverlayUsers.values, j['users'], OverlayUsers.always),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OverlayPrefs &&
      other.enabled == enabled &&
      other.avatarSize == avatarSize &&
      other.names == names &&
      other.users == users;

  @override
  int get hashCode => Object.hash(enabled, avatarSize, names, users);
}

/// Where the overlay choices live: a small JSON file in this machine's data root, never synced.
class OverlayPrefsStore {
  OverlayPrefsStore.file(String this._path) : _memory = null;
  OverlayPrefsStore.memory([OverlayPrefs? initial])
      : _path = null,
        _memory = initial ?? const OverlayPrefs();

  final String? _path;
  OverlayPrefs? _memory;

  Future<OverlayPrefs> load() async {
    final path = _path;
    if (path == null) return _memory!;
    try {
      return OverlayPrefs.fromJson(jsonDecode(await File(path).readAsString()));
    } catch (_) {
      return const OverlayPrefs(); // missing or unreadable: the defaults
    }
  }

  Future<void> save(OverlayPrefs p) async {
    final path = _path;
    if (path == null) {
      _memory = p;
      return;
    }
    try {
      await writeFileAtomic(path, jsonEncode(p.toJson()));
    } catch (e) {
      debugPrint('could not save overlay settings: $e');
    }
  }
}

/// The overlay choices, saved on every change.
class OverlaySettings extends ChangeNotifier {
  OverlaySettings(this._store);

  final OverlayPrefsStore _store;
  OverlayPrefs _prefs = const OverlayPrefs();

  OverlayPrefs get prefs => _prefs;

  Future<void> start() async {
    _prefs = await _store.load();
    notifyListeners();
  }

  Future<void> update(OverlayPrefs p) async {
    _prefs = p;
    notifyListeners();
    await _store.save(p);
  }
}
