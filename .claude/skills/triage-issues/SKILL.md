---
name: triage-issues
description: Triage open issues across OpenCine and the apps and route each to the repository that owns the fix, moving shared-code issues to OpenCine. Use when asked to triage, sort, label or clean up issues, or to find what to work on next.
---

# Triage and route issues

Read-only until the user authorizes GitHub writes (labels, comments, transfers, closing).
`atlas` means `python3 atlas/tools/atlas.py`, run from the OpenCine checkout.

1. **Collect.** `atlas issues --json`. Offline: stop and say so.
2. **Read** each issue that needs triage (`needs-triage`, or no area label):
   `gh issue view <n> --repo <owner/repo> --comments`.
3. **Locate** the code it describes (`atlas/docs/ROUTING.md`, source search) and run
   `atlas impact <symbol or path>`.
4. **Decide** one of:
   - app-only: declared in the app, or app composition, branding, store or device setup;
   - shared: declared in OpenCine, or the same report in two apps that link the same owner;
   - needs info: cannot be located; ask for what is missing;
   - duplicate: name the issue it repeats.
5. **Propose** a table (issue, decision, evidence line from `atlas impact`, action) and wait.
6. **Act** when authorized:
   - shared: `gh issue transfer <n> <owner>/OpenCine --repo <owner>/<App>` (comments move, the
     old link redirects), then link it from related app issues;
   - app-only: add the app's area labels;
   - duplicates across apps: keep one (in OpenCine when shared), close the others with a link.
   Then `python3 atlas/tools/publish.py project --execute` adds new and moved issues to the
   GitHub project.
