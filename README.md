# Repos — an Omarchy shell plugin

Every GitHub repo you can reach, in your Omarchy bar. See which checkouts have
uncommitted work, clone the ones you haven't, and start a Claude Code session
in any of them — without leaving the keyboard.

![The Repos panel](docs/screenshot.png)

## Install

```bash
omarchy plugin add https://github.com/salamaashoush/omarchy-repos.git --enable --yes
omarchy restart shell
```

Requires [`gh`](https://cli.github.com/) signed in (`gh auth login`).
[`herdr`](https://herdr.dev) is needed only for Claude sessions, and ships with
Omarchy. Optional: `lazygit` for the git action.

To summon it from the keyboard, add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + R", "Repos", "omarchy-shell sashoush.repos toggle")
```

Pick a combination that is free on your machine — `hyprctl binds -j` is the
authority, and it is worth avoiding keys one slipped modifier away from
something disruptive.

## Order

Two groups earn the top by being unfinished work: **IN SESSION** (a herdr pane
running an agent in that checkout) and **UNCOMMITTED WORK**. Everything else is
one **BY ACTIVITY** stream, cloned and uncloned interleaved, newest first,
where activity is `max(your last commit, GitHub's last push)` — the same number
the row displays, so a row's position and its stated age never disagree.

Sorting cloned repos above uncloned ones was the obvious first design and the
wrong one: it buried a repo pushed an hour ago under a checkout last touched
two years ago.

## Keys

Typing filters. Prefix matches on the repo name rank above substring matches,
above matches in the description; `clts` finds `clap-ts` by subsequence.

| Key | Action |
|---|---|
| `⏎` | Cloned → Claude session. Not cloned → clone, then session |
| `^D` | Clone only |
| `^E` | Editor (`omarchy-launch-editor`, so whatever `omarchy` is set to) |
| `^T` | Terminal in the checkout |
| `^G` | lazygit |
| `^O` | Open on GitHub |
| `^R` | Force a GitHub refresh |
| `^N` / `^P` | Move the cursor (arrows work too; `j`/`k` type into the filter) |
| `Esc` | Clear the filter, then close |

Bar icon: left click opens, right click refreshes. On a row, left click runs the
primary action and middle click opens it on GitHub. The active row reveals
editor / lazygit / GitHub buttons in place of its status column, so the row
never changes height under the pointer.

## Sessions

`⏎` on a checkout starts herdr if it isn't up, waits for its socket, creates a
workspace with `--cwd` at the repo, and runs `herdr agent start --kind claude`
in that workspace's root pane with whatever `claudeArgs` says.

Every repo becomes **another workspace inside the one running herdr session**,
never a second herdr instance — so herdr's workspace bindings walk between the
repos you have open. Opening a repo that already has a session focuses it
rather than stacking a second agent on the same checkout, and that lookup
matches on the pane's **working directory**, not its label: labels are repo
short names, and two owners can share one.

`claudeArgs` is empty by default, so sessions prompt for permissions as usual.
For a yolo session:

```bash
omarchy bar set sashoush.repos claudeArgs '--dangerously-skip-permissions'
```

## Clone destinations

A repo clones to `<workspaceDir>/<name>`. When more than one repo wants that
folder name — two orgs with a `.github` repo, or the same project name under a
personal account and an org — the contested ones go to
`<workspaceDir>/<owner>/<name>` instead, which the depth-2 scan then finds.
Uncontested names stay flat. Cloning goes through `gh`, so it honors your
`gh config git_protocol` and authenticates for private repos.

## Settings

`omarchy bar set sashoush.repos <key> <value>` (numbers and booleans need
`--json`):

| Key | Default | Meaning |
|---|---|---|
| `workspaceDir` | `~/Workspace` | Where clones land and checkouts are scanned |
| `scanDepth` | `2` | Levels below the workspace to search. 2 finds both `<ws>/repo` and `<ws>/owner/repo` |
| `owners` | `[]` | Empty auto-detects your GitHub login plus every org you belong to. Set it to pin the list |
| `refreshIntervalSec` | `90` | Local rescan cadence while the panel is open. Closed, it drops to `max(600, that × 8)` — each tick costs two git processes per checkout, and a closed panel only has to keep the bar dot honest |
| `remoteTtlSec` | `1800` | How stale the cached GitHub listing may get |
| `repoLimit` | `200` | Repos fetched per owner. An owner that hits the limit is named in the panel's status line rather than silently truncated |
| `includeForks` | `false` | Forks are hidden by default |
| `claudeArgs` | `""` | Passed to `claude` when a session starts |
| `cloneProtocol` | `ssh` | Cloning goes through `gh`, which honors `gh config git_protocol` |
| `editorCommand` | `""` | Empty uses `omarchy-launch-editor` |

## How it works

```
manifest.json   plugin + settings schema
Panel.qml       bar icon and popup — the only view code
Service.qml     owns every subprocess; the view never spawns one
Model.js        formatting, filtering, grouping — stateless
repos.py        the inventory scan
actions.sh      clone / session / open, one JSON line per call
```

`repos.py` walks the workspace `scanDepth` levels down for checkouts, running
`git status --porcelain=v2 --branch` across a thread pool, and merges that with
`gh repo list` for every owner. A directory that is itself a checkout is never
descended into, so vendored submodules don't each become a row.

The GitHub half is cached in `~/.local/state/omarchy/repos/remote.json`. The
panel's periodic scan passes `--stale-ok` and never touches the network, so it
stays a local pass measured in tens of milliseconds; a cold fetch of several
hundred repos takes seconds and only happens on the refresh button, `^R`, or
once the cache passes its TTL — always in the background, with the cached list
already on screen. A failed refresh keeps serving the last good cache rather
than blanking the list.

Every color and metric comes from the `qs.Commons` `Color` and `Style`
singletons, so `omarchy theme set <name>` re-themes the widget with no work
here.

## Hacking on it

Saving a file re-registers the plugin but does **not** reliably re-instantiate
the bar widget on Omarchy 4.0.1 — a stale panel keeps rendering, with no error
anywhere. Run `omarchy restart shell` to see QML or JS changes.

```bash
omarchy plugin validate .          # manifest + entry points
python3 repos.py --stale-ok | jq   # the scan, without the shell
./actions.sh clone "" /tmp/x owner/name
```

## License

MIT
