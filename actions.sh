#!/bin/bash
# Side-effecting actions for the sashoush.depot shell plugin.
#
# The panel never shells out to git or herdr directly — it calls one
# subcommand here and reads a single JSON line off stdout. Keeping the
# sequencing (start herdr if it isn't up, wait for the socket, create the
# workspace, attach Claude to its pane) in bash keeps the QML side free of
# multi-step process choreography.
#
# Usage: actions.sh <clone|session|terminal|editor|lazygit|browse> [args...]

set -uo pipefail

HERDR_SOCK="${HERDR_SOCK:-$HOME/.config/herdr/herdr.sock}"

reply() { # reply <ok|error> <message> [extra-json-fields]
  jq -cn --arg status "$1" --arg message "$2" \
    '{status: $status, message: $message} + (env.EXTRA // "{}" | fromjson)'
}

die() {
  reply error "$1"
  exit 1
}

# ------------------------------------------------------------------ cloning

cmd_clone() {
  local url="${1:-}" dest="${2:-}" nwo="${3:-}"
  [[ -n $dest ]] || die "clone needs a destination"
  [[ -n $url || -n $nwo ]] || die "clone needs a url"
  [[ -e $dest ]] && die "$(basename "$dest") already exists"

  mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"

  # `gh repo clone` honors the git_protocol you configured and authenticates
  # the same way the rest of the panel does, so private repos and hosts
  # without an ssh key still work. Plain git is the fallback for a checkout
  # that isn't a GitHub repo.
  # gh takes either a full URL or owner/name, and authenticates for both. A URL
  # is only passed when cloneProtocol forces a transport; otherwise the
  # shorthand lets `gh config git_protocol` decide.
  local target="${url:-$nwo}"
  local out
  if [[ -n $nwo || -n $url ]]; then
    out=$(gh repo clone "$target" "$dest" -- --recurse-submodules 2>&1)
  else
    out=$(git clone --recurse-submodules "$url" "$dest" 2>&1)
  fi

  if [[ $? -ne 0 ]]; then
    # A failed clone can leave a half-written directory behind; a retry from
    # the panel should not then trip the "already exists" guard above.
    [[ -d $dest ]] && rm -rf -- "$dest"
    die "$(clone_error "$out")"
  fi
  reply ok "Cloned into $(basename "$dest")"
}

# git and gh both bury the useful line in a paragraph of advice. Prefer the
# first line that actually names a cause over the trailing "make sure you have
# the correct access rights" boilerplate.
clone_error() {
  local text="$1" line
  line=$(grep -m1 -E "Permission denied|Could not resolve|Repository not found|not found|does not exist|authentication|timed out" <<<"$text")
  [[ -z $line ]] && line=$(grep -m1 -E "^(fatal|error|ERROR):" <<<"$text")
  [[ -z $line ]] && line=$(printf '%s' "$text" | tail -n1)
  printf '%s' "${line#*: }"
}

# ------------------------------------------------------------------- agents

# Which agent to launch. "auto" (the default) follows `omarchy default agent`,
# the same setting the rest of Omarchy reads.
resolve_agent() {
  local want="${1:-auto}"
  if [[ $want == "auto" || -z $want ]]; then
    omarchy-default-agent 2>/dev/null
  else
    printf '%s' "$want"
  fi
}

# Every agent spells "don't stop to ask" differently. This mirrors the table in
# omarchy-agent so a session started here behaves like one started from
# Omarchy's own launcher; it is only consulted when autoApprove is on.
auto_approve_args() {
  case "$1" in
    opencode) printf '%s' "--auto" ;;
    gemini)   printf '%s' "--yolo" ;;
    copilot)  printf '%s' "--allow-all" ;;
    crush)    printf '%s' "--yolo" ;;
    claude)   printf '%s' "--permission-mode auto" ;;
    grok)     printf '%s' "--permission-mode bypassPermissions" ;;
    codex)    printf '%s' "--approve-for-me" ;;
    omp)      printf '%s' "--auto-approve" ;;
    pi)       printf '%s' "" ;;          # pi has no approval prompts
    *)        printf '%s' "" ;;
  esac
}

# herdr can detect and drive these; anything else still runs, just as a plain
# command in the pane without herdr's agent status.
herdr_knows_agent() {
  case "$1" in
    pi | claude | codex | gemini | cursor | devin | agy | cline | omp | mastracode \
      | opencode | copilot | kimi | kiro | droid | amp | grok | hermes | kilo \
      | qodercli | qwen | maki) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ herdr sessions

herdr_up() {
  [[ -S $HERDR_SOCK ]] && herdr workspace list >/dev/null 2>&1
}

# herdr's server only exists while a client is attached, so the first session
# has to open a terminal and wait for the socket to appear.
ensure_herdr() {
  herdr_up && return 0

  omarchy-launch-or-focus-tui herdr >/dev/null 2>&1 &

  local waited=0
  while ((waited < 150)); do
    sleep 0.1
    herdr_up && return 0
    ((waited++))
  done
  return 1
}

