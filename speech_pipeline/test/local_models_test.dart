import 'dart:io';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  File gguf(String relative, {int bytes = 1024}) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(bytes, 0));
    return file;
  }

  setUp(() => root = Directory.systemTemp.createTempSync('models'));
  tearDown(() => root.deleteSync(recursive: true));

  group('findLocalModels', () {
    test('finds weights the user already has', () async {
      gguf('gemma-3-4b-it-Q4_K_M.gguf');
      gguf('qwen3-1.7b-q4.gguf');

      final found = await findLocalModels(directories: [root]);
      expect(found.map((m) => m.name), [
        'gemma-3-4b-it-Q4_K_M',
        'qwen3-1.7b-q4',
      ]);
    });

    test('ignores everything that is not a GGUF', () async {
      gguf('real.gguf');
      File('${root.path}/notes.txt').writeAsStringSync('hi');
      File('${root.path}/model.safetensors').writeAsStringSync('x');

      final found = await findLocalModels(directories: [root]);
      expect(found.single.fileName, 'real.gguf');
    });

    test('lists a sharded model once, by its first shard', () async {
      // Loading the second shard directly is never what anyone wants, and
      // listing all of them reads as several different models.
      gguf('big-00001-of-00003.gguf');
      gguf('big-00002-of-00003.gguf');
      gguf('big-00003-of-00003.gguf');

      final found = await findLocalModels(directories: [root]);
      expect(found.single.fileName, 'big-00001-of-00003.gguf');
    });

    test('descends into nested caches', () async {
      gguf('hub/models--org--name/snapshots/abc/weights.gguf');
      final found = await findLocalModels(directories: [root]);
      expect(found.single.fileName, 'weights.gguf');
    });

    test('stops descending rather than crawling the disk', () async {
      gguf('a/b/c/d/e/f/deep.gguf');
      expect(await findLocalModels(directories: [root], maxDepth: 2), isEmpty);
    });

    test('skips a directory that does not exist', () async {
      final found = await findLocalModels(
        directories: [Directory('${root.path}/nope'), root],
      );
      expect(found, isEmpty);
    });

    test('reports size in units a person reads', () async {
      gguf('small.gguf', bytes: 5 * 1024 * 1024);
      final model = (await findLocalModels(directories: [root])).single;
      expect(model.sizeLabel, '5 MB');
      expect(model.gigabytes, lessThan(1));
    });
  });

  group('quantisation', () {
    test('reads the tag from the file name', () {
      String? q(String name) =>
          LocalModel(path: '/x/$name', sizeBytes: 1).quantisation;

      expect(q('gemma-3-4b-it-Q4_K_M.gguf'), 'Q4_K_M');
      expect(q('qwen3-1.7b-q8_0.gguf'), 'Q8_0');
      expect(q('model-IQ3_XXS.gguf'), 'IQ3_XXS');
      expect(q('llama-f16.gguf'), 'F16');
    });

    test('says nothing when the name carries no tag', () {
      expect(
        LocalModel(path: '/x/mystery.gguf', sizeBytes: 1).quantisation,
        isNull,
      );
    });
  });
}
