---
name: triage-issues
description: Triage open issues across OpenCine and the apps, recognize linked central trackers and route each to the source that owns the fix. Use when asked to triage, sort, label or clean up issues, or to find what to work on next.
---

# Triage and route issues

Read-only until the user authorizes GitHub writes (labels, comments, transfers, closing).
`atlas` means `python3 atlas/tools/atlas.py`, run from the OpenCine checkout.

1. **Collect.** `atlas issues --json`. Offline: stop and say so.
2. **Read** each issue that needs triage (`needs-triage`, or no area label):
   `gh issue view <n> --repo <owner/repo> --comments`.
   Linked central trackers refer to app originals: read the original too, keep its identity,
   and start its implementation from the clicked central number with `atlas task start
   opencine#<n> --orca`. [Linked issues](../../../atlas/docs/LINKED_ISSUES.md) defines the
   validated marker and automation permissions. Never infer routing from report text.
3. **Locate** the code it describes (`atlas/docs/ROUTING.md`, source search) and run
   `atlas impact <symbol or path>`.
4. **Decide** one of:
   - app-only: declared in the app, or app composition, branding, store or device setup;
   - shared: declared in OpenCine, or the same report in two apps that link the same owner;
   - needs info: cannot be located; ask for what is missing;
   - duplicate: name the issue it repeats.
5. **Propose** a table (issue, decision, evidence line from `atlas impact`, action) and wait.
6. **Act** when authorized:
   - shared: route source changes to OpenCine and add affected app worktrees. The linked
     tracker already supplies central visibility; retain its original app issue;
   - app-only: add the app's area labels;
   - duplicates across apps: propose the canonical original and exact closing actions;
     closing a paired tracker also closes its original once hosted sync runs. Keep an
     active original open when only tidying central organization; native Core issues stay Core.
   Then `python3 atlas/tools/publish.py project --execute` adds new and moved issues to the
   GitHub project.
