# speech-pipeline

A streaming speech-to-speech pipeline in Dart — **VAD → STT → LLM → TTS** — in
the shape of [huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech),
but with Dart isolates and streams where the Python version uses threads and
queues.

No Python, no server-side runtime beyond the Dart VM. The models run natively
through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) over `dart:ffi`.

## Layout

```
speech_pipeline/          pure Dart core — engine interfaces + orchestrator
speech_pipeline_server/   headless CLI driving the core over pipes
tool/fetch_models.sh      downloads models + native sherpa-onnx library
```

The core is deliberately free of Flutter imports so the planned Flutter client
can depend on it directly rather than reimplementing the loop.

## Stages

| Stage | Implementation | Model |
|---|---|---|
| VAD | `SherpaVadEngine` | Silero VAD |
| STT | `SherpaSttEngine` | SenseVoice (zh/en/ja/ko/yue) |
| LLM | `OpenAiCompatibleLlm` | any `/chat/completions` endpoint |
| TTS | `SherpaTtsEngine` | Kokoro v0.19, 24 kHz |

Every stage sits behind an interface in `lib/src/engines.dart`. Swapping
SenseVoice for Whisper, or Kokoro for Piper, is a config change; swapping the
local LLM in for the API one is a different `LlmEngine` implementation.

## Languages

English, Nepali and Sanskrit. Support is genuinely uneven, so the pipeline
states what it is doing rather than quietly degrading — `PipelineSetup` refuses
to start when a stage isn't ready, and prints the caveat when one is
approximate. The machine-readable version of this table lives in
`lib/src/languages.dart`.

| | STT | TTS |
|---|---|---|
| **English** | SenseVoice — ready | Kokoro v0.19 — ready |
| **Nepali** | IndicConformer `ne` — **verified** | Piper `ne_NP-chitwan-medium` — ready |
| **Sanskrit** | IndicConformer `sa` — works, accuracy unproven | Kokoro + own phonemizer — ready |

**Nepali TTS is genuinely good** and needs nothing beyond `fetch_models.sh`.
Measured RTF 0.46 — noticeably faster than Kokoro on English.

### Sanskrit TTS: phonemise in Dart, skip espeak

espeak-ng ships `ne`, `hi`, `mr` and `bn` under `lang/inc/` but no `sa`, so
every VITS/Piper route reaches Sanskrit through a *Hindi* front-end — which
deletes the inherent schwa (*Rāma* → *Rām*), flattens anusvara and drops
visarga. Those are the defects, and they live in the phonemiser, not the voice.

