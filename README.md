# speech-pipeline

A streaming speech-to-speech pipeline in Dart — **VAD → STT → LLM → TTS** — in
the shape of [huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech),
but with Dart isolates and streams where the Python version uses threads and
queues.

No Python, no server-side runtime beyond the Dart VM. The models run natively
through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) over `dart:ffi`.

## Layout

```
speech_pipeline/          pure Dart core — engines, orchestrator, PipelineSetup
agent_cli/                finds and drives installed AI coding CLIs
speech_pipeline_server/   headless CLI driving the core over pipes
tool/fetch_models.sh      downloads models + native sherpa-onnx library
```

The core is deliberately free of Flutter imports, so the Flutter client
(`../voicelab-app/`) depends on it directly rather than reimplementing the
loop. `PipelineSetup` lives there too — model-path resolution is not
CLI-specific, and the app assembling its own pipeline differently from the CLI
is precisely how the two would drift apart.

## Stages

| Stage | Implementation | Model |
|---|---|---|
| VAD | `SherpaVadEngine` | Silero VAD |
| STT | `SherpaSttEngine` / `CloneSttEngine` | SenseVoice, IndicConformer |
| LLM | `OpenAiCompatibleLlm` / `AnthropicLlm` | local or cloud, see below |
| TTS | `SherpaTtsEngine` / `CloneTtsEngine` | Kokoro, Piper, OmniVoice |

Every stage sits behind an interface in `lib/src/engines.dart`. Swapping
SenseVoice for Whisper, or Kokoro for Piper, is a config change; swapping the
local LLM in for the API one is a different `LlmEngine` implementation.

### Choosing a model

`llmProviders` is the catalog — llama.cpp, Ollama, OpenAI, Anthropic,
OpenRouter, DeepSeek, Groq, NVIDIA NIM, and a hand-entered OpenAI-compatible
endpoint. `LlmConfig.problem` says what a chosen provider is still missing, so
a settings screen can render it next to the field rather than catching an
exception; `buildLlm` refuses to construct an engine that isn't ready.

From the environment:

```bash
export SP_LLM_PROVIDER=llamacpp     # or ollama, openai, anthropic, …
export SP_LLM_MODEL=qwen3
export SP_LLM_API_KEY=…             # not needed for local servers
export SP_LLM_MAX_TOKENS=100
```

Setting only `SP_LLM_BASE_URL` still works and is read as a custom
OpenAI-compatible endpoint, which is what it always meant.

#### Finding and running a model

Three ways in, all in the shared package so the CLI and the app behave alike.

**`discoverLocalLlms()`** probes the ports the common servers use — llama.cpp
(8080/8081/8082), Ollama (11434), LM Studio (1234), text-generation-webui
(5000) — with `/v1/models`, and reports which answered *and which model each is
serving*. Getting the port wrong is the single most common reason the assistant
cannot reach a model, and the only symptom is a connection error, so asking the
machine beats asking the user to remember.

**`findLocalModels()`** lists the GGUF files already on disk, under `~/llm`,
`~/models`, the LM Studio and Hugging Face caches, and `~/Downloads`. Weights
are large and slow to fetch; nobody should download a second copy of something
they have. Sharded models are listed once, by their first shard — loading shard
two directly is never what anyone wants. Depth is bounded: a Hugging Face cache
nests several levels deep and a Downloads folder can hold an entire source
tree, so an unbounded walk turns a button press into a disk crawl.

**`ManagedLlmServer`** runs llama.cpp as a child process and waits for
`/health` before reporting success. It is deliberately not bundled: the binary
is whatever the user points at, because shipping one would mean carrying a
large native binary per platform, keeping it current, and it still would not
work on a phone.

```dart
final server = ManagedLlmServer();
final baseUrl = await server.start(
  executable: '/home/you/llama.cpp/build/bin/llama-server',
  modelPath: '/home/you/llm/gemma3-4b-q4.gguf',
  port: 8080,
);
```

Two details that matter more than they look:

- **The process is a child, so it dies with the app.** A forgotten server
  holding several gigabytes of weights is exactly the kind of thing nobody
  notices until the machine is out of memory.
- **A server that cannot load its weights prints why and exits.** Waiting for
  the health timeout would throw that line away, so the exit is watched
  alongside the probe and the failure carries what the process actually said.

