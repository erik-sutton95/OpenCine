# Automatic two-way linked issues

GitHub-hosted automation pairs every registered app issue with one OpenCine tracker.
Titles, descriptions, comments, label assignments, eligible assignees and closing/reopening
synchronize in both directions. Native Core-only issues stay in OpenCine. The registry
selects apps; original app identity keys task reuse and PR references.

After one-time installation, no local command, running Orca session or local scheduler is
needed. The central [workflow](../../.github/workflows/atlas-linked-issues.yml) reacts to
central issue/comment events and reconciles all registered repositories every five minutes.
GitHub can delay scheduled runs; this is eventual synchronization, not an instant delivery
promise. The workflow checks out only the default branch, serializes hosted writers, skips
its own bot events and writes only changed fields. Source text never becomes shell code.

## Paired fields, conflicts and deletion

Each authenticated pair stores durable last-common field fingerprints and set baselines in
central managed metadata. The editable description is the full source report inside its
encoded `<pre>` section; escaping preserves Markdown, mentions, entities and marker syntax
exactly on roundtrip. Edit that report to change the paired description. Operator notes
outside the managed section and internal routing/state metadata stay central. The app prefix
on the central title identifies the pair and is removed when applying its title to the app.
Oversize titles, reports, comments or state are explicit incomplete results; nothing truncates.

One-sided edits propagate, equal edits settle, and competing title/description/comment edits
remain intact on both sides with an explicit conflict. Independent fields and pairs continue.
Resolve a conflict by making both sides agree, or restore one side to the recorded common
version; the next run settles it. There is no timestamp-based last-writer winner.

Labels and assignees use three-way set addition/removal. A missing label definition is
created from its existing source definition; existing repository colors/descriptions are
never overwritten and global labels are never deleted. Ineligible assignees stay visible as
a blocked field, retaining both intended assignments while other fields progress. Automation
never grants repository access. API writes are read back before common state advances.

Comments retain original author and canonical source URL. Authenticated copies have stable
origin IDs, so edits flow both ways without copying echoes. A separate, paginated, bounded
bot-owned index retains both endpoint IDs, last confirmed text and tombstones. Deleting an
original marks the surviving copy as logically deleted and retains its text. Deleting a copy
records a tombstone without recreating it or deleting the surviving original. Deleting both
retains the last indexed content. No DELETE API is used. Post a new comment to start a new
pair after a logical deletion. Missing/altered index shards require review and block that
pair before field writes; they never mean an empty history. Index comments are internal
state, not operator comments to mirror or manually remove.
Every durable record's origin, peer binding, fingerprint, content type and pending/deletion
state are validated before any field, index or carrier write; invalid records require review.

Existing records retain their shard membership, including tombstones whose two endpoints
are gone. New records append without moving existing history; all prospective shard sizes
are checked before any index object is written, and writes are read back before checkpoint.
A growing record that exceeds its shard's limit leaves prior durable content intact and
reports incomplete; it is never moved or truncated to force success.

New comment copies first persist their complete origin and text as prepared index records.
The central manifest references those shards before any carrier POST, and a separate
attempt checkpoint is confirmed before sending it. A fresh inventory recovers an accepted
authenticated carrier even when its response was lost. If an attempted carrier is absent,
the result stays explicitly incomplete and retains the text without another POST: absence
cannot distinguish a failed request from a copy that was accepted and then human-deleted.
A prepared record whose attempt checkpoint was never accepted can resume automatically.
Independent fields and pairs continue while an ambiguous attempt needs deliberate review.

## Identity and failure recovery

A versioned marker names exactly the registered app, positive issue number and canonical
GitHub issue URL. Only trackers and state/copy comments **created by the configured sync
App bot** grant reverse-write authority; a public user's copied marker is report data, not
permission. Invalid or duplicate authenticated identities fail closed. Pull requests and
unrelated Core issues are excluded. Every issue, label and comment inventory is paginated;
a failed initial read cannot imply deletion, absence or success.

The workflow's concurrency group serializes hosted runs. Optional local diagnostics default
to a read-only JSON plan (`python3 atlas/tools/linked_issues.py`). The backend's `--execute`
requires the dedicated installation identity. Use the hosted executor; a local lock cannot
coordinate separate machines/checkouts. REST provides no unique-marker constraint or atomic
compare-and-swap, so external concurrent edits can still race the final read. The engine
rechecks visible values before writes and checkpoints only confirmed equal fields.

Receipts contain actual `applied`, `errors`, per-field `conflicts`, `tombstones` and any
`uncertain` request. A partial result is not success. Uncertain creates are never retried in
the same run; a fresh complete inventory finds stable markers and durable copy attempts.
An attempted copy with no surviving carrier requires review, never a reset or blind retry.
Disable activation while investigating corrupted/duplicate state, retain all surviving notes
and indexed text, and resolve the identified state deliberately. Do not delete indexes or
reset baselines to force a green run.

A read that succeeds can still be incomplete: on 2026-10-22, during a GitHub degradation, the
central listing came back without the existing trackers and one run created a second tracker
for every open app issue. Creation therefore trusts absence only after a second complete
central read names exactly the same authenticated trackers, and an automatic run creates at
most five trackers. A larger backfill is a manual workflow dispatch with `execute` ticked
(`--allow-backfill`), after a dry run was reviewed. Receipts record inventory sizes
(`inventory`) so an incomplete read is visible.

### Retiring a duplicate tracker

Keep the older tracker: it holds the durable common baseline, the poll checkpoint and the
comment index that existing copies bind to. Then:

