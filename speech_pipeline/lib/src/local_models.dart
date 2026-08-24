import 'dart:io';

/// A GGUF weight file already on disk.
///
/// Models are large and slow to fetch, so the app finds what is already there
/// rather than asking the user to download another copy of something they have.
class LocalModel {
  const LocalModel({required this.path, required this.sizeBytes});

  final String path;
  final int sizeBytes;

  String get fileName => path.split(Platform.pathSeparator).last;

  /// The file name without its extension — what a person calls the model.
  String get name {
    final n = fileName;
    return n.toLowerCase().endsWith('.gguf') ? n.substring(0, n.length - 5) : n;
  }

  /// The quantisation tag, if the name carries one (`Q4_K_M`, `Q8_0`, `F16`).
  ///
  /// Worth surfacing: it is the difference between a model that fits in memory
  /// and one that does not.
  String? get quantisation {
    // Case-insensitive: the same quantisation is written `Q4_K_M` by one
    // publisher and `q4_k_m` by the next.
    final match = RegExp(
      r'(?:^|[-_.])((?:IQ|Q)\d+(?:_[A-Z0-9]+)*|BF16|F16|F32)(?:$|[-_.])',
      caseSensitive: false,
    ).firstMatch(name);
    return match?.group(1)?.toUpperCase();
  }

  double get gigabytes => sizeBytes / (1024 * 1024 * 1024);

  String get sizeLabel => gigabytes >= 1
      ? '${gigabytes.toStringAsFixed(2)} GB'
      : '${(sizeBytes / (1024 * 1024)).round()} MB';

  @override
  String toString() => '$name · $sizeLabel${quantisation ?? ''}';
}

/// Directories worth looking in for GGUF files.
///
/// The places the common tools put them, plus the user's own. Nothing outside
/// the home directory is searched: a full-disk scan is slow and is not what
/// someone means by "find my models".
List<Directory> defaultModelDirectories({String? home}) {
  final root =
      home ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (root == null) return const [];

  return [
    for (final relative in const [
      'llm',
      'models',
      'gguf',
      '.cache/lm-studio/models',
      '.ollama/models',
      '.cache/huggingface/hub',
      'Downloads',
      'Documents/models',
    ])
      Directory(
        '$root${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      ),
  ];
}

/// Finds GGUF files under [directories].
///
/// [maxDepth] is bounded because a Hugging Face cache nests several levels
/// deep while a Downloads folder can contain an entire source tree; walking
/// either without a limit turns a UI action into a disk crawl.
Future<List<LocalModel>> findLocalModels({
  List<Directory>? directories,
  int maxDepth = 4,
}) async {
  final roots = directories ?? defaultModelDirectories();
  final found = <String, LocalModel>{};

  for (final root in roots) {
    if (!root.existsSync()) continue;
    await _walk(root, maxDepth, found);
  }

  final models = found.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return models;
}

Future<void> _walk(
  Directory dir,
  int depth,
  Map<String, LocalModel> found,
) async {
  if (depth < 0) return;
  try {
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is File) {
        if (!entry.path.toLowerCase().endsWith('.gguf')) continue;
        // Multi-part weights: only the first shard is the one to load, and
        // listing all of them would read as several different models.
        if (RegExp(
          r'-0000[2-9]-of-\d+\.gguf$',
          caseSensitive: false,
        ).hasMatch(entry.path)) {
          continue;
        }
        final resolved = await entry.resolveSymbolicLinks();
        found.putIfAbsent(
          resolved,
          () => LocalModel(path: entry.path, sizeBytes: entry.lengthSync()),
        );
      } else if (entry is Directory) {
        await _walk(entry, depth - 1, found);
      }
    }
  } on FileSystemException {
    // Unreadable directory — skip it rather than abandoning the whole search.
  }
}
