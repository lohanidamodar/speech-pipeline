# dictation

Hold a hotkey, speak, and the words are typed into whatever has focus.
Windows, pure Dart — no Flutter, no plugins.

```
C:\dev\dictate.exe --models models --native-lib C:\dev\voicelab-runtime
```

Hold **Ctrl+Alt+D**, speak, let go. Right-click the tray icon for settings.

## How it works

| piece | Win32 |
|---|---|
| record | `waveIn`, 16 kHz mono — exactly what the recogniser wants, no resample |
| recognise | sherpa-onnx (Parakeet TDT or SenseVoice) on a worker isolate |
| type | `SendInput` with `KEYEVENTF_UNICODE` — layout-independent, handles Devanagari |
| hotkey, tray, overlay | one dedicated UI thread (see below) |

Raw recognition, deliberately. The point is that words appear while the thought
is still in the air; a language-model cleanup pass punctuates better and costs
a second or two, which is the wrong trade here. `transcribe.dart --polish` is
for when it is the right one.

Corrections (`Vocabulary`) and spoken punctuation are cheap string work and do
run.

## The things that were not obvious

Each of these was found by something not working, and each is load-bearing.

**A Dart isolate does not own an OS thread.** `RegisterHotKey(null, …)` binds
to the calling thread and window messages go to the thread that created the
window, but the VM schedules an isolate onto a thread from a pool and moves it
between event-loop turns. Measured here: the hotkey registered on thread 17680
and the message pump was later running on 38460, draining a queue the messages
never arrived in. Everything stayed alive and correct; the hotkey simply went
dead and Windows pruned the tray icon whose owner had stopped answering. The
fix is `ui_host.dart`: an isolate that enters a blocking `GetMessage` loop and
never returns to the event loop, so it cannot be rescheduled. Commands reach it
by `PostMessage`, which is thread-safe by design — hence two integers rather
than objects, and why the UI derives its own captions from a state code.

**Batched `SendInput` silently truncates.** Sending a whole string as one array
reports every event delivered and then produces only the first word: "Hello
world 123" arrives as "Hello". One character per call with a 2 ms gap arrives
intact. The success return cannot be trusted on a batch.

**The hotkey's own modifiers sabotage the typing.** Ctrl or Alt still held when
injection starts combine with the characters and fire menu shortcuts in the
target application, so there is a settle delay before the first character.

**Buffers handed back to the audio driver must not be freed.** Re-queuing with
`waveInAddBuffer` gives the memory back to the driver; freeing it then corrupts
the heap, and the access violation surfaces later on an unrelated allocation.
`stop()` resets first, collects without re-queuing, and leaks a buffer rather
than freeing one whose `waveInUnprepareHeader` failed.

**Windows' own `onnxruntime.dll` wins the search order.** System32 ships ORT
1.17, which sherpa cannot use; the process prints its version and dies. Ours is
loaded by absolute path first — see `initSherpaBindings` in speech_pipeline.

## Settings

`%APPDATA%\Dictation\config.json`, created on first run and self-documenting.
Hotkey, language, models directory, vocabulary path, spoken punctuation and the
overlay live there. "Reload settings" in the tray applies everything except the
hotkey, which belongs to the UI thread and needs a restart — the console says
so rather than ignoring it.

Only one copy runs: a named mutex means a second exits with a message instead
of quietly failing to register the hotkey and looking broken.
