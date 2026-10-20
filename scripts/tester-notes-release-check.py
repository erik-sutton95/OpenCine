#!/usr/bin/env python3
"""Fail a release when its tester notes still describe the previous release.

Release and upload workflows run this before building. A notes file is stale when a
successful earlier release already contained its newest revision: the release commit
descends from the last commit that changed the file. Re-running a release of the same
commit is allowed. Format and caps stay with the *-release-notes-check.sh scripts.

Earlier releases come from one of:
    --released-by-workflow FILE  successful GitHub Actions runs of that workflow (Play, TestFlight);
                                    with --release-job NAME, only runs whose NAME job succeeded
                                    (a run can succeed with its upload job skipped)
    --released-by-status TEXT    successful commit statuses whose context contains TEXT, on
                                    the first-parent history (Xcode Cloud: "<app> | TestFlight ...")
    --released-sha SHA           an explicit release commit (tests, manual checks)

The GitHub API is read with GH_TOKEN or GITHUB_TOKEN when set (public repositories also work
without one). Any lookup failure fails the release: an unknown history is not a fresh one.
Contract: docs/testing/CI.md (Release time) and the app's tester notes doc.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

API = "https://api.github.com"
# Notes that survived this many first-parent commits were almost certainly released.
MAX_STATUS_COMMITS = 100


class CheckError(Exception):
    pass


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], text=True, capture_output=True, check=check)


def is_ancestor(ancestor: str, descendant: str) -> bool:
    return git("merge-base", "--is-ancestor", ancestor, descendant, check=False).returncode == 0


def have_commit(sha: str) -> bool:
    return git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0


def ensure_full_history(repo: str) -> None:
    if git("rev-parse", "--is-shallow-repository").stdout.strip() != "true":
        return
    # Xcode Cloud and default Actions checkouts are shallow; the check needs the file history.
    fetched = git("fetch", "--quiet", "--unshallow", "--no-tags", f"https://github.com/{repo}.git", check=False)
    if fetched.returncode != 0:
        raise CheckError(f"cannot read the full history of {repo}: {fetched.stderr.strip()}")


def api_get(path: str) -> object:
    # curl uses the system trust store on macOS (Xcode Cloud) and Linux, unlike some Pythons.
    headers = ["Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28"]
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers.append(f"Authorization: Bearer {token}")
    # Headers go through stdin so the token never appears in a process listing.
    fetched = subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--max-time", "30", "-H", "@-", API + path],
        input="\n".join(headers) + "\n", text=True, capture_output=True)
    if fetched.returncode != 0:
        raise CheckError(f"GitHub API {path} failed: {fetched.stderr.strip()}")
    try:
        return json.loads(fetched.stdout)
    except json.JSONDecodeError as error:
        raise CheckError(f"GitHub API {path} returned no JSON: {error}") from error


def workflow_releases(repo: str, workflow: str) -> list[tuple[str, int]]:
    """(head SHA, run id) of every successful run, newest first."""
    found: list[tuple[str, int]] = []
    for page in range(1, 4):
        body = api_get(f"/repos/{repo}/actions/workflows/{workflow}/runs?status=success&per_page=100&page={page}")
        runs = body.get("workflow_runs", []) if isinstance(body, dict) else []
        found += [(run["head_sha"], run["id"]) for run in runs]
        if len(runs) < 100:
            break
    return found


def job_succeeded(repo: str, run_id: int, job: str) -> bool:
    body = api_get(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
    jobs = body.get("jobs", []) if isinstance(body, dict) else []
    return any(entry.get("name") == job and entry.get("conclusion") == "success" for entry in jobs)


def status_releases(repo: str, context: str, since: str, head: str) -> list[str]:
    """Commits from head back along the first parent that carry `since` and a successful status."""
    commits = git("rev-list", "--first-parent", f"--max-count={MAX_STATUS_COMMITS + 1}", head).stdout.split()
    released: list[str] = []
    walked = 0
    for sha in commits:
        if not is_ancestor(since, sha):
            return released
        walked += 1
        if walked > MAX_STATUS_COMMITS:
            raise CheckError(f"notes unchanged for over {MAX_STATUS_COMMITS} commits; rewrite them for this release")
        if sha == head:
            continue
        body = api_get(f"/repos/{repo}/commits/{sha}/status?per_page=100")
        statuses = body.get("statuses", []) if isinstance(body, dict) else []
        if any(context in status.get("context", "") and status.get("state") == "success" for status in statuses):
            released.append(sha)
    return released


def default_repo() -> str:
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    url = git("remote", "get-url", "origin", check=False).stdout.strip()
    tail = url.rstrip("/").removesuffix(".git").replace(":", "/").split("/")
    if len(tail) >= 2 and tail[-2] and tail[-1]:
        return f"{tail[-2]}/{tail[-1]}"
    raise CheckError("set --repo or GITHUB_REPOSITORY")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--notes", action="append", required=True, help="notes file; repeat for each")
    parser.add_argument("--repo", help="owner/name (default: GITHUB_REPOSITORY or origin)")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--released-by-workflow", metavar="FILE")
    source.add_argument("--released-by-status", metavar="TEXT")
    source.add_argument("--released-sha", action="append", metavar="SHA")
    parser.add_argument("--release-job", metavar="NAME", help="with --released-by-workflow: the upload job")
    args = parser.parse_args(argv)
    if args.release_job and not args.released_by_workflow:
        parser.error("--release-job needs --released-by-workflow")

    try:
        repo = args.repo or (None if args.released_sha else default_repo())
        if repo:
            ensure_full_history(repo)
        head = git("rev-parse", "HEAD").stdout.strip()
        runs: list[tuple[str, int | None]] | None
        if args.released_by_workflow:
            runs = list(workflow_releases(repo, args.released_by_workflow))
        elif args.released_sha:
            runs = [(sha, None) for sha in args.released_sha]
        else:
            runs = None

        stale: list[str] = []
        for path in args.notes:
            last = git("log", "-1", "--format=%H", "HEAD", "--", path).stdout.strip()
            if not last:
                raise CheckError(f"{path} has no history at HEAD")
            if runs is None:
                runs_here = [(sha, None) for sha in status_releases(repo, args.released_by_status, last, head)]
            else:
                runs_here = runs
            # Ancestry first (local), then the upload job (one API call per remaining run).
            shipped = [
                sha for sha, run_id in runs_here
                if sha != head and have_commit(sha) and is_ancestor(last, sha)
                and (not args.release_job or run_id is None or job_succeeded(repo, run_id, args.release_job))
            ]
            if shipped:
                stale.append(f"{path} (last changed {last[:8]}, already released at {shipped[0][:8]})")
            else:
                print(f"Tester notes are new for this release: {path} (last changed {last[:8]}).")
    except (CheckError, subprocess.CalledProcessError) as error:
        print(f"Tester notes release check failed: {error}", file=sys.stderr)
        return 1

    if stale:
        for entry in stale:
            print(f"Tester notes release check failed: still the previous release's notes: {entry}", file=sys.stderr)
        print("Rewrite them for this release (the app's tester notes doc), merge, then release again.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