`--host 127.0.0.1` is not configurable. A local model is the private option;
binding it to every interface would quietly put it on the network.

**Running a binary from another platform.** `leadingArgs` puts arguments in
front of the server's own, which is what lets a Windows app start a llama.cpp
built inside WSL:

```dart
await server.start(
  executable: r'C:\Windows\System32\wsl.exe',
  leadingArgs: const ['-e', '/home/you/llama.cpp/build/bin/llama-server'],
  modelPath: '/home/you/llm/gemma3-4b-q4.gguf',
  verifyPaths: false, // those paths live inside WSL, not here
);
```

**Reasoning models need care in a voice loop.** Qwen3 and its kin stream a
`reasoning_content` channel before any answer. Reading that aloud would narrate
the model thinking to itself, and on a voice-sized token budget the whole
allowance goes on reasoning — the turn ends `finish_reason: length` with empty
content and the assistant says nothing at all. `OpenAiCompatibleLlm` therefore
asks the server to disable thinking by default and never yields the reasoning
channel; `AnthropicLlm` skips `thinking_delta` for the same reason. Pass
`disableThinking: false` if you are rendering a transcript rather than speaking
one.

**Small models are not multilingual enough for Nepali or Sanskrit.** Measured
on Qwen3-1.7B-Q4 through this pipeline, same model, three languages:

| Prompt | Reply |
|---|---|
| *What is the capital of Nepal?* | "The capital of Nepal is Kathmandu." ✅ |
| *नेपालको राजधानी कुन हो?* | degenerate repetition, no answer |
| *नेपालको सबैभन्दा अग्लो हिमाल कुन हो?* | "दामाड हिमाल" — invented |
| *भारतस्य राजधानी का अस्ति?* | answers in Hindi, evasively |

Gemma 3 4B, on the same hardware and the same questions, gets them right:

| Prompt | Qwen3-1.7B | Gemma 3 4B |
|---|---|---|
| नेपालको राजधानी कुन हो? | repetition loop | काठमाडौं नेपालको राजधानी हो। ✅ |
| सबैभन्दा अग्लो हिमाल? | "दामाड हिमाल" (invented) | Everest ✅ *(see below)* |
| तपाईंलाई कस्तो छ? | तपाईंलाई खुशी छ. (wrong person) | म एकदमै राम्रो छु, धन्यवाद! ✅ |
| भारतस्य राजधानी का अस्ति? | answers in Hindi | नई दिल्ली भारतस्य राजधानी अस्ति। ✅ |

The recognisers and voices handle these languages; the smallest local LLMs do
not. 4B is roughly where Nepali starts working — below that, use a cloud
provider.

### Automatic language detection

`--auto-lang` detects the language per turn instead of fixing it up front.
`--lang` still matters: it is where the conversation starts and where detection
falls back when the evidence is thin.

```
· heard English
you  > What is the capital of Nepal?
The capital of Nepal is Kathmandu.
· heard Nepali (whisper: hi)
you  > नमस्ते नेपालको राजधानी कुन हो
नमस्ते, नेपालको राजधानी काठमाडौं हो।
· speaking Nepali · ne (94%, Devanagari markers 5 ne / 0 sa)
```

It works in two stages, because the two ends of the pipeline have very
different evidence available.

**Input — from the audio.** The recogniser has to be chosen before there is any
transcript, so this uses Whisper's spoken-language identifier. Measured on five
samples through this pipeline:

| sample | actual | Whisper said |
|---|---|---|
| Kokoro | English | `en` OK |
| OmniVoice | Nepali | `ne` OK |
| Piper Chitwan | Nepali | `hi` wrong |
| Sanskrit A | Sanskrit | `si` wrong |
| Sanskrit B | Sanskrit | `pa` wrong |

Two out of five — **not good enough to route on directly.** But every error
stayed inside the Indic family, which makes the Latin-against-Indic split 5 out
of 5. So that is the only split it is trusted with, and it is right in practice
even when the code it returns is wrong: the run above shows Whisper reporting
Hindi for Nepali audio and the turn still reaching the Nepali recogniser.

