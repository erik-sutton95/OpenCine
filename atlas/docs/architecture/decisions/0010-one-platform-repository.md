# ADR 0010: One platform repository, OpenCine, with the atlas inside it

Status: **Accepted.** Approved by the user on 2026-10-02 (consolidation); executed locally, nothing pushed.
Date: 2026-10-02

## Context

The shared code was seven local repositories (OpenCineCore, OpenCineUI, OpenCineMulticam,
OpenCineDJI, OpenCineNikon, OpenCineInsta360, OpenCineHarness) plus opencapture-atlas. Every
change crossed several pins, sibling checkouts and CI checkout scripts, and the publish needed
seven tags in dependency order with library ranges between them (ADR 0009). None of them had
been published yet, so merging them cost nothing downstream.

## Decision

- One repository, `OpenCine` (atlas id `opencine`), holds every shared Swift product and Android
  module under its existing name and Gradle coordinate, merged with full history
  (`git filter-repo` path renames, one merge per former repository).
- One root `Package.swift` with every product and target and the same target dependency edges;
  no package dependencies. One Gradle build in `Android/` with one wrapper and one version
  catalog; modules keep `com.opencapture.opencine:<module>`.
- The atlas lives at `atlas/`. It is still never a build dependency. Its registry has one
  platform entry with a product layer per target and module (`layers`), and `atlas check`
  enforces the plan 3.4 direction rules per target and module instead of per repository.
- One version for everything: one tag, `0.1.0`; in 0.x a minor bump means an incompatible change
  in some product. Apps pin it exactly and take one sibling path (`../OpenCine`) and one Gradle
  included build named `opencine` until published; `opencine-pins.txt` has one line.
- The former repositories are archived locally, not deleted.

## Consequences

- An app that links one product resolves nothing else (no package dependencies), so optional
  products cost a Core-only consumer nothing.
- Cross-area changes are one commit and one review; the direction rules are a check, not a
  repository boundary. A change in one area releases a new version of everything.
- Publishing is one remote and one tag; `publish.py` and its rehearsal follow (docs/PUBLISH.md).
- Old compatibility records name retired ids and old SHAs; they moved to `compat/archive/`.