1. Set `ATLAS_LINKED_ISSUES_ENABLED` to `false` and snapshot both trackers and their comments.
2. Edit the duplicate's body to a plain note naming the kept tracker, with no
   `<!-- atlas-linked-issue:` text left (any leftover fragment fails every run). Read it back.
   Without the marker it is an ordinary Core issue and its comments are never read again.
3. Only then close it as a duplicate. Never close a tracker that still carries its marker:
   closing is a paired field and would close the app issue. Never edit the kept tracker.
4. Run the dry run (locally and as a manual dispatch without `execute`), confirm no create
   and no unexpected app-side write, then one manual execute, then re-enable activation.

## One-time hosted setup and activation

The default GITHUB_TOKEN cannot write child repositories: its authority is limited to its
own repository ([GitHub documentation](https://docs.github.com/en/actions/concepts/security/github_token)).
Use a dedicated GitHub App installed on only the repositories named by the registry:
OpenCine, OpenPocketCine, OpenInstaCine and OpenZCine today. Future registered apps also need
that installation selection. Current repositories share one owner; another owner needs a
separately reviewed installation/token scope before it can be synchronized.

The App needs repository **Issues: read and write** and mandatory **Metadata: read** only.
No Contents write, organization membership/access grant, PAT, child secrets or child workflows
are needed. The central workflow uses a short-lived token from the pinned official
[create-github-app-token action](https://github.com/actions/create-github-app-token).
Its ordinary GITHUB_TOKEN has only Contents read for checkout. Use a dedicated GitHub App
private key; credentials for unrelated services must never enter this workflow.

Prepare these steps locally; publishing, App installation/key generation, repository settings,
workflow execution and live issue changes require explicit authorization:

1. Register an App named `opencine-atlas-sync` (or review the chosen slug and update
   `atlas/issue-sync.json`), disable webhooks, grant only the permissions above, and install
   it on the exact registered repositories. The bot login must match the authored config.
2. Store its client ID in central repository variable `ATLAS_SYNC_APP_CLIENT_ID` and its PEM
   private key in central Actions secret `ATLAS_SYNC_APP_PRIVATE_KEY`. Store the exact bot
   login in variable `ATLAS_SYNC_BOT_LOGIN`; never print the key or installation token.
3. Deploy the reviewed workflow/backend to the default branch. Scheduled/event writes remain
   dormant until `ATLAS_LINKED_ISSUES_ENABLED` equals `true`. The App is the only sync writer.
4. Run one hosted manual dry run (the default), inspect complete inventories, proposed actions,
   permissions and conflicts, then explicitly authorize one manual execution for backfill.
5. Inspect actual receipts and both paired states, then enable
   `ATLAS_LINKED_ISSUES_ENABLED=true`. Ordinary issue/comment/label/assignment changes then
   synchronize automatically with no routine manual command. Disabling the variable stops
   future automatic runs without deleting issues or state.

Public automation is not active merely because this implementation exists locally.

## Start implementation in Orca

Use the linked OpenCine number, for example:

```sh
python3 atlas/tools/atlas.py task start opencine#70 --orca
```

The validated central marker resolves to the original app. Both identities go into `TASK.md`,
and the original `<app>-<number>` keys the folder and branch. Starting the original directly
and starting its tracker therefore reuse the same task. Linked tasks include editable
OpenCine and the reporting app; having an editable Core checkout does not imply a runtime fix.
Route ownership from current manifests and source before editing. For a shared change, assess
every app and rerun with `--with <app>` for each additional consumer to change or verify.

`--orca` uses the public Orca catalog to discover and adopt Atlas's existing Git worktrees.
They are **adopted/discovered**, not native-created. The physical sibling layout stays
`OpenCine-tasks/<app>-<number>/{OpenCine,<App>}`, so SwiftPM, Xcode and Gradle resolve the same
OpenCine directory without source rewrites or symlink assumptions. A fresh Orca issue workspace
can discover registered repository paths; explicit `atlas/.local/checkouts.json` mappings
still take precedence. Add missing repositories to Orca using `orca repo add --path` on a
verified checkout, then retry.

Atlas verifies full catalog IDs, physical paths, identity, issue links, ownership and parent
metadata. The reporting app links its original number and task Core links the central number.
The matching clicked Core issue workspace is the launcher parent; work continues with the
current agent in the returned task children. An unlinked launcher leaves task Core independent
and associates apps through companion catalog IDs in comments and the shared receipt.
The current Orca runtime rejects cross-repository parent cards with
`LINEAGE_PARENT_CONTEXT_CONFLICT`: apps remain independently operable in their registered
projects, and Atlas does not claim a nested cross-repository card hierarchy.
Conflicting issue ownership, foreign comments/parents or a caller
linked to another Core issue fail before adoption. No model, agent or second writer is started.

The task's `.atlas-orca.json` is a local custody receipt. If adoption fails partway, preserve
all worktrees, inspect `adopted`, `attempting` and `error`, correct the reported catalog conflict,
then rerun the same command. Previously verified worktrees are reused. Do not create another
task branch, relocate paths or change global Orca visibility to bypass a conflict. Raw Git
mode remains available without `--orca` for existing scripts; it makes no Orca ownership claim.
After merge or deliberate abandonment, use Orca removal for adopted worktrees and retain
unique task notes before deleting the task folder.

A provider-neutral agent prompt is:

> Implement OpenCine issue #70. Read AGENTS.md and the issue-to-task workflow, then run
> `python3 atlas/tools/atlas.py task start opencine#70 --orca` and continue this agent in
> the returned task worktrees. Read TASK.md and each repository's instructions, confirm
> source ownership before editing, verify affected consumers, and report original and
> tracking issue status separately. Public actions require explicit authorization.
