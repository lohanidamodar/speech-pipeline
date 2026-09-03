import 'dart:async';
import 'dart:io';

import 'package:voice_models/voice_models.dart';

export 'package:voice_models/voice_models.dart'
    show
        DownloadProgress,
        ModelDeclined,
        ModelFeature,
        ModelLicence,
        ModelStore,
        ModelTask,
        VoiceModel,
        VoiceStylePolicy,
        applyVoiceStyle,
        modelById,
        modelsFor;

/// Everything needed to start a voice, resolved from the shared store.
class VoiceSetup {
  const VoiceSetup({
    required this.model,
    required this.modelPath,
    required this.family,
  });

  final VoiceModel model;

  /// The GGUF on disk.
  final String modelPath;

  /// The loader's name for this architecture — `omnivoice`, `voxcpm2`.
  final String family;

  /// Whether the user can describe the voice in words for this model.
  bool get canDesignVoice => model.canDesignVoice;

  bool get canCloneVoice => model.canCloneVoice;

  /// How this model wants that description delivered.
  VoiceStylePolicy get stylePolicy => model.stylePolicy;
}

/// The voices this app can speak with, and how to get them.
///
/// A thin layer over [ModelStore]: it knows that a synthesis model needs a
/// path and a family name, which is the one thing the store deliberately does
/// not — the store's job is bytes and licences, not engines.
class VoiceCatalogue {
  VoiceCatalogue({ModelStore? store}) : store = store ?? ModelStore();

  final ModelStore store;

  /// Every voice, whether or not it is downloaded.
  List<VoiceModel> get voices => modelsFor(ModelTask.synthesis);

  /// The ones already on disk, ready to use without a download.
  List<VoiceModel> get installed =>
      voices.where(store.has).toList(growable: false);

  bool has(VoiceModel model) => store.has(model);

  /// The voice to offer when the user has not chosen.
  ///
  /// Prefers one already downloaded — a first run should not be a wait for a
  /// gigabyte. Failing that, the widest-language model, because a voice that
  /// cannot say the user's language is not a default.
  VoiceModel get defaultVoice {
    final ready = installed;
    if (ready.isNotEmpty) return ready.first;
    return modelById('omnivoice-q8') ?? voices.first;
  }

  /// Downloads [model] if needed and returns what is required to start it.
  ///
  /// [onLicence] is asked before any bytes move; answering no throws
  /// [ModelDeclined]. Weights carry terms, and agreeing to them is the user's
  /// to do.
  Future<VoiceSetup> prepare(
    VoiceModel model, {
    void Function(DownloadProgress)? onProgress,
    FutureOr<bool> Function(VoiceModel)? onLicence,
  }) async {
    if (model.task != ModelTask.synthesis) {
      throw ArgumentError('${model.id} is not a voice.');
    }
    if (model.engineFamily == null) {
      throw ArgumentError('${model.id} does not name an engine family, so '
          'there is no way to know how to load it.');
    }

    final dir = await store.ensure(
      model,
      onProgress: onProgress,
      onLicence: onLicence,
    );
    return VoiceSetup(
      model: model,
      modelPath: '${dir.path}${Platform.pathSeparator}${model.files.single.name}',
      family: model.engineFamily!,
    );
  }

  /// What to warn about before speaking [language] with [model].
  ///
  /// Null when there is nothing to say. A model asked for a language it was
  /// not trained on does not fail — it produces confident, wrong
  /// pronunciation, which is worse, so this exists to be shown.
  String? languageWarning(VoiceModel model, String? language) {
    if (language == null || language.isEmpty) return null;
    if (model.speaks(language)) return null;
    return '${model.name} was not trained on "$language". It will still say '
        'something, in the accent of a language it does know. Pick a voice '
        'that lists it if the pronunciation matters.';
  }

  void dispose() => store.dispose();
}
