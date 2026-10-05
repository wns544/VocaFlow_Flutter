# Japanese pitch-aware TTS feasibility — 2026-10-04

## Verified findings

Current app prefers the reading field and sends only text/language to Android
TextToSpeech. The original spelling and meaning are unavailable to the engine.

Kanjium offers pitch positions keyed by spelling and reading. A live read of
the upstream accents.txt returned the following exact entries:

| Spelling | Reading | Accent position |
| --- | --- | --- |
| 酒 | さけ | 0 |
| 鮭 | さけ | 1 |
| 雨 | あめ | 1 |
| 飴 | あめ | 0 |
| 橋 | はし | 2 |
| 箸 | はし | 1 |

0 denotes no lexical pitch drop; a positive number denotes the mora after
which pitch drops. Phrase-final and unaccented words can sound similar alone;
following particles reveal the distinction. These entries establish lexical
lookup feasibility, not listening verification of any synthesized audio.

Upstream states CC BY-SA 4.0 and requests attribution to Uros O. Distribution
must preserve attribution/license and applicable share-alike obligations for
the data. The text file does not contain Korean definitions or sense IDs.
It is a downloadable dataset, not a hosted meaning-disambiguation service.

VOICEVOX Engine exposes pronunciation and accent_type through its dictionary
API and supports per-request kana/accent synthesis. It is a self-hosted engine;
an existing public production API for this app has not been selected. Voice
terms and attribution must be checked for the chosen speaker. No engine was
installed, no paid service activated, and no user vocabulary was uploaded.

## Proposed integration

1. Preserve spelling, reading, and meaning in the speech request.
2. Use an attributed, pinned dictionary snapshot in a separate speech store.
3. Exact spelling + reading may produce one or multiple accent candidates.
   Never silently choose the first candidate or merge readings globally.
4. Meaning can select a sense only through a separately sourced sense mapping
   or a user-confirmed choice. AI suggestions are not verified dictionary data.
   Missing/ambiguous results must remain explicit, not fabricated.
5. Generate audio with the selected reading and accent, cache by spelling,
   reading, sense, accent, voice and engine version, then play the cached file.
   Use per-request synthesis rather than mutating a shared dictionary per play.
6. Compare actual audio for the above pairs before enabling a new provider.
   Existing Android TTS cannot enforce the chosen accent via its current API.

For a no-recurring-service-cost prototype, generate samples on the user's PC.
Live generation while away requires a reachable service or a supported on-device
engine. Pre-generated cached audio works without the PC after download.
Firestore users/{uid}/vocabBooks/*/words remains read-only.

## Sources

- https://github.com/mifunetoshiro/kanjium
- https://raw.githubusercontent.com/mifunetoshiro/kanjium/master/README.md
- https://raw.githubusercontent.com/mifunetoshiro/kanjium/master/data/source_files/raw/accents.txt
- https://github.com/VOICEVOX/voicevox_engine
- https://voicevox.hiroshiba.jp/term/

Status: feasibility and exact dictionary lookup verified. On-device Android
integration is implemented in v1.0.22: an attributed Kanjium snapshot provides
display data, and the bundled VOICEVOX runtime generates and caches a WAV only
for an exact single spelling+reading match. Existing device TTS remains the
fallback for ambiguous or missing entries. No vocabulary-card data is uploaded
or modified.

## Local synthesis prototype — 2026-10-05

The official Windows CPU VOICEVOX Engine 0.25.2 archive was downloaded to
`D:\DevTools\VocaFlowSpeech\`, SHA-256 verified against the release metadata,
and started on localhost only. Its API returned version 0.25.2 and speaker
metadata successfully.

A local generator at `tools/pronunciation/generate_pitch_samples.ps1` now
looks up exact spelling+reading pairs from a separately downloaded Kanjium
snapshot. It uses VOICEVOX `mora_data` after assigning an accent position,
then produces a WAV and manifest with source/query hashes. Updating only the
accent number without `mora_data` did not change the rendered audio; this was
verified and is why the recalculation is mandatory.

The first 30 source-backed samples generated successfully, including the
minimal pairs 酒/鮭, 雨/飴, 橋/箸. For 酒 (0) and 鮭 (1), the generated WAV SHA-256
hashes differed and the engine returned different mora-pitch values. These are
technical generation checks, not a native-speaker accuracy verdict. The tested
engine package does not include VOICEVOX Nemo, so no substitute speaker has
been selected as the app's default voice.
