# Longform

A voice chat app for Claude where **your turn ends only when you say a trigger phrase** — never on a pause.

Normal voice assistants cut you off the moment you stop talking. Longform doesn't. Silence means nothing to it;
you can stop and think for as long as you like. The turn ends when you say *"send it"* (or whatever phrase you set).

Personal proof of concept: one screen, no accounts, no persistence, no streaming, no interruption handling.

---

## How it works

```
mic ─► AVAudioEngine tap ─► AVAudioConverter ─► SpeechAnalyzer ─► live transcript
                                                                        │
                                            TriggerDetector: does it END with the phrase?
                                                                        │ yes
                                              strip phrase, stop mic ───┤
                                                                        ▼
                               AVSpeechSynthesizer ◄── Claude Messages API (full history)
                                        │
                                        └─ finished speaking ─► resume listening
```

The mic is off for the entire reply, so Claude's own speech can never trigger a turn.

## Requirements

- Xcode 26, iOS 26+ / macOS 26+
- An Anthropic API key — [console.anthropic.com](https://console.anthropic.com) → Settings → API keys.
  API credits are billed separately from a Claude.ai subscription.

## Setup

1. Create `Longform/Secrets.swift` (gitignored):
   ```swift
   enum Secrets {
       static let anthropicKey = "sk-ant-api03-..."
   }
   ```
2. Pick a destination and run.

> **The iOS Simulator cannot do speech.** It ships no transcription models — `SpeechTranscriber.supportedLocales`
> is empty and `isAvailable` is `false` there ([known limitation](https://developer.apple.com/forums/thread/802969),
> no workaround). Start Listening is disabled in the Simulator; you can still type into the transcript box and
> end with the trigger phrase to exercise everything else.

| Destination | Mic | Use for |
|---|---|---|
| Physical iPhone | yes | the real thing |
| My Mac | yes | testing the speech pipeline without a device |
| Simulator | **no** | UI, trigger, API, text-to-speech via typing |

---

## Technical notes

### Files

| File | Role |
|---|---|
| `LongformApp.swift` | App entry point |
| `ContentView.swift` | The single screen |
| `ChatModel.swift` | State machine and turn orchestration; owns `Message`, `Role`, `Status` |
| `Transcriber.swift` | Mic → `SpeechAnalyzer` long-form transcription |
| `TriggerDetector.swift` | Pure functions: normalize, end-match, strip |
| `ClaudeClient.swift` | Messages API over `URLSession` |
| `Speaker.swift` | `AVSpeechSynthesizer` wrapped as `async` |
| `Log.swift` | `OSLog` categories: `speech`, `trigger`, `api` |

### Turn lifecycle

`Status` drives everything: `idle → listening → thinking → speaking → listening`.

`ChatModel.transcriptChanged` is the single entry point for transcript updates, from the mic **or** from typing.
It sets `status = .thinking` **synchronously** on a match — volatile results arrive fast enough that an
`await`-gated guard would let a second update match the same text and send twice.

### Why silence never ends a turn

`SpeechAnalyzer` is fed from an `AsyncStream` that nothing closes but an explicit `stop()`. There is no
silence timeout anywhere in the chain, so a multi-minute pause mid-sentence is indistinguishable from any
other quiet moment.

### Trigger matching

Normalize (lowercase, strip punctuation, collapse whitespace), then require the text to **end** with the
normalized trigger:

```swift
normalized == trigger || normalized.hasSuffix(" " + trigger)
```

The leading space enforces a word boundary, so `"pretend it"` doesn't match the trigger `"end it"`.
Stripping drops whole words off the **original** text, so capitalization and punctuation survive into the
message sent to Claude.

| Spoken | Trigger | Result |
|---|---|---|
| `What do you think? Send it.` | `send it` | sends `What do you think?` |
| `I told him to send it yesterday` | `send it` | no match — mid-sentence |
| `Send it and then we talk` | `send it` | no match — not at the end |
| `pretend it` | `end it` | no match — word boundary |

Matching runs on volatile (in-progress) results, so it fires the instant the words are recognized rather
than waiting for finalization. That's what makes it feel immediate, and it's where false positives would
appear — hence the `trigger` log category.

### Audio format conversion

The mic runs at its hardware rate (typically 48kHz float32); `SpeechAnalyzer` wants its own format
(16kHz). `Transcriber.convert` bridges them with `AVAudioConverter` on the audio thread.

iOS 27 adds `AnalyzerInputConverter`, which does this in three lines — but it doesn't exist on macOS 26,
so the manual path is used to keep one code path for both platforms.

### Locale reservation

`AssetInventory.reserve(locale:)` is called before analysis. Without it the framework logs
*"Cannot use modules with unallocated locales… This will be an error in a future release"*. The
reservation is released in `stop()`.

### Getting a decent voice

`Speaker.bestVoice()` picks the highest-quality installed voice — premium > enhanced > compact — filtering out
the novelty and Eloquence voices. **But quality is only as good as what's installed**, and macOS/iOS ship only
`compact` voices by default, which sound like hold music. Download a better one once and the app picks it up
automatically (the chosen voice is logged at startup under the `speech` category):

- **macOS** — System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice ▸ Manage Voices… ▸ English,
  then download a **Premium** voice (Ava, Zoe, Evan and Noelle are the natural-sounding ones).
- **iOS** — Settings ▸ Accessibility ▸ Spoken Content ▸ Voices ▸ English, pick a voice and tap the
  download arrow. Prefer the ones marked Premium.

Stock iOS ships only `super-compact` Samantha plus the novelty voices, so **this applies to a real iPhone too**.
The app detects a compact-only install and shows a dismissible one-time hint pointing at the download, rather
than silently sounding robotic.

Siri's voices are not available to `AVSpeechSynthesizer`; Premium is the ceiling for on-device TTS. A genuinely
conversational voice means a cloud TTS (ElevenLabs, Cartesia, OpenAI) — natural and zero user setup, at the cost
of per-reply latency, network dependency and usage billing.

### Ambient noise and the confidence filter

Silence-endpointing normally doubles as a noise filter: stop talking, turn ends, nothing more is captured.
This app removes that on purpose, so during a long pause the mic keeps transcribing **everything in the room**
into your message.

`Transcriber.minimumConfidence` (default `0.3`) drops final results scoring below it. Measured on real audio:

| Source | Confidence |
|---|---|
| Clear speech at the mic | 0.98 – 0.99 |
| **Hesitant real speech** ("Um, we should… Uh, I don't know.") | **0.55** |
| Background audio across the room | 0.45 – 0.84 |

The middle row is why the threshold is so low. At `0.65` an on-device test silently deleted that line — and
thinking out loud is precisely what this app exists to capture. The ranges overlap badly: filtering hard
enough to catch a TV also eats your own hesitation, and losing your words is invisible to you.

**It will not filter a clear nearby voice**, and it isn't meant to. Confidence measures acoustic clarity,
not whether the speaker is you. A pause button or `SpeechDetector` gating is the real fix. Everything dropped
is logged with its score under the `speech` category.

### Conversational tuning

The system prompt in `ClaudeClient.swift` is the whole mechanism — short turns, no validation, no AI-isms,
plain words, and a few example lines showing the register. `evals/run_eval.py` grades it against realistic
spoken turns in `evals/turns.json`, reading the prompt straight out of the source so it always checks what
ships. The check is deterministic — reply length, sentence length, a banned-phrase scan — rather than a judge
model, so it's fast and nearly free:

```sh
cd evals && python3 run_eval.py          # add --verbose to read the replies
```

Short turns land at 40-140 characters with no flattery or filler. Two things remain stubborn: sentences run
to 22-24 words against a 20-word target, and an explicit request for depth produces ~1900 characters, which is
over two minutes of speech. Adding more instruction to fix either made both *worse* — the prompt is near the
point where extra rules cost more than they buy.

Run-to-run variance is wide (the same prompt produced 248, 312 and 437 characters on one case), so treat a
single run as a smoke test, not a measurement.

### Cost

Every reply returns its token counts, so spend is measured rather than estimated. `CostTracker` accumulates
them and the session total shows in the header; each turn is logged under the `cost` category:

```
[cost] turn 1292 in + 80 out = 0.338¢ | session 4 turns, 3886 in + 305 out = $0.011
```

Measured on a real 4-turn conversation at `claude-sonnet-5-5` rates ($2/M input, $10/M output):

| Turn | Input tokens | Output tokens | Turn cost |
|---|---|---|---|
| 1 | 728 | 28 | 0.17¢ |
| 2 | 818 | 99 | 0.26¢ |
| 3 | 1048 | 98 | 0.31¢ |
| 4 | 1292 | 80 | 0.34¢ |

About **$0.27 per 100 turns** of that shape — testing is close to free.

The thing to watch is the first column. The whole conversation is resent every turn, so input tokens climb
while output stays flat, and cost per turn grows the longer you talk. Input already dominates: 3886 input
tokens against 305 output. Prompt caching would cut the repeated prefix tenfold ($0.20/M instead of $2/M) and
is the obvious fix if sessions get long.

Account-wide spend needs the Admin API, which rejects a normal `sk-ant-usr-…` key. Create an Admin key in
Console (Settings ▸ Admin keys) if you want org-level reporting; the in-app number covers this app alone.

### TODO

**Better voice (cloud TTS).** On-device `AVSpeechSynthesizer` tops out at Premium, a clear tier below what the
Claude mobile app sounds like — that uses **ElevenLabs** (Anthropic lists it as a subcontractor; the five voices
are Buttery, Airy, Mellow, Glassy, Rounded). Matching it means swapping `Speaker` for a streaming cloud TTS:

- ElevenLabs Flash v2.5 (~75-150ms to first audio) or Cartesia Sonic, called over raw HTTP like `ClaudeClient`
- Costs a second API key and per-character billing; adds a network dependency to every reply
- `Speaker` is already the only thing that touches TTS, so the swap is one file

**Stream the reply.** Today the full response is fetched before any audio plays, so there's a 2-4s silence after
the trigger fires. Streaming the Messages API and speaking after the first sentence would cut most of that —
likely a bigger felt improvement than voice timbre, and free. Note Claude's own voice mode is *full-duplex*
(it decides when you've stopped talking), which is exactly the behaviour this app exists to avoid — take its
TTS, not its turn-taking.

### Known limitations

- `claude-sonnet-5-5` has thinking on by default, which adds latency before each spoken reply.
  Adding `let thinking = ["type": "between_tools"]` (plus a `CodingKeys` case) to `RequestBody`
  turns it off.
- `Speaker.speak` must be called sequentially; a second call before the first returns would strand
  its continuation.
- A `.error` status persists until the next successful action.
- The API key is compiled into the binary. Personal-device POC only — don't ship it.

### Debugging

Logs go through `OSLog` under subsystem `Longform`. In Console.app filter by subsystem, or in Terminal:

```sh
log stream --predicate 'subsystem == "Longform"' --style compact
```

Categories: `speech` (model resolution, listening start/stop, conversion errors),
`trigger` (every match, with the text that matched), `api` (turn count, reply size, round-trip time).