**Output — from the text.** `detectLanguage` reads the reply. Script settles
English; Nepali and Sanskrit share Devanagari, so those are separated on
function words (`छ`, `हो`, `को`, `ले`) against Sanskrit's (`अस्ति`, `इति`,
`च`, visarga `ः`, word-final `म्`). It returns a confidence, and
`LanguageRoutingTtsEngine` acts only on a confident guess — a two-word reply
carries little evidence, and flickering between voices is worse than staying
put.

This fixes a plainer bug too, one that has nothing to do with switching
languages: **the reply's language is the model's choice, not the
configuration's.** Ask an English-configured assistant something in Nepali and
it may well answer in Nepali, which the English voice then reads as gibberish.

**The honest limitation:** Whisper never once returned `sa`. Sanskrit *speech*
therefore routes to the Nepali recogniser in auto mode — select Sanskrit
explicitly with `--lang sa`. Sanskrit *replies* are detected correctly, because
that decision is made from text. Hindi and Marathi are also Devanagari and not
in this pipeline's language set, so they read as Nepali; detection can only
choose among languages the pipeline can actually speak.

Auto mode loads every language's models at once, and `verify()` checks for all
of them rather than only the starting language.

### Replaying a recording at speaking speed

A file is read as fast as the disk allows, so a whole conversation reaches the
VAD within milliseconds and every turn barges in on the one before it — which
looks exactly like a bug and is not one. `--realtime` paces the input the way a
microphone would:

```bash
dart run speech_pipeline_server/bin/talk.dart --auto-lang --realtime \
  --input conversation.raw --output reply.wav --native-lib native
```

### Mixed scripts, and why the pipeline repairs them

Gemma's Everest answer came back as **`एভারেস্ট`** — the word spelled half in
Devanagari and half in Bengali, inside an otherwise clean Nepali sentence. It
is a tokenizer artifact and it is reproducible. Prompting does not fix it:
demanding Devanagari suppresses the mixing only by making the model evade the
question.

Fed straight to Piper, that word costs **6.1 seconds of audio instead of 2.4** —
the espeak front-end spells the stray letters out one at a time.

`repairDevanagari` fixes it exactly. Unicode lays the Brahmic blocks out in
parallel — Devanagari क is U+0915, Bengali ক is U+0995 — so shifting the
sibling letters down by their block offset yields `एभारेस्ट`, the right word.
`ScriptGuardTtsEngine` applies this on the audio path only, so captions and
history keep the model's literal output, and it reports every repair rather
than silently papering over which models need replacing.

Only Bengali, Gurmukhi, Gujarati and Oriya are transposed: they share
Devanagari's phonemic inventory, so the mapping is faithful. Tamil and its
neighbours do not — Tamil has no aspirate or voiced-stop letters — so those are
left intact and reported instead of being mapped into sounds the model never
wrote. Nothing is ever dropped: a mispronounced word is recoverable, a deleted
clause is not.

### Answering through a CLI you already have

Someone using `claude` or `codex` daily has already signed in. `CliLlmEngine`
drives that CLI as the LLM stage, so the assistant works with no API key pasted
anywhere and no second subscription.

```dart
final agents = await discoverCliAgents();
final llm = CliLlmEngine(agents.first);
```

The `agent_cli` package does the finding and the driving. Its process layer
follows the design proven in chitragupta-app: one `CommandRunner` abstraction
with a native and a WSL implementation, so the same code works on Linux, on
Windows, and on a Windows app reaching into a WSL distribution.

**Measured on this machine, and the reason this is the convenient option rather
than the fast one:**

| backend | first text |
|---|---|
| llama.cpp, Qwen3-1.7B | 95 ms |
| llama.cpp, Gemma 3 4B | 257 ms |
| Claude Code CLI | 5542 ms |
| Codex CLI | 7407 ms |

Every turn is a fresh process that loads the tool list, hooks and project
instructions before it answers — one measured invocation created 8011 cache
tokens before producing five tokens of reply. For a spoken assistant those
seconds are audible silence.

Three details that decide whether this works at all:

- **Lookups go through a login shell.** These CLIs install into
  `~/.local/bin`, which `~/.profile` puts on PATH. A non-login shell never
  sources it, so a bare `which` reports nothing installed. This applies on
  POSIX as much as inside WSL — and `command -v` is a shell builtin with no
  executable to run, so `Process.run('command', …)` fails outright.
