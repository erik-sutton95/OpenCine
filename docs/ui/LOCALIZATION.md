# Localized copy

The shared operator copy is written in English and translated beside it. The English string is
the key, so a missing translation reads exactly as the app reads today, and every contract that
pins the English text keeps working: `Fixtures/playback-copy.tsv`, the parity tests and the Swift
twin `MonitorPlaybackCopy` in `Sources/MonitorPresentation`.

This guide covers the Android side (`Android/monitor-ui`). The Swift side carries the same shape
but no table yet, which is the one platform difference this change records.

## Why the copy is not in `strings.xml`

Android resources are the usual answer, and they are the wrong tool for this copy:

- The copy contract is a unit test. `MonitorPlaybackCopyVectorTest` and
  `MonitorPlaybackCopyVectorTests` read one fixture and compare every string, and they run on the
  JVM. Reading `R.string` needs an instrumented test or Robolectric, which this module does not
  use, so moving the copy into resources would move the contract into a slower, device-bound test.
- The English text is the shared artifact. Both platforms and the fixture name the same words, so
  the words are the key. A resource id would need a second mapping between the id and the fixture.
- Accessibility copy is read outside composition too (labels handed to `semantics` blocks and to
  hosts), where `stringResource` is not available.

If a later change moves the copy into resources, `CopyCatalog` is the seam to replace: the screens
read resolved strings, not the source of them.

## Using it

A screen resolves the copy once per composition and reads it like the constants:

```kotlin
val copy = MonitorPlaybackCopy.resolved(LocalCopyLanguage.current)
MonitorPlaybackActionChip(MonitorIcon.REPEAT, copy.loop, { ... }, active = looping)
```

`LocalCopyLanguage` defaults to the device language (`CopyLanguage.preferred()`), so an app that
does nothing shows the operator's language. The value is `internal` today because the whole seam
is: promoting it, so a host can offer its own picker, is a public API change and moves the
`:monitor-ui` API dump with it.

## Coverage

| Surface | State |
| --- | --- |
| Playback (`MonitorPlaybackCopy`, 35 strings and 4 composed labels) | Translated to `zh-Hans` |
| Settings (`MonitorSettingsCopy`) | English |
| Gyro (`GyroCopy`) | English |
| Live chrome (`MonitorOperatorVocabularySurface`) | English |
| Host app strings | The app |

The playback surface came first because its text is fixture-pinned, so a translation cannot drift
from the English without a test failing. The remaining surfaces take the same three steps.

## Adding a language

1. Add a case to `CopyLanguage` with its BCP 47 tag.
2. Add its table to `CopyTranslations`.
3. Extend `CopyLanguage.resolve` when the new tag needs matching that the language subtag alone
   does not express. Traditional Chinese is the worked example: `zh-Hant`, `zh-TW`, `zh-HK` and
   `zh-MO` read English on purpose rather than the simplified table.
4. `CopyTranslationTest` covers the rest: it fails on a missing row, a stale row, a blank value and
   an em dash.

## Rules

- The key is the English text. Editing English copy retires its translation, and
  `CopyTranslationTest` reports the orphaned row instead of leaving it silently unused.
- Operator copy never uses the em dash, translated or not.
- Composed labels (`Rate 1 star`, `7 seconds`) translate through `MonitorPlaybackCopyUnits`, so a
  language can change the word order instead of only the words.
- A translation keeps the punctuation of the English it replaces, so a host can swap languages
  without reflowing a sheet.

## Verification

```sh
cd Android
./gradlew :monitor-ui:testDebugUnitTest --tests '*CopyTranslationTest*'
```

`CopyTranslationTest` asserts that every fixture row has a Chinese row, that resolving in English
reproduces the fixture vectors byte for byte (so the resolved copy is a faithful twin of the
constants), that Chinese composes the shared units, that the style rules hold, and that an unknown
language or an empty table reads English.
