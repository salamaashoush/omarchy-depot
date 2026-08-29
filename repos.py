#!/usr/bin/env python3
"""Repo inventory for the sashoush.depot Omarchy shell plugin.

Prints one JSON document on stdout describing every repo the panel can show:
local checkouts under the workspace folder, each with live git status, merged
with the GitHub repos reachable through `gh`. The GitHub side is cached on
disk with a TTL so opening the panel never waits on the network, and every
git call is fanned out across a thread pool so a folder full of checkouts
still answers in well under a second.

The shell only renders what comes out of here, so all the classification
(which group a repo lands in, how it sorts) is decided in this file.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

STATE_DIR = os.path.expanduser("~/.local/state/omarchy/depot")
REMOTE_CACHE = os.path.join(STATE_DIR, "remote.json")
HERDR_SOCK = os.path.expanduser("~/.config/herdr/herdr.sock")
AGENT_DEFAULT = os.path.expanduser("~/.config/omarchy/defaults/agent")

# Groups, in the order the panel stacks them. The first two are work already
# in flight — a live agent, or edits you have not committed — and they earn
# the top of the list by being unfinished, not by being recent.
#
# Everything else is one activity-ordered stream: a repo pushed an hour ago
# outranks a checkout you last touched two years ago, whether or not it
# happens to be cloned. Sorting cloned-before-uncloned buried exactly the
# repos worth reaching for.
GROUP_SESSION, GROUP_CHANGES, GROUP_ACTIVITY = "session", "changes", "activity"
GROUP_RANK = {GROUP_SESSION: 0, GROUP_CHANGES: 1, GROUP_ACTIVITY: 2}


def run(cmd, cwd=None, timeout=15):
    """Run a command, never raise. Returns (returncode, stdout, stderr)."""
    try:
        p = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "%s not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except Exception as exc:  # pragma: no cover - defensive
        return 1, "", str(exc)


# --------------------------------------------------------------- local repos

def default_agent():
    """Whatever `omarchy default agent` last wrote, or "" when unset."""
    try:
        with open(AGENT_DEFAULT) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def find_checkouts(workspace, depth):
    """Git checkouts under the workspace folder, at most `depth` levels down.

    Bounded on purpose: an unbounded walk over a workspace full of
    node_modules is exactly what makes a panel feel slow. A directory that is
    itself a checkout is never descended into, so vendored submodules and
    nested worktrees don't each become their own row.
    """
    out = []

    def walk(path, level):
        try:
            entries = sorted(os.scandir(path), key=lambda e: e.name.lower())
        except OSError:
            return
        for entry in entries:
            if not entry.is_dir(follow_symlinks=True) or entry.name.startswith("."):
                continue
            if os.path.exists(os.path.join(entry.path, ".git")):
                out.append(entry.path)
                continue
            if level < depth:
                walk(entry.path, level + 1)

    walk(workspace, 1)
    return out


def parse_status(raw):
    """Count the porcelain v2 lines into the numbers the panel shows."""
    branch, upstream, ahead, behind = "", "", 0, 0
    staged = unstaged = untracked = conflicts = 0
    for line in raw.splitlines():
        if line.startswith("# branch.head "):
            branch = line[14:].strip()
        elif line.startswith("# branch.upstream "):
            upstream = line[18:].strip()
        elif line.startswith("# branch.ab "):
            m = re.match(r"# branch\.ab \+(\d+) -(\d+)", line)
            if m:
                ahead, behind = int(m.group(1)), int(m.group(2))
        elif line.startswith("1 ") or line.startswith("2 "):
            # "<X><Y>" staged/unstaged status pair follows the record type.
            xy = line[2:4]
            if xy[0] != ".":
                staged += 1
            if xy[1] != ".":
                unstaged += 1
        elif line.startswith("u "):
            conflicts += 1
        elif line.startswith("? "):
            untracked += 1
    return {
        "branch": branch or "(detached)",
        "upstream": upstream,
        "ahead": ahead,
        "behind": behind,
        "staged": staged,
        "unstaged": unstaged,
        "untracked": untracked,
        "conflicts": conflicts,
        "dirty": staged + unstaged + untracked + conflicts,
    }


# A repo description is written by whoever owns the repo and a commit subject
# by whoever authored it, so neither is the user's own text. Both land in a
# fixed-height single-line row: fold the whitespace so nothing gains a second
# line, drop the control and bidi-override characters that would let a string
# misrepresent what it says, and cap the length so a repo carrying a megabyte
# of subject line cannot cost the bar a layout pass over all of it.
UNPRINTABLE = re.compile(
    r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]")


def clean_text(value, limit=200):
    return " ".join(UNPRINTABLE.sub("", str(value or "")).split())[:limit]


def name_with_owner(url):
    """github.com owner/name out of any remote URL shape, or ''."""
    u = (url or "").strip()
    if not u:
        return ""
    u = re.sub(r"\.git$", "", u)
    m = re.search(r"github\.com[:/]+([^/]+)/([^/]+)$", u)
    return "%s/%s" % (m.group(1), m.group(2)) if m else ""


def inspect(path):
    """Everything the panel needs about one local checkout."""
    # --no-optional-locks keeps a background poll from fighting a foreground
    # git for the index lock.
    base = ["git", "--no-optional-locks", "-C", path]
    rc, status_out, _ = run(base + ["status", "--porcelain=v2", "--branch"], timeout=20)
    info = parse_status(status_out) if rc == 0 else parse_status("")
    _, origin, _ = run(base + ["remote", "get-url", "origin"], timeout=5)
    _, last, _ = run(base + ["log", "-1", "--format=%ct%n%s"], timeout=10)

    lines = last.splitlines()
    commit_ts = int(lines[0]) if lines and lines[0].strip().isdigit() else 0
    subject = clean_text(lines[1]) if len(lines) > 1 else ""

    nwo = name_with_owner(origin)
    short = os.path.basename(path)
    info.update({
        "path": path,
        "cloned": True,
        "nameWithOwner": nwo,
        "name": nwo or short,
        "short": short,
        "owner": nwo.split("/")[0] if nwo else "",
        "url": "https://github.com/" + nwo if nwo else "",
        "lastCommit": commit_ts,
        "lastCommitSubject": subject,
        "readable": rc == 0,
    })
    return info


# -------------------------------------------------------------- github repos

def gh_owners(configured):
    """Whose repos to list: the configured owners, else you plus your orgs."""
    if configured:
        return configured, ""
    rc, out, err = run(["gh", "api", "user", "--jq", ".login"], timeout=20)
    if rc != 0:
        return [], (err or out or "gh is not authenticated").strip().splitlines()[0]
    owners = [out.strip()]
    rc, out, _ = run(["gh", "api", "user/orgs", "--paginate", "--jq", ".[].login"], timeout=25)
    if rc == 0:
        owners += [o.strip() for o in out.splitlines() if o.strip()]
    return owners, ""


GH_FIELDS = ",".join([
    "nameWithOwner", "name", "owner", "description", "primaryLanguage",
    "isPrivate", "isFork", "stargazerCount", "pushedAt", "url", "sshUrl",
    "defaultBranchRef",
])


def gh_list(owner, limit, include_forks):
    cmd = ["gh", "repo", "list", owner, "--limit", str(limit),
           "--no-archived", "--json", GH_FIELDS]
    if not include_forks:
        cmd.append("--source")
    rc, out, err = run(cmd, timeout=60)
    if rc != 0:
        return [], (err or out or "gh repo list failed").strip().splitlines()[0], False
    try:
        items = json.loads(out or "[]")
    except ValueError:
        return [], "gh returned unreadable JSON", False
    # gh stops at --limit without saying so, so a full page means there are
    # probably more repos we are not showing. Report it rather than quietly
    # serving a partial list.
    return items, "", len(items) >= limit


def iso_epoch(value):
    try:
        return int(time.mktime(time.strptime((value or "")[:19], "%Y-%m-%dT%H:%M:%S")))
    except Exception:
        return 0


def fetch_remote(owners_setting, limit, include_forks):
    owners, err = gh_owners(owners_setting)
    if not owners:
        return {"ok": False, "error": err or "no GitHub owners resolved",
                "fetchedAt": int(time.time()), "repos": []}

    repos, errors, truncated = {}, [], []
    with ThreadPoolExecutor(max_workers=min(8, len(owners))) as pool:
        results = pool.map(lambda o: (o,) + gh_list(o, limit, include_forks), owners)
        for owner, items, e, hit_limit in results:
            if e:
                errors.append(e)
            if hit_limit:
                truncated.append(owner)
            for item in items:
                nwo = item.get("nameWithOwner") or ""
                if nwo:
                    repos[nwo] = item
    return {
        "ok": bool(repos) or not errors,
        "error": "; ".join(errors[:2]),
        "owners": owners,
        "truncated": truncated,
        "fetchedAt": int(time.time()),
        "repos": list(repos.values()),
    }


def load_cache():
    try:
        with open(REMOTE_CACHE) as fh:
            return json.load(fh)
    except Exception:
        return None


def save_cache(payload):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = REMOTE_CACHE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(payload, fh)
        os.replace(tmp, REMOTE_CACHE)
    except OSError:
        pass


def remote_repos(owners_setting, ttl, limit, include_forks, force, stale_ok):
    cached = load_cache()
    age = int(time.time()) - int((cached or {}).get("fetchedAt", 0))
    if cached and not force and (stale_ok or age < ttl):
        return cached, age, False
    # No cache and told not to fetch: answer with the local half immediately
    # rather than making the panel wait on the network.
    if stale_ok and not cached:
        return {"ok": True, "error": "", "fetchedAt": 0, "repos": []}, age, False
    fresh = fetch_remote(owners_setting, limit, include_forks)
    # A failed refresh must not blank out a good cache — keep serving the old
    # list and just report the error alongside it.
    if not fresh.get("repos") and cached and cached.get("repos"):
        cached["error"] = fresh.get("error", "")
        return cached, age, True
    save_cache(fresh)
    return fresh, 0, True


# ------------------------------------------------------------ herdr sessions

def herdr_sessions():
    """Map absolute cwd -> live agent pane, so repos with a session sort first."""
    if not os.path.exists(HERDR_SOCK):
        return {}, False
    rc, out, _ = run(["herdr", "pane", "list"], timeout=6)
    if rc != 0:
        return {}, False
    try:
        payload = json.loads(out)
    except ValueError:
        return {}, False
    result = payload.get("result", payload)
    if payload.get("error"):
        return {}, False
    sessions = {}
    for pane in result.get("panes", []) or []:
        cwd = pane.get("cwd") or ""
        if not cwd:
            continue
        entry = {
            "workspaceId": pane.get("workspace_id", ""),
            "paneId": pane.get("pane_id", ""),
            "agent": pane.get("agent") or pane.get("display_agent") or "",
            "status": pane.get("agent_status") or "",
        }
        # A pane actually running an agent wins over a bare shell in the
        # same directory.
        if cwd not in sessions or (entry["agent"] and not sessions[cwd]["agent"]):
            sessions[cwd] = entry
    return sessions, True


# ------------------------------------------------------------------- merging

# A clone destination is only ambiguous when more than one repo wants the same
# folder name — the common case stays the flat workspace/<name> everyone
# expects, and only the genuine collisions nest under their owner.
def resolve_clone_paths(repos, workspace):
    wanted = {}
    for repo in repos:
        if repo["cloned"]:
            # An existing checkout owns its folder outright.
            wanted.setdefault(os.path.basename(repo["path"]).lower(), []).append(repo)
    for repo in repos:
        if not repo["cloned"]:
            wanted.setdefault(repo["short"].lower(), []).append(repo)

    for name, claimants in wanted.items():
        if len(claimants) < 2:
            continue
        for repo in claimants:
            if repo["cloned"] or not repo["owner"]:
                continue
            repo["path"] = os.path.join(workspace, repo["owner"], repo["short"])
            repo["contested"] = True


def merge(local, remote, sessions, workspace):
    by_key = {}

    for repo in local:
        key = (repo["nameWithOwner"] or "local:" + repo["short"]).lower()
        repo["session"] = sessions.get(repo["path"])
        by_key[key] = repo

    for item in remote:
        nwo = item.get("nameWithOwner") or ""
        key = nwo.lower()
        owner_login = (item.get("owner") or {}).get("login", "")
        lang = (item.get("primaryLanguage") or {}).get("name", "")
        pushed = iso_epoch(item.get("pushedAt"))
        meta = {
            "description": clean_text(item.get("description")),
            "language": lang,
            "private": bool(item.get("isPrivate")),
            "fork": bool(item.get("isFork")),
            "stars": int(item.get("stargazerCount") or 0),
            "pushedAt": pushed,
            "url": item.get("url") or ("https://github.com/" + nwo),
            "sshUrl": item.get("sshUrl") or ("git@github.com:%s.git" % nwo),
            "httpsUrl": (item.get("url") or ("https://github.com/" + nwo)) + ".git",
            "defaultBranch": (item.get("defaultBranchRef") or {}).get("name", ""),
        }
        if key in by_key:
            # Local truth (branch, dirt) stays; GitHub only fills in the
            # things a checkout cannot tell us.
            existing = by_key[key]
            for field, value in meta.items():
                if not existing.get(field):
                    existing[field] = value
            continue
        entry = {
            "path": os.path.join(workspace, item.get("name") or nwo.split("/")[-1]),
            "cloned": False,
            "nameWithOwner": nwo,
            "name": nwo,
            "short": item.get("name") or nwo.split("/")[-1],
            "owner": owner_login,
            "branch": meta["defaultBranch"],
            "upstream": "",
            "ahead": 0, "behind": 0,
            "staged": 0, "unstaged": 0, "untracked": 0, "conflicts": 0, "dirty": 0,
            "lastCommit": pushed,
            "lastCommitSubject": "",
            "readable": True,
            "session": None,
        }
        entry.update(meta)
        by_key[key] = entry

    repos = list(by_key.values())
    resolve_clone_paths(repos, workspace)
    for repo in repos:
        repo.setdefault("description", "")
        repo.setdefault("language", "")
        repo.setdefault("private", False)
        repo.setdefault("fork", False)
        repo.setdefault("stars", 0)
        repo.setdefault("pushedAt", repo.get("lastCommit", 0))
        repo.setdefault("sshUrl", "")
        repo.setdefault("httpsUrl", "")
        repo.setdefault("defaultBranch", "")
        repo.setdefault("session", None)
        repo.setdefault("contested", False)

        if repo["session"]:
            repo["group"] = GROUP_SESSION
        elif repo["cloned"] and (repo["dirty"] or repo["ahead"] or repo["conflicts"]):
            repo["group"] = GROUP_CHANGES
        else:
            repo["group"] = GROUP_ACTIVITY

        # Activity is the newest thing that happened to the repo anywhere:
        # your last local commit, or someone's last push to GitHub. Taking the
        # max means a repo a colleague moved today rises even if your checkout
        # is stale.
        recency = max(repo["lastCommit"] or 0, repo["pushedAt"] or 0)
        repo["activityAt"] = recency
        repo["sortKey"] = "%d:%012d" % (GROUP_RANK[repo["group"]], 10 ** 11 - min(recency, 10 ** 11 - 1))
        repo["search"] = " ".join([
            repo["name"], repo["short"], repo["owner"],
            repo["language"], repo["description"],
        ]).lower()

    repos.sort(key=lambda r: (r["sortKey"], r["name"].lower()))
    return repos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default="~/Workspace")
    ap.add_argument("--depth", type=int, default=2,
                    help="how many levels below the workspace to look for checkouts")
    ap.add_argument("--owners", default="")
    ap.add_argument("--remote-ttl", type=int, default=1800)
    ap.add_argument("--limit", type=int, default=200)
    ap.add_argument("--include-forks", action="store_true")
    ap.add_argument("--refresh-remote", action="store_true")
    ap.add_argument("--stale-ok", action="store_true",
                    help="serve GitHub from cache at any age; never fetch")
    args = ap.parse_args()

    workspace = os.path.abspath(os.path.expanduser(args.workspace))
    owners = [o.strip() for o in args.owners.split(",") if o.strip()]

    paths = find_checkouts(workspace, max(1, min(4, args.depth)))
    with ThreadPoolExecutor(max_workers=12) as pool:
        local = list(pool.map(inspect, paths)) if paths else []

    remote, age, refreshed = remote_repos(
        owners, args.remote_ttl, args.limit, args.include_forks,
        args.refresh_remote, args.stale_ok)
    sessions, herdr_up = herdr_sessions()

    repos = merge(local, remote.get("repos", []), sessions, workspace)
    counts = {"total": len(repos), "cloned": 0, "dirty": 0, "sessions": 0, "remote": 0}
    for repo in repos:
        if repo["cloned"]:
            counts["cloned"] += 1
        else:
            counts["remote"] += 1
        if repo["group"] == GROUP_CHANGES:
            counts["dirty"] += 1
        if repo["session"]:
            counts["sessions"] += 1

    json.dump({
        "ok": True,
        "workspace": workspace,
        "workspaceExists": os.path.isdir(workspace),
        "generatedAt": int(time.time()),
        "remoteError": remote.get("error", ""),
        "remoteFetchedAt": remote.get("fetchedAt", 0),
        "remoteAgeSec": 0 if refreshed else age,
        "remoteStale": (not refreshed) and age >= args.remote_ttl,
        "remoteTtlSec": args.remote_ttl,
        "remoteOwners": remote.get("owners", owners),
        "remoteTruncated": remote.get("truncated", []),
        "herdrRunning": herdr_up,
        "defaultAgent": default_agent(),
        "counts": counts,
        "repos": repos,
    }, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
