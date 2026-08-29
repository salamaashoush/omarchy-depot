import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Owns every subprocess the panel needs: the inventory scan, and the one-shot
// actions. The panel reads state off this and calls its methods; nothing in
// the view ever spawns a process itself.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  readonly property string home: Quickshell.env("HOME")

  property var repos: []
  property var counts: ({ total: 0, cloned: 0, dirty: 0, sessions: 0, remote: 0 })
  property bool loading: false
  property bool everLoaded: false
  property bool refreshingRemote: false
  property string lastError: ""
  property string remoteError: ""
  property string actionStatus: ""
  property bool actionFailed: false
  property int remoteAgeSec: 0
  property var remoteTruncated: []
  property bool workspaceExists: true
  // Set by the panel. A closed panel still wants the bar dot to be roughly
  // right, but not at the cost of spawning two git processes per checkout
  // every 90 seconds all day.
  property bool panelOpen: false
  property bool remoteStale: false
  property bool herdrRunning: false
  property string defaultAgent: ""
  property string workspace: ""

  // Set while a clone runs so the row can show progress and the panel can
  // refuse to fire a second clone at the same destination.
  property string busyRepo: ""
  property string busyVerb: ""

  readonly property string scanner: pluginDir + "/repos.py"
  readonly property string actions: pluginDir + "/actions.sh"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  readonly property string workspaceDir: expand(String(setting("workspaceDir", "~/Workspace")))
  readonly property int scanDepth: intSetting("scanDepth", 2, 1, 4)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 90, 15, 3600)
  readonly property int remoteTtlSec: intSetting("remoteTtlSec", 1800, 60, 86400)
  readonly property int repoLimit: intSetting("repoLimit", 200, 10, 1000)
  readonly property bool includeForks: String(setting("includeForks", false)) === "true" || setting("includeForks", false) === true
  readonly property string agentSetting: String(setting("agent", "auto"))
  // claudeArgs is the pre-1.1 name for this key, read as a fallback so an
  // existing config keeps working across the rename.
  readonly property string agentArgs: String(setting("agentArgs", setting("claudeArgs", "")))
  readonly property bool autoApprove: String(setting("autoApprove", false)) === "true" || setting("autoApprove", false) === true

  // What the panel calls the agent in its hints. "auto" defers to
  // `omarchy default agent`, which the scanner reports back to us.
  readonly property string resolvedAgent: agentSetting !== "auto" ? agentSetting : defaultAgent
  readonly property string editorCommand: String(setting("editorCommand", ""))
  readonly property string cloneProtocol: String(setting("cloneProtocol", "auto"))

  // "auto" hands gh the owner/name and lets `gh config git_protocol` decide;
  // ssh and https hand it an explicit URL instead. gh authenticates either
  // way, so private repos work without an ssh key when https is chosen.
  function cloneTarget(repo) {
    if (cloneProtocol === "ssh" && repo.sshUrl) return repo.sshUrl
    if (cloneProtocol === "https" && repo.httpsUrl) return repo.httpsUrl
    return ""
  }

  function expand(path) {
    var p = String(path || "")
    if (p.indexOf("~/") === 0) return home + p.substring(1)
    if (p === "~") return home
    return p
  }

  // `owners` reaches us as whatever the config happens to hold: a real array,
  // or a bare string when `omarchy bar set --json` collapses a one-element
  // array, or a hand-typed comma-separated list. Calling .join() on the string
  // form threw inside scan() and wedged the panel on "Scanning…" forever.
  function ownersArg() {
    var owners = setting("owners", [])
    if (owners instanceof Array) return owners.join(",")
    if (typeof owners === "string") {
      return owners.replace(/[\s,]+/g, ",").replace(/^,+|,+$/g, "")
    }
    return ""
  }

  // `full` forces a GitHub refetch; without it the scan serves GitHub from
  // cache at any age and stays a ~40ms local-only pass.
  function scan(full) {
    if (scanProcess.running) {
      if (full) pendingFull = true
      return
    }
    // Build the command line before claiming the loading flag: anything that
    // throws while reading settings must not leave the panel stuck reporting
    // a scan that never started.
    var args = ["python3", scanner,
                "--workspace", workspaceDir,
                "--depth", String(scanDepth),
                "--remote-ttl", String(remoteTtlSec),
                "--limit", String(repoLimit)]
    if (includeForks) args.push("--include-forks")
    if (ownersArg() !== "") args = args.concat(["--owners", ownersArg()])
    args.push(full ? "--refresh-remote" : "--stale-ok")
    loading = true
    refreshingRemote = !!full
    scanProcess.command = args
    scanProcess.running = true
  }

  function refresh() { scan(true) }

  property bool pendingFull: false

  function applyScan(raw) {
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      lastError = "Could not read the repo scan"
      return
    }
    if (!data || data.ok !== true) {
      lastError = "Repo scan failed"
      return
    }
    repos = data.repos || []
    counts = data.counts || counts
    remoteError = String(data.remoteError || "")
    remoteAgeSec = Number(data.remoteAgeSec || 0)
    remoteStale = data.remoteStale === true
    remoteTruncated = data.remoteTruncated || []
    workspaceExists = data.workspaceExists !== false
    herdrRunning = data.herdrRunning === true
    defaultAgent = String(data.defaultAgent || "")
    workspace = String(data.workspace || workspaceDir)
    lastError = ""
    everLoaded = true

    // First paint came from a cold cache — go get the real list in the
    // background now that something is already on screen.
    if (remoteStale && !refreshingRemote) Qt.callLater(function() { root.scan(true) })
  }

  function repoByName(name) {
    for (var i = 0; i < repos.length; i++) if (repos[i].name === name) return repos[i]
    return null
  }

  // ------------------------------------------------------------- actions

  function runAction(args, repoName, verb, successPrefix) {
    if (actionProcess.running) return
    busyRepo = repoName || ""
    busyVerb = verb || ""
    actionFailed = false
    actionStatus = successPrefix || ""
    actionProcess.command = args
    actionProcess.running = true
  }

  function startSession(repo) {
    if (!repo || !repo.cloned) return
    var name = resolvedAgent || "the agent"
    runAction([actions, "session", repo.path, repo.short,
               agentSetting, agentArgs, autoApprove ? "true" : "false"],
              repo.name, "session", "Starting " + name + " in " + repo.short + "…")
  }

  function clone(repo, thenSession) {
    if (!repo || repo.cloned) return
    sessionAfterClone = thenSession ? repo.name : ""
    runAction([actions, "clone", cloneTarget(repo), repo.path, repo.nameWithOwner || ""],
              repo.name, "clone", "Cloning " + repo.short + "…")
  }

  property string sessionAfterClone: ""

  function openTerminal(repo) {
    if (!repo || !repo.cloned) return
    runAction([actions, "terminal", repo.path], repo.name, "terminal", "")
  }

  function openEditor(repo) {
    if (!repo || !repo.cloned) return
    runAction([actions, "editor", repo.path, editorCommand], repo.name, "editor", "")
  }

  function openLazygit(repo) {
    if (!repo || !repo.cloned) return
    runAction([actions, "lazygit", repo.path], repo.name, "lazygit", "")
  }

  function browse(repo) {
    if (!repo || !repo.url) return
    runAction([actions, "browse", repo.url], repo.name, "browse", "")
  }

  // The one action every row has, whatever state it is in.
  function primary(repo) {
    if (!repo) return
    if (!repo.cloned) clone(repo, true)
    else startSession(repo)
  }

  Timer {
    id: refreshTimer
    // Two cadences: the configured one while you are looking at the panel,
    // and a much slower beat while it is closed, which only has to keep the
    // bar dot honest. Each tick costs two git processes per checkout, so a
    // workspace with forty repos would otherwise churn the disk all day for
    // a panel nobody has open.
    interval: (root.panelOpen ? root.refreshIntervalSec
                              : Math.max(600, root.refreshIntervalSec * 8)) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.scan(false)
  }

  Timer {
    id: actionStatusTimer
    interval: 4000
    repeat: false
    onTriggered: { root.actionStatus = ""; root.actionFailed = false }
  }

  Process {
    id: scanProcess
    running: false
    command: []
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    stderr: StdioCollector { id: scanErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      root.refreshingRemote = false
      if (exitCode === 0) root.applyScan(String(scanOut.text || ""))
      else root.lastError = String(scanErr.text || "Repo scan failed").split("\n")[0]
      if (root.pendingFull) { root.pendingFull = false; root.scan(true) }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var finishedRepo = root.busyRepo
      var verb = root.busyVerb
      root.busyRepo = ""
      root.busyVerb = ""

      var message = ""
      var ok = exitCode === 0
      try {
        var parsed = JSON.parse(String(actionOut.text || ""))
        message = String(parsed.message || "")
        ok = parsed.status === "ok"
      } catch (e) {
        message = String(actionErr.text || actionOut.text || "").split("\n")[0]
      }

      root.actionFailed = !ok
      root.actionStatus = message
      actionStatusTimer.restart()

      if (verb === "clone") {
        var chained = root.sessionAfterClone
        root.sessionAfterClone = ""
        // Pick the fresh checkout up before chaining, so startSession sees a
        // repo that is actually cloned.
        if (ok) {
          rescanThenChain.chainRepo = chained && finishedRepo === chained ? chained : ""
          rescanThenChain.restart()
        }
      } else if (verb === "session") {
        root.scan(false)
      }
    }
  }

  Timer {
    id: rescanThenChain
    property string chainRepo: ""
    interval: 150
    repeat: false
    onTriggered: {
      root.scan(false)
      if (chainRepo !== "") {
        var name = chainRepo
        chainRepo = ""
        chainStart.repoName = name
        chainStart.restart()
      }
    }
  }

  Timer {
    id: chainStart
    property string repoName: ""
    interval: 400
    repeat: false
    onTriggered: {
      var repo = root.repoByName(repoName)
      repoName = ""
      if (repo && repo.cloned) root.startSession(repo)
    }
  }
}