herdr_json() { # herdr_json <args...> — unwraps the CLI envelope, fails on error
  local raw err
  # Keep stderr out of the payload: a stray herdr warning merged into stdout
  # would land in the middle of the JSON we are about to parse.
  raw=$(herdr "$@" 2>/dev/null) || return 1
  err=$(jq -r '.error.message // empty' <<<"$raw" 2>/dev/null)
  [[ -n $err ]] && { printf '%s' "$err"; return 1; }
  jq -c '.result // .' <<<"$raw" 2>/dev/null || return 1
}

cmd_session() {
  local path="${1:-}" label="${2:-}" agent_setting="${3:-auto}" agent_args="${4:-}" auto_approve="${5:-false}"
  [[ -d $path ]] || die "$path is not a directory"
  [[ -n $label ]] || label=$(basename "$path")

  local agent
  agent=$(resolve_agent "$agent_setting")
  [[ -n $agent ]] || die "No coding agent set — run: omarchy default agent <name>"
  command -v "$agent" >/dev/null 2>&1 || die "$agent is not installed"

  ensure_herdr || die "herdr did not start"

  # Already have a workspace on this checkout? Focus it instead of stacking a
  # second agent on the same directory.
  #
  # Matched by working directory, not by label: the label is the repo's short
  # name, and two owners can share one (Bltzo/mandarin-app and
  # salamaashoush/mandarin-app both label "mandarin-app"), so a label match
  # would silently hand you the wrong repo's session. Panes carry their real
  # cwd, which is unambiguous.
  local existing
  existing=$(herdr_json pane list | jq -r --arg d "$path" \
    '.panes[]? | select(.cwd == $d) | .workspace_id' | head -n1)
  if [[ -n $existing ]]; then
    herdr_json workspace focus "$existing" >/dev/null
    omarchy-launch-or-focus-tui herdr >/dev/null 2>&1 &
    reply ok "Focused $label"
    return 0
  fi

  local created pane
  created=$(herdr_json workspace create --cwd "$path" --label "$label" --focus) \
    || die "herdr workspace create failed: $created"
  pane=$(jq -r '.root_pane.pane_id // empty' <<<"$created")
  [[ -n $pane ]] || die "herdr did not return a pane"

  omarchy-launch-or-focus-tui herdr >/dev/null 2>&1 &

  local -a args=()
  if [[ $auto_approve == "true" ]]; then
    local approve
    approve=$(auto_approve_args "$agent")
    [[ -n $approve ]] && read -r -a args <<<"$approve"
  fi
  if [[ -n $agent_args ]]; then
    local -a extra=()
    read -r -a extra <<<"$agent_args"
    args+=("${extra[@]}")
  fi

  local started
  if herdr_knows_agent "$agent"; then
    if ! started=$(herdr_json agent start "$label" --kind "$agent" --pane "$pane" -- "${args[@]}"); then
      # The workspace is there and sitting at a shell prompt, which is still a
      # useful place to land — say so rather than pretending nothing happened.
      reply error "Workspace opened, but $agent did not start: $started"
      return 0
    fi
  else
    # herdr has no detector for this agent, so run it as a plain command. The
    # session works; only herdr's status reporting is missing.
    if ! started=$(herdr_json pane run "$pane" "$agent" "${args[@]}"); then
      reply error "Workspace opened, but $agent did not start: $started"
      return 0
    fi
  fi
  reply ok "$agent running in $label"
}

# ------------------------------------------------------------- plain openers

cmd_terminal() {
  local path="${1:-}"
  [[ -d $path ]] || die "$path is not a directory"
  (cd "$path" && setsid uwsm-app -- xdg-terminal-exec --dir="$path" >/dev/null 2>&1 &)
  reply ok "Opened terminal"
}

cmd_editor() {
  local path="${1:-}" editor="${2:-}"
  [[ -d $path ]] || die "$path is not a directory"
  if [[ -n $editor ]]; then
    (cd "$path" && setsid $editor "$path" >/dev/null 2>&1 &)
  else
    (cd "$path" && setsid omarchy-launch-editor "$path" >/dev/null 2>&1 &)
  fi
  reply ok "Opened editor"
}

cmd_lazygit() {
  local path="${1:-}"
  [[ -d $path ]] || die "$path is not a directory"
  (cd "$path" && setsid omarchy-launch-tui lazygit >/dev/null 2>&1 &)
  reply ok "Opened lazygit"
}

cmd_browse() {
  local url="${1:-}"
  [[ -n $url ]] || die "no URL for this repo"
  setsid omarchy-launch-browser "$url" >/dev/null 2>&1 &
  reply ok "Opened GitHub"
}

case "${1:-}" in
  clone)    shift; cmd_clone "$@" ;;
  session)  shift; cmd_session "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  editor)   shift; cmd_editor "$@" ;;
  lazygit)  shift; cmd_lazygit "$@" ;;
  browse)   shift; cmd_browse "$@" ;;
  *)        die "unknown action: ${1:-<none>}" ;;
esac