- **Tools are turned off and the system prompt is replaced.** These are coding
  agents. Left with their own prompt they will read files and run commands
  instead of answering; a voice assistant that edits a repository because you
  thought aloud is not what anyone asked for.
- **stdin is closed immediately.** A CLI that reads stdin when it is not a
  terminal waits forever for input that is never coming — `codex exec` says so
  out loud and then hangs.

Each call is stateless, with the conversation rendered into the prompt. The
CLIs do have resume modes, but leaning on them would move the conversation's
memory into the CLI's own session store, where the pipeline cannot trim it and
where it would drift from the history the caller believes it has.

### Speaking in a cloned voice

`CloneTtsEngine` answers through `CloneService` — audio.cpp over `dart:ffi` —
so the assistant replies in a voice cloned from a recording. Pair it with
`CloneSttEngine` and both share one engine isolate: the native weights are tens
of megabytes and synthesis blocks its isolate outright, so a second copy would
double both the memory and the warm-up.

```bash
dart run speech_pipeline_server/bin/talk.dart --lang ne --timing \
  --input you.raw --output reply.wav --native-lib native \
  --voice-model ~/audiocpp-models/OmniVoice-GGUF/omnivoice-q8_0.gguf \
  --voice-lib ~/audio.cpp/build-vk/bin \
  --voice-backend vulkan \
  --voice-ref you.wav --voice-ref-text "what the recording says"
```

`--voice-ref-text` is not optional in spirit: OmniVoice conditions on the
reference transcript as well as its audio, and omitting it measurably weakens
the clone.

#### The voice library

Cloning is not limited to one person. `VoiceLibrary` holds any number of named
voices — yours, a friend's, a narrator's — alongside `VoiceProfile.builtIn`,
the model's own speaker, which needs no recording and so is the one voice that
works before anything has been recorded.

```bash
dart run speech_pipeline_server/bin/talk.dart --list-voices
#   default            Default voice  ·  the model's own speaker
#   damodar            Damodar        ·  "नमस्ते, मेरो नाम दामोदर हो"
#   narrator           Narrator       ·  no transcript

dart run speech_pipeline_server/bin/talk.dart --voice damodar …
```

Reference audio is copied into the library rather than referenced where it was
recorded: a recorder writes to a cache directory the OS may empty, so a profile
pointing there would work right up until the day it silently did not. A voice
whose recording has gone missing is dropped at load, so selecting it fails
early rather than inside the engine, mid-reply.

Unlike the sherpa engines this yields one chunk per utterance rather than a
stream. OmniVoice is non-autoregressive — 32 MaskGIT unmasking steps over the
whole sequence at once — so there is no prefix to emit early. Splitting the
reply into sentences, which the orchestrator already does, is what keeps
time-to-first-audio bounded.

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
# A .wav becomes the raw 16 kHz mono the pipeline reads. --pad matters: the
# VAD only closes a turn after hearing enough silence, so a file that ends the
# instant the speaker stops leaves the last utterance open.
dart run speech_pipeline_server/bin/to_raw.dart --in you.wav --out you.raw

dart run speech_pipeline_server/bin/talk.dart \
  --native-lib native --input you.raw --output reply.wav --timing
```

`--timing` reports each turn measured from the moment the user stopped talking,
which is when they actually start waiting:

```
transcript 93ms · first token 338ms · first audio 3118ms · turn 3123ms
```

Time to first audio is the number that decides whether the assistant feels
responsive, and on a CPU build it is dominated by synthesis, not by the model.

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
- Cloned-voice synthesis is only conversational on a GPU backend. A full turn
  measured through this pipeline on CPU: transcript 4197ms, first token 4785ms,
  **first audio 20675ms**, 58.4s for 6.5s of speech — RTF 9.03. The same engine
  over Vulkan synthesises the same Nepali sentence at RTF 0.129. Treat the CPU
  path as a correctness fallback, not a usable one.

## Licence

MIT — see [LICENSE](LICENSE).

The models are not MIT, and one recogniser is not open source at all. Nothing
here bundles weights: they are downloaded from their publishers with the licence
shown first. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) before you
build anything on top of this.
