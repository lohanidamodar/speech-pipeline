import 'dart:typed_data';

import 'audio.dart';
import 'clone_service.dart';
import 'engines.dart';
import 'voice_catalogue.dart';

/// A voice the assistant can answer in.
///
/// Either the model's own speaker ([VoiceProfile.builtIn]) or a clone
/// conditioned on a reference recording. [transcript] is not decoration:
/// OmniVoice conditions on the reference text as well as its audio, and
/// omitting it measurably degrades the clone — so a profile without one is
/// worth flagging to the user, not silently accepting.
class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.name,
    this.referenceWavPath,
    this.transcript,
    this.language,
    this.instruct,
  });

  /// The model's default speaker. Needs no recording, so it is the one voice
  /// that always works — including the first time the app is opened.
  static const builtIn = VoiceProfile(id: 'default', name: 'Default voice');

  final String id;
  final String name;

  /// Null for [builtIn]: nothing to clone from.
  final String? referenceWavPath;

  final String? transcript;

  /// Language of the reference recording, when it differs from the
  /// conversation language.
  final String? language;

  /// The voice in words — "an older man, unhurried, warm" — or, alongside a
  /// reference recording, how to bend it: "sound tired", "read this quickly".
  ///
  /// Only some models can act on this; ask the catalog entry's
  /// `canDesignVoice` before offering it, or it is silently ignored.
  final String? instruct;

  bool get hasTranscript => (transcript ?? '').trim().isNotEmpty;

  /// False for the built-in speaker.
  bool get isCloned => referenceWavPath != null;

  /// A voice that exists only as a description.
  bool get isDesigned =>
      referenceWavPath == null && (instruct ?? '').trim().isNotEmpty;

  VoiceProfile copyWith({
    String? name,
    String? transcript,
    String? language,
    String? instruct,
  }) =>
      VoiceProfile(
        id: id,
        name: name ?? this.name,
        referenceWavPath: referenceWavPath,
        transcript: transcript ?? this.transcript,
        language: language ?? this.language,
        instruct: instruct ?? this.instruct,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (referenceWavPath != null) 'referenceWavPath': referenceWavPath,
    if (transcript != null) 'transcript': transcript,
    if (language != null) 'language': language,
    if (instruct != null) 'instruct': instruct,
  };

  static VoiceProfile fromJson(Map<String, dynamic> json) => VoiceProfile(
    id: json['id']! as String,
    name: json['name']! as String,
    referenceWavPath: json['referenceWavPath'] as String?,
    transcript: json['transcript'] as String?,
    language: json['language'] as String?,
    instruct: json['instruct'] as String?,
  );
}

/// Speaks through [CloneService], in the user's own voice when a profile is set.
///
/// Unlike the sherpa engines this yields exactly one chunk per utterance.
/// OmniVoice is non-autoregressive — 32 MaskGIT unmasking steps over the whole
/// sequence at once — so there is no prefix to emit early. The pipeline already
/// splits replies into sentences, which is what keeps time-to-first-audio
/// bounded; that split does the work streaming would have done here.
class CloneTtsEngine implements TtsEngine {
  CloneTtsEngine(
    this._service, {
    this.profile,
    this.language,
    this.stylePolicy = VoiceStylePolicy.instruction,
    int? sampleRate,
    this.ownsService = false,
  }) : _declaredRate = sampleRate ?? _service.sampleRate {
    if (_declaredRate <= 0) {
      throw ArgumentError(
        'Output rate unknown: start CloneService with warmUp: true, or pass '
        'sampleRate explicitly. Playback cannot be configured without it.',
      );
    }
  }

  final CloneService _service;
  final int _declaredRate;

  /// Whether disposing this engine should also shut the service down. False
  /// when the service is shared with the recogniser, which is the normal case.
  final bool ownsService;

  /// The voice to speak in. Null uses the model's default speaker.
  VoiceProfile? profile;

  /// Conversation language passed to the model, independent of the profile's.
  String? language;

  /// How to say it, in words, overriding the profile's own description for
  /// this engine. Set for a one-off — a narrator that should sound urgent —
  /// without editing the saved voice.
  String? instruct;

  /// How the loaded model wants a description delivered. Comes from the
  /// catalogue entry; the default suits OmniVoice, which is the default voice.
  VoiceStylePolicy stylePolicy;

  @override
  int get sampleRate => _declaredRate;

  /// The pipeline speaks ISO 639-1; OmniVoice's language table is 639-3 for
  /// anything with a three-letter code. Nepali is the case that bites —
  /// `ne` is rejected outright and the id is `npi`. Sanskrit happens to be
  /// `sa` in both, which is why the mismatch stayed hidden.
  static const _engineLanguage = <String, String>{'ne': 'npi'};

  /// Unknown codes pass straight through: the engine keeps its own list and
  /// rejects a bad one with a better message than a guess here would.
  static String? engineLanguageFor(String? code) =>
      code == null ? null : (_engineLanguage[code] ?? code);

  @override
  Stream<AudioChunk> synthesize(String text) async* {
    if (text.trim().isEmpty) return;

    // A profile that is not a clone falls through to the model's own speaker,
    // which is exactly what passing no reference does.
    final voice = profile;
    // One model takes the description as an instruction, another reads it off
    // the front of the text. Resolved here so nothing above has to know.
    final say = applyVoiceStyle(text, instruct ?? voice?.instruct, stylePolicy);
    final result = await _service.speak(
      say.text,
      language: engineLanguageFor(language),
      instruct: say.instruct,
      refWavPath: voice?.referenceWavPath,
      refText: voice?.referenceWavPath == null ? null : voice?.transcript,
    );

    // A model that changes rate mid-conversation would desynchronise playback
    // that was already configured from [sampleRate]. Resample instead of
    // letting the contract quietly become false.
    yield result.sampleRate == _declaredRate
        ? result.samples
        : resample(result.samples, result.sampleRate, _declaredRate);
  }

  @override
  Future<void> dispose() async {
    if (ownsService) await _service.dispose();
  }
}

/// Recognises through the same [CloneService] the cloning voice runs on.
///
/// Sharing one service matters: the native engines are tens of megabytes and
/// synthesis blocks its isolate outright, so a second copy would double both
/// the memory and the warm-up.
class CloneSttEngine implements SttEngine {
  CloneSttEngine(
    this._service, {
    this.language = 'ne',
    this.inputSampleRate = kSampleRate,
    this.ownsService = false,
  });

  final CloneService _service;
  final String language;
  final int inputSampleRate;
  final bool ownsService;

  @override
  Future<String> transcribe(AudioChunk samples) async {
    if (samples.isEmpty) return '';
    return _service.transcribe(
      Float32List.fromList(samples),
      inputSampleRate,
      language: language,
    );
  }

  @override
  Future<void> dispose() async {
    if (ownsService) await _service.dispose();
  }
}
