import 'dart:io';
import 'dart:typed_data';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late VoiceLibrary library;

  Uint8List wav([double hz = 440]) =>
      encodeWav(Float32List.fromList(List.filled(1600, 0.1)), 16000);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('voices');
    library = VoiceLibrary(dir);
    await library.load();
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('offers the built-in voice before anything is recorded', () {
    expect(library.profiles, [VoiceProfile.builtIn]);
    expect(library.clones, isEmpty);
    expect(VoiceProfile.builtIn.isCloned, isFalse);
  });

  test('the built-in voice is never removable', () async {
    expect(await library.remove(VoiceProfile.builtIn.id), isFalse);
    expect(library.profiles.first, VoiceProfile.builtIn);
  });

  test('holds several voices at once, not just one', () async {
    await library.add(name: 'Damodar', wav: wav(), transcript: 'नमस्ते');
    await library.add(name: 'Narrator', wav: wav());

    expect(library.clones.map((p) => p.name), ['Damodar', 'Narrator']);
    expect(library.profiles.length, 3, reason: 'built-in plus two clones');
  });

  test(
    'copies the audio in, so a cleared cache cannot break a voice',
    () async {
      final source = File('${dir.path}/elsewhere.wav')..writeAsBytesSync(wav());
      final profile = await library.addFromFile(
        name: 'Imported',
        wavPath: source.path,
      );

      await source.delete();
      expect(File(profile.referenceWavPath!).existsSync(), isTrue);
    },
  );

  test('gives readable ids and never collides', () async {
    final a = await library.add(name: 'My Voice', wav: wav());
    final b = await library.add(name: 'My Voice!', wav: wav());

    expect(a.id, 'my-voice');
    expect(b.id, 'my-voice-2');
  });

  test('never takes the built-in id, whatever the voice is called', () async {
    final p = await library.add(name: 'Default', wav: wav());
    expect(p.id, isNot(VoiceProfile.builtIn.id));
    expect(library.byId(VoiceProfile.builtIn.id), VoiceProfile.builtIn);
  });

  test('survives a reload', () async {
    await library.add(name: 'Damodar', wav: wav(), transcript: 'नमस्ते');

    final reopened = VoiceLibrary(dir);
    await reopened.load();

    expect(reopened.clones.single.name, 'Damodar');
    expect(reopened.clones.single.transcript, 'नमस्ते');
    expect(reopened.clones.single.hasTranscript, isTrue);
  });

  test('drops a voice whose recording has vanished', () async {
    final profile = await library.add(name: 'Ghost', wav: wav());
    await File(profile.referenceWavPath!).delete();

    final reopened = VoiceLibrary(dir);
    await reopened.load();

    // Failing here rather than inside the engine, mid-reply.
    expect(reopened.clones, isEmpty);
    expect(reopened.profiles, [VoiceProfile.builtIn]);
  });

  test('removing a voice deletes its recording', () async {
    final profile = await library.add(name: 'Temp', wav: wav());
    final path = profile.referenceWavPath!;

    expect(await library.remove(profile.id), isTrue);
    expect(File(path).existsSync(), isFalse);
    expect(library.clones, isEmpty);
  });

  test('renaming keeps the recording and the id', () async {
    final profile = await library.add(name: 'Old', wav: wav());
    final updated = await library.update(profile.id, name: 'New');

    expect(updated!.name, 'New');
    expect(updated.id, profile.id);
    expect(updated.referenceWavPath, profile.referenceWavPath);
  });

  test('a transcript can be added after the fact', () async {
    final profile = await library.add(name: 'Quiet', wav: wav());
    expect(profile.hasTranscript, isFalse);

    final updated = await library.update(profile.id, transcript: 'नमस्ते');
    expect(updated!.hasTranscript, isTrue);
  });

  test('an empty library loads cleanly rather than throwing', () async {
    final empty = VoiceLibrary(Directory('${dir.path}/never-created'));
    await empty.load();
    expect(empty.profiles, [VoiceProfile.builtIn]);
  });
}