So we replaced the phonemiser. `sanskrit_phonemizer.dart` is a port of
[EdgeSanskrit-TTS](https://huggingface.co/Hari7718/EdgeSanskrit-TTS) (MIT): a
table-driven Devanagari→IPA converter that keeps the inherent vowel,
assimilates anusvara to the following consonant's varga, and gives visarga its
echo vowel. Its tests assert byte-identical output to the upstream Python on
every reference phrase.

That IPA then goes **straight into Kokoro**, whose 177-token vocabulary is
already IPA and already contains every retroflex, aspirate and length marker
Sanskrit needs. sherpa-onnx has no way to inject phonemes — its Kokoro path is
text→espeak/lexicon→IPA with no override — so `KokoroIpaTtsEngine` drives the
same `model.onnx` through ONNX Runtime directly (`tokens`, `style`, `speed` →
`audio`), reading style vectors out of `voices.bin`.

Bhagavad Gītā 1.1 round-trips as:

```
धर्मक्षेत्रे कुरुक्षेत्रे समवेता युयुत्सवः। मामकाः पाण्डवाश्चैव किमकुर्वत सञ्जय॥
dʰaɾmakʂetɾe kuɾukʂetɾe samavetaː jujutsavaha. maːmakaːha paːɳɖavaːʃtʃaɪva
kimakuɾvata saɲdʒaja.
```

Visarga (`…vaha`, `maːmakaːha`), retroflexes (`paːɳɖavaː`) and the palatal nasal
(`saɲdʒaja`) all survive.

**It is correct Sanskrit, but it is not chanting.** The voice is an English
Kokoro speaker: no pitch accent, no vṛtta. For recitation the answer is
[Vāgdhenu](https://github.com/prathoshap/vagdhenu) (IISc, Apache-2.0), the only
meter-aware śloka-to-chant model — but it's an F5-TTS DiT plus BigVGAN with no
ONNX export, so it belongs behind an `HttpTtsEngine`, not in-process.

**Unexpected bonus: the direct-ONNX path is ~5× faster than sherpa's** for the
same Kokoro weights — RTF **0.16** vs 0.80. Bypassing the text front-end, not
the model, accounts for it.

### STT: IndicConformer, verified on Nepali

Nepali, through the exported IndicConformer:

```
spoken:  नमस्ते। मेरो नाम राम हो। म काठमाडौंमा बस्छु र नेपाली भाषा बोल्छु।
heard:   नमस्ते  मेरो नाम राम हो  म काठमाडौँमा बस्छु र नेपाली भाषा बोल्छु
```

The only differences are the danda (CTC emits no punctuation) and
काठमाडौंमा/काठमाडौँमा — anusvara against candrabindu, both current orthography.
Decoded in **198 ms**, against Whisper's 2226 ms for a mangled result.

Sanskrit runs but is **not** verified to the same standard. `अहं संस्कृतं वदामि।`
comes back as `संस्कृतं वदामि` — the leading word is dropped, and a Gītā line
degrades further. The test is confounded, though: the only Sanskrit audio on
hand is our own TTS, which is an English Kokoro voice, and that accent is out of
domain for a recogniser trained on native speech. Judge it on real recordings
before concluding anything about the model.

### Why not just use Whisper

Measured, not assumed. Whisper `small` and `large-v3-turbo` both mangle Nepali,
and — tellingly — mangle it *identically*:

```
नेपाल एक सुन्दर देश हो।        → "िाल"          (small AND turbo)
नमस्ते। मेरो नाम राम हो। …      → "ममस्ते िरो ाम्राम हो मो"
```

Scaling the model up changes nothing, so this is Whisper's Nepali coverage, not
a capacity problem. It is also not a bug in this pipeline: transcribing the
whole file with no VAD gives the same result, and the VAD segment measures
4.26 s against 3.99 s of audio, so pre-roll and resampling are both behaving.

So the fix is a language-specific model. AI4Bharat's **IndicConformer** is the
only open model with dedicated Nepali *and* Sanskrit recognisers (MIT, 22
scheduled languages). It ships as NeMo checkpoints, and the community
sherpa-onnx conversions cover 11 languages — neither of ours — so it needs one
conversion:

```bash
pip install "nemo_toolkit[asr]" onnx onnxruntime huggingface_hub
pip install "protobuf>=6.31.1,<7" "ml_dtypes>=0.5.0" "onnx==1.19.0" \
            "numpy<2.5,>=2.0"     # realigns NeMo's pins with a cp314 onnx

export HF_TOKEN=hf_...            # repos are gated (approval is automatic)
python tool/export_indicconformer.py --lang ne
python tool/export_indicconformer.py --lang sa
```

**The AI4Bharat repos are gated.** Approval is instant, but you must accept the
terms while signed in and supply a token; the script says so rather than dying
in a stack trace. The second `pip install` is not optional — NeMo pins protobuf
~=5.29 while the only onnx with CPython 3.14 wheels carries 6.31 gencode, and a
runtime older than its gencode is a hard failure.

This is offline tooling, not a runtime dependency: it runs once per language and
emits files the Dart side loads by itself. Nothing in the pipeline needs Python.
Until it has run, `PipelineSetup` falls back to Whisper automatically so both
languages still work end-to-end; `activeSttModel` reports which is in use.

The export needs six deviations from stock NeMo, all of them recorded in the
script. Two are worth knowing about because they fail *quietly*:

- **`subsampling_factor` must come from the checkpoint, not a guess.** It is 4
  here. sherpa derives the output frame count from it, so a wrong value
  truncates the transcript to a fraction of the audio and never errors. This
  cost the most time to find — the first export looked like a weak model rather
  than a broken config.
- **The per-language repo names are misleading.** Every checkpoint carries the
  same full multilingual model: one encoder over an aggregate vocabulary of
  22 languages x 256 BPE tokens, so the CTC head emits 5632 classes spanning
  every Indic script. Nepali occupies `[3328, 3584)`, Sanskrit `[4096, 4352)`.
  Nothing constrains greedy argmax to that slice, so mixed-script output is
  possible in principle — in practice Nepali came back clean, so the export
  leaves the vocabulary whole rather than masking it.

Check a voice without standing up the pipeline:

```bash
dart run speech_pipeline_server/bin/say.dart --lang ne \
  --native-lib native --text "नमस्ते, म तपाईंलाई कसरी सहयोग गर्न सक्छु?"

dart run speech_pipeline_server/bin/say.dart --lang sa --voice 5 \
  --native-lib native --text "अहं संस्कृतं वदामि।"
```

`--voice` picks from Kokoro's 11 speakers (see `kokoroV019Voices`).

## Testing a real recording

Round-tripping our own TTS flatters the recogniser — the audio is clean, evenly
paced, and for Sanskrit is spoken by an English voice. `transcribe.dart` runs
the real thing:

```bash
dart run speech_pipeline_server/bin/transcribe.dart \
  --lang ne --native-lib native --input recording.wav
```

`--native-lib` is the only thing needed to find the native libraries — no
environment variables. It points at the directory `tool/fetch_models.sh`
populates, and both sherpa-onnx and ONNX Runtime are loaded from there by
absolute path.

Input must be **mono 16-bit PCM .wav**, which is not what phone recorders or
Windows Voice Recorder produce by default; the tool says so and prints
conversion commands rather than failing obscurely. `--whole` skips the VAD and
decodes the file in one pass, which is useful for telling a segmentation
problem apart from a recognition one.

## Setup

```bash
./tool/fetch_models.sh          # ~1.5 GB of models + native libs
SP_LANGS=en ./tool/fetch_models.sh   # …or just the languages you need
dart pub get

export SP_LLM_BASE_URL=https://api.openai.com/v1
export SP_LLM_MODEL=gpt-4o-mini
export SP_LLM_API_KEY=sk-...
```

Point `SP_LLM_BASE_URL` at `http://localhost:11434/v1` for Ollama or
`http://localhost:8080/v1` for llama.cpp's server to run fully offline.

## Run

Live conversation, mic in and speaker out, using ALSA for the device ends:

```bash
arecord -f S16_LE -r 16000 -c 1 -t raw \
  | dart run speech_pipeline_server/bin/talk.dart --native-lib native \
  | aplay -f S16_LE -r 24000 -c 1 -t raw
```

Or drive it from a recording and write the reply to a file:

```bash
dart run speech_pipeline_server/bin/talk.dart \
  --native-lib native --input sample.raw --output reply.wav
```

Transcripts and live token deltas go to stderr, so they stay readable while
stdout carries the audio.

## Verify the install

`selftest` round-trips the native stages without touching the LLM — it
synthesises a sentence, feeds the audio back through VAD and STT, and prints
what came out. This is the check that FFI, both worker isolates, and the
streaming callbacks work on your machine.

```bash
LD_LIBRARY_PATH=native dart run speech_pipeline_server/bin/selftest.dart \
  --native-lib native
```

Measured on a 32-core WSL2 box, CPU only:

| | |
|---|---|
| Kokoro TTS load | ~3.4 s |
| SenseVoice STT load | ~2.3 s |
| TTS real-time factor | 0.81 @ 2 threads, 0.69 @ 8 |
| TTS via direct ONNX (Sanskrit path) | **0.16** |
| Nepali Piper TTS | 0.46 |
| STT for a 2.8 s utterance | ~120 ms |

Two things to read off that table. **STT is not the bottleneck** — it is roughly
20× faster than real time. **TTS very nearly is**: at RTF 0.7–0.8 Kokoro
generates barely faster than the audio plays, and thread count barely helps.

Note also that sherpa fires the TTS progress callback **once per sentence**, not
continuously — a single sentence yields a single chunk, so its time-to-first-
audio equals its full synthesis time. The orchestrator's early clause-splitting,
not the streaming callback, is what actually gets first audio out quickly. If
you need lower latency than this, that is the argument for moving TTS to an API.

## Design notes

**Isolates, not threads.** STT and TTS each own a long-lived isolate that holds
its native recogniser for the process lifetime — model load is far too
expensive to repeat per utterance, and decoding is a blocking FFI call that
must not share an isolate with the audio loop. The VAD is the exception: Silero
is small enough that keeping it inline is what makes barge-in feel immediate.

**Cancellation crosses isolates through shared memory, not messages.** During
synthesis the TTS worker is blocked inside a native call and cannot pump its
event loop, so a `cancel` message would not be read until the utterance it was
meant to interrupt had already finished. Instead the main isolate flips a
`Pointer<Int32>` that the sherpa progress callback checks on each chunk.

**Backpressure is free.** Because stage boundaries are streams rather than
queues, a slow playback device propagates back through TTS to token generation
without any explicit flow control.

**First sentence is cut early.** Time-to-first-audio dominates perceived
latency, so the sentence splitter will break the opening sentence at a clause
boundary and tighten up for the rest of the reply.

## Limitations

- The native libraries shipped via pub are **CPU builds**. GPU means building
  sherpa-onnx yourself with the CUDA provider and pointing `--native-lib` at it.
- `sherpa_onnx` declares a Flutter SDK dependency for plugin registration even
  though `lib/` is pure Dart and FFI. Resolving this workspace therefore needs
  the Flutter SDK on `PATH`, but running it does not.
- No acoustic echo cancellation in the CLI path — use headphones, or the
  assistant will hear itself and barge in on its own reply.
