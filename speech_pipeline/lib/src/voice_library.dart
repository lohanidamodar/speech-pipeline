import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'clone_engines.dart';

/// The set of voices available to speak in, and their reference recordings.
///
/// Reference audio is copied into the library rather than referenced where it
/// was recorded. A recorder writes to a cache directory the OS is free to
/// empty, so a profile pointing there would work until the day it silently
/// did not.
///
/// [VoiceProfile.builtIn] is always first and cannot be removed: it needs no
/// recording, so it is the one voice that works before the user has made any.
class VoiceLibrary {
  VoiceLibrary(this.directory);

  final Directory directory;

  final _saved = <VoiceProfile>[];

  File get _index => File('${directory.path}/voices.json');

  /// Every voice, built-in first.
  List<VoiceProfile> get profiles => [VoiceProfile.builtIn, ..._saved];

  /// Only the clones.
  List<VoiceProfile> get clones => List.unmodifiable(_saved);

  VoiceProfile? byId(String id) {
    if (id == VoiceProfile.builtIn.id) return VoiceProfile.builtIn;
    for (final p in _saved) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Reads the index, dropping any profile whose audio has gone missing.
  ///
  /// A half-present library is worse than a smaller one: selecting a voice
  /// whose file was deleted fails inside the engine, mid-reply.
  Future<void> load() async {
    _saved.clear();
    if (!_index.existsSync()) return;

    final raw = jsonDecode(await _index.readAsString());
    if (raw is! List) return;

    var dropped = false;
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final profile = VoiceProfile.fromJson(entry);
      // A described voice has no recording to check — the description is the
      // whole of it. Only a clone whose audio has gone is dropped.
      final keep = switch (profile.referenceWavPath) {
        final path? => File(path).existsSync(),
        null => profile.isDesigned,
      };
      if (keep) {
        _saved.add(profile);
      } else {
        dropped = true;
      }
    }
    if (dropped) await _write();
  }

  /// Stores [wav] as a new voice and returns its profile.
  ///
  /// [transcript] should be what the recording actually says — the clone is
  /// materially better with it.
  Future<VoiceProfile> add({
    required String name,
    required Uint8List wav,
    String? transcript,
    String? language,
  }) async {
    await directory.create(recursive: true);
    final id = _newId(name);
    final path = '${directory.path}/$id.wav';
    await File(path).writeAsBytes(wav);

    final profile = VoiceProfile(
      id: id,
      name: name.trim().isEmpty ? id : name.trim(),
      referenceWavPath: path,
      transcript: transcript,
      language: language,
    );
    _saved.add(profile);
    await _write();
    return profile;
  }

  /// Stores a voice that exists only as a description.
  ///
  /// No recording, so nothing is written beside the index: the description is
  /// the whole of the voice. Only models whose `canDesignVoice` is true can
  /// act on it — the rest will speak in their default voice.
  Future<VoiceProfile> describe({
    required String description,
    String? name,
    String? language,
  }) async {
    final wanted = description.trim();
    if (wanted.isEmpty) {
      throw ArgumentError('A described voice needs a description.');
    }
    await directory.create(recursive: true);

    final label = (name ?? '').trim().isEmpty ? wanted : name!.trim();
    final profile = VoiceProfile(
      id: _newId(label),
      name: label,
      instruct: wanted,
      language: language,
    );
    _saved.add(profile);
    await _write();
    return profile;
  }

  /// Copies an existing recording into the library.
  Future<VoiceProfile> addFromFile({
    required String name,
    required String wavPath,
    String? transcript,
    String? language,
  }) async => add(
    name: name,
    wav: await File(wavPath).readAsBytes(),
    transcript: transcript,
    language: language,
  );

  Future<VoiceProfile?> update(
    String id, {
    String? name,
    String? transcript,
  }) async {
    final i = _saved.indexWhere((p) => p.id == id);
    if (i < 0) return null;
    final updated = _saved[i].copyWith(name: name, transcript: transcript);
    _saved[i] = updated;
    await _write();
    return updated;
  }

  /// Deletes a voice and its recording. The built-in voice is not removable.
  Future<bool> remove(String id) async {
    final i = _saved.indexWhere((p) => p.id == id);
    if (i < 0) return false;

    final gone = _saved.removeAt(i);
    if (gone.referenceWavPath case final path?) {
      final file = File(path);
      // Only delete audio this library owns — an imported path may be the
      // user's own file sitting somewhere else.
      if (file.existsSync() && file.parent.path == directory.path) {
        await file.delete();
      }
    }
    await _write();
    return true;
  }

  Future<void> _write() async {
    await directory.create(recursive: true);
    await _index.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final p in _saved) p.toJson()]),
    );
  }

  /// A readable, collision-free id — the name slugged, plus a counter when
  /// that is already taken. Readable matters: these become filenames the user
  /// may well go looking at.
  String _newId(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'voice' : slug;
    if (base != VoiceProfile.builtIn.id && byId(base) == null) return base;

    var n = 2;
    while (byId('$base-$n') != null) {
      n++;
    }
    return '$base-$n';
  }
}
