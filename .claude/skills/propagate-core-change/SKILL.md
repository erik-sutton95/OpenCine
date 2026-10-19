---
name: propagate-core-change
description: Carry a change in OpenCine shared code (core, media, UI, multicam or an integration) to every app that uses it. Use when changing a public type, contract, UI component or shared behavior, or when asked which apps a change affects.
---

# Propagate a core change

Run from the OpenCine checkout. `atlas` means `python3 atlas/tools/atlas.py`.

1. **Measure first.** `atlas impact <symbol or path>`: owner target or Gradle module and its
   layer, the products that carry it, the apps that link one of them (read from the apps'
   manifests) and their call sites. `atlas impact opencine --include-candidates` gives the
   repository order.
2. **One task folder.** `atlas task start opencine#<n> --with <app> ...` for every linking app
   (any OpenCine issue number works before OpenCine is on GitHub). Each app worktree builds
   against the task's OpenCine branch.
3. **Add, migrate, remove.** Add the new API beside the old one; migrate each app in its
   worktree; remove the old API in a later change (below 1.0 an incompatible change bumps the
   minor version). An app not migrated in this task must still build.
4. **Keep the rules.** Capability, not brand: shared code asks for a capability, setting
   descriptor or service, never which manufacturer or app it runs in. Swift and Kotlin change
   together. Import rules: AGENTS.md; `atlas check` enforces target layers.
5. **Verify** OpenCine (AGENTS.md, Verification), then every linking app with its own checks in
   the task folder, iOS on a private simulator, operator-visible UI on a physical device or
   `untested`. Record what ran per repository.
6. **Land in order** (each step needs the user's go): OpenCine merges; each app moves
   `opencine-pins.txt` (after publishing: the version in its manifests) in its own reviewed
   change; then update atlas refs and edges (`atlas/docs/MAINTENANCE.md`).
