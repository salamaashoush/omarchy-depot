// Pure formatting and filtering for the repos panel. Kept out of the QML so
// the view stays declarative and these stay trivially testable.

var GROUPS = [
  { key: "session",  title: "IN SESSION" },
  { key: "changes",  title: "UNCOMMITTED WORK" },
  { key: "activity", title: "BY ACTIVITY" }
]

function groupTitle(key) {
  for (var i = 0; i < GROUPS.length; i++) if (GROUPS[i].key === key) return GROUPS[i].title
  return ""
}

// Filter on the lowercase haystack the scanner precomputed, then rank: a hit
// in the repo's own name beats a hit in its description, and an earlier hit
// beats a later one. Subsequence matching lets "clts" find "clap-ts".
function filter(repos, query, limit) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return repos.slice(0, limit)

  var scored = []
  for (var i = 0; i < repos.length; i++) {
    var repo = repos[i]
    var short = String(repo.short || "").toLowerCase()
    var score = -1

    var atShort = short.indexOf(q)
    if (atShort === 0) score = 0
    else if (atShort > 0) score = 10 + atShort
    else {
      var atHay = String(repo.search || "").indexOf(q)
      if (atHay >= 0) score = 100 + atHay
      else if (subsequence(short, q)) score = 400
    }

    if (score >= 0) scored.push({ repo: repo, score: score, order: i })
  }

  scored.sort(function(a, b) { return a.score - b.score || a.order - b.order })

  var out = []
  for (var j = 0; j < scored.length && out.length < limit; j++) out.push(scored[j].repo)
  return out
}

function subsequence(haystack, needle) {
  var at = 0
  for (var i = 0; i < needle.length; i++) {
    at = haystack.indexOf(needle.charAt(i), at)
    if (at < 0) return false
    at++
  }
  return true
}

// Flatten into the rows a ListView draws: a header row per group, then its
// repos. Headers carry `isHeader` so the delegate can switch on it.
//
// Filtered results are ordered by relevance, not by group, so the groups are
// no longer contiguous and a header per change would repeat itself down the
// list. Under a filter the ranking is the only order that matters, so the
// headers are dropped entirely.
function rows(repos, grouped) {
  var out = []
  if (!grouped) {
    for (var n = 0; n < repos.length; n++) out.push({ isHeader: false, repo: repos[n], key: repos[n].name + ":" + n })
    return out
  }

  // Count each group up front so its header can carry the total — the list
  // scrolls, so "ON GITHUB · 420" is the only place that number is legible.
  var totals = {}
  for (var t = 0; t < repos.length; t++) totals[repos[t].group] = (totals[repos[t].group] || 0) + 1

  var current = ""
  for (var i = 0; i < repos.length; i++) {
    var repo = repos[i]
    if (repo.group !== current) {
      current = repo.group
      out.push({ isHeader: true, title: groupTitle(current), count: totals[current] || 0, key: "h:" + current })
    }
    out.push({ isHeader: false, repo: repo, key: repo.name + ":" + i })
  }
  return out
}

function relativeTime(epoch) {
  if (!epoch) return ""
  var seconds = Math.floor(Date.now() / 1000) - epoch
  if (seconds < 0) seconds = 0
  if (seconds < 90) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.round(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.round(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.round(months / 12) + "y ago"
}

// The compact status cluster after the branch name: what changed, and how far
// the branch has drifted from its upstream.
function statusText(repo) {
  if (!repo || !repo.cloned) return ""
  var parts = []
  if (repo.dirty) parts.push("●" + repo.dirty)
  if (repo.ahead) parts.push("↑" + repo.ahead)
  if (repo.behind) parts.push("↓" + repo.behind)
  if (repo.conflicts) parts.push("!" + repo.conflicts)
  return parts.join(" ")
}

// Hover detail for the status cluster — the breakdown the one-number summary
// deliberately hides.
function statusDetail(repo) {
  if (!repo || !repo.cloned) return ""
  var parts = []
  if (repo.staged) parts.push(repo.staged + " staged")
  if (repo.unstaged) parts.push(repo.unstaged + " modified")
  if (repo.untracked) parts.push(repo.untracked + " untracked")
  if (repo.conflicts) parts.push(repo.conflicts + " conflicted")
  if (repo.ahead) parts.push(repo.ahead + " to push")
  if (repo.behind) parts.push(repo.behind + " to pull")
  return parts.length ? parts.join(", ") : "clean"
}

// The second line under the repo name. Cloned repos talk about the checkout;
// uncloned ones talk about GitHub.
function subtitle(repo) {
  if (!repo) return ""
  if (!repo.cloned) {
    var bits = []
    if (repo.language) bits.push(repo.language)
    if (repo.stars) bits.push("★" + repo.stars)
    if (repo.private) bits.push("private")
    var pushed = relativeTime(repo.pushedAt)
    if (pushed) bits.push("pushed " + pushed)
    return bits.join(" · ")
  }
  var line = []
  if (repo.branch) line.push(repo.branch)
  var status = statusText(repo)
  if (status) line.push(status)
  var touched = relativeTime(repo.lastCommit)
  if (touched) line.push(touched)
  return line.join("  ")
}

function sessionLabel(repo) {
  if (!repo || !repo.session) return ""
  var agent = repo.session.agent || "shell"
  var status = repo.session.status || ""
  return status && status !== "unknown" ? agent + " · " + status : agent
}

function glyph(repo) {
  if (!repo) return "󰊢"
  if (repo.session) return "󱚝"          // an agent is live in this checkout
  if (!repo.cloned) return "󰇚"          // downloadable
  if (repo.conflicts) return "󰅚"
  if (repo.dirty) return "󰜘"
  if (repo.ahead || repo.behind) return "󰓡"
  return "󰊢"
}

// Bar summary: the one number worth carrying in the status bar.
function barBadge(counts) {
  if (!counts) return ""
  if (counts.sessions) return String(counts.sessions)
  if (counts.dirty) return String(counts.dirty)
  return ""
}

function summary(counts) {
  if (!counts || !counts.total) return "No repos yet"
  var parts = []
  if (counts.sessions) parts.push(counts.sessions + " live")
  if (counts.dirty) parts.push(counts.dirty + " dirty")
  parts.push(counts.cloned + " cloned")
  parts.push(counts.remote + " on GitHub")
  return parts.join(" · ")
}


// The workspace path as the hero pill shows it: home-relative, and clipped to
// its last two components when even that is too long to sit next to a title.
function shortPath(path, home) {
  var p = String(path || "")
  if (home && p.indexOf(home) === 0) p = "~" + p.substring(home.length)
  if (p.length <= 28) return p
  var parts = p.split("/").filter(function(x) { return x.length })
  if (parts.length <= 2) return p
  return "…/" + parts.slice(-2).join("/")
}


// Right-column line 1. A checkout reports where it is and what changed; a repo
// you have not cloned reports what GitHub knows about it.
function trailingPrimary(repo) {
  if (!repo) return ""
  if (repo.cloned) return repo.branch || ""
  var bits = []
  if (repo.language) bits.push(repo.language)
  if (repo.stars) bits.push("★" + repo.stars)
  return bits.join("  ")
}

function trailingTime(repo) {
  if (!repo) return ""
  return relativeTime(repo.activityAt || repo.lastCommit || repo.pushedAt)
}

// Left-column line 2: the most specific thing we know. A checkout has a real
// last commit; an uncloned repo only has whatever the description says.
function detailLine(repo) {
  if (!repo) return ""
  if (repo.cloned) return repo.lastCommitSubject || "No commits yet"
  return repo.description || ""
}
