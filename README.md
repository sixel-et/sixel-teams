# Hubless Agent Teams with Claude Code

**How to coordinate multiple AI agent sessions without a central orchestrator, custom harness, or API integration.**

This is a pattern guide for building peer-to-peer agent coordination using standard tools: tmux, bash, git, and the filesystem. No framework required. We've tested this architecture over multi-day sessions with multiple concurrent Claude Code instances.

---

## Why Hubless?

Most agent team frameworks (CrewAI, AutoGen, Claude's native agent teams) use a central orchestrator: one lead agent delegates to workers, collects results, and makes decisions. This works for defined workflows, but it has limitations:

- **Single point of failure.** The lead dies, the team dies.
- **Rigid hierarchy.** Workers can't initiate, only respond.
- **Context bottleneck.** The lead must hold the full picture in its context window.
- **Custom infrastructure.** You need the framework's runtime, its message format, its execution model.

Hubless teams flip this. Each agent session is an independent peer. They share work through the filesystem, coordinate through tmux, and persist through git. No session is special. Any session can initiate, contribute, or pass.

## Architecture Overview

```
                    ┌──────────────┐
                    │ External I/O │  (email, API, webhook — whatever)
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   Watcher    │  Polls for work, stores it,
                    │   (bash)     │  scans for responses, ships them
                    └──────┬───────┘
                           │ writes to shared filesystem
                    ┌──────▼───────┐
                    │  Shared State│  Per-task directories with
                    │  (filesystem)│  input, responses, and status
                    └──┬───────┬───┘
                       │       │ reads
                ┌──────▼──┐ ┌──▼──────┐
                │Session A │ │Session B │  Independent Claude Code
                │ (tmux)   │ │ (tmux)   │  sessions
                └──────┬───┘ └───┬─────┘
                       │         │
                    ┌──▼─────────▼──┐
                    │   Watchdog     │  Monitors liveness, wakes
                    │   (bash)       │  idle sessions when work arrives
                    └───────────────┘

        Peer-to-peer (direct between sessions):
                ┌──────────┐     ┌──────────┐
                │Session A │◄───►│Session B │
                └──────────┘     └──────────┘
            git-tracked messages + tmux attention signal
```

Two communication patterns:
1. **External coordination** — work arrives from outside, multiple sessions contribute, one assembled result goes out.
2. **Peer protocol** — sessions talk directly to each other via git-tracked message files and tmux attention signals.

## The Five Components

### 1. Watcher

A bash loop that handles external I/O. It has no intelligence — it polls, stores, scans, and sends.

- Polls an external source (email inbox, API, queue) on a fixed interval
- Stores new work items as files in per-task directories
- Scans those directories for response files written by agent sessions
- After a configurable delay from the first response, assembles contributions and ships the result
- Tracks seen item IDs to prevent duplicates

**The key design choice:** The watcher never decides *what* to say. It only manages I/O. Agent sessions read the input, decide whether to contribute, and write their response as a file. The watcher collects and sends.

The main loop is minimal:

```bash
while true; do
    poll_for_work
    scan_for_responses
    ship_ready_items
    sleep "$INTERVAL"
done
```

### 2. Watchdog

The watchdog monitors session liveness and wakes idle sessions when work arrives. This is the mechanism that lets sessions sleep without polling.

- Checks heartbeat files on a fixed interval (each session touches a file on interaction)
- When new work is pending AND a session has been idle past a threshold, it injects a notification into the session's tmux terminal
- The notification tells the session what arrived and how to respond

**Why this works:** Claude Code sessions respond to text that appears in their terminal. You can use `tmux send-keys` to inject a message. The session sees it as user input and wakes up — same mechanism as a human typing.

**The tmux send-keys gotcha:** Send the text in literal mode and the Enter keystroke separately. Long messages with embedded newlines don't register reliably.

### 3. Heartbeat Hook

A shell hook fires on every user interaction, touching a timestamp file. This is how the watchdog knows which sessions are active.

Use Claude Code's hook system (`UserPromptSubmit` event) to touch a per-session file on each interaction. The watchdog checks file modification times to determine idle duration.

**The feedback loop problem:** When the watchdog injects a tmux message, it triggers the hook, which updates the heartbeat, which makes the session look active again. If you have idle-detection logic (e.g., "notify when operator is away"), the injection itself resets the timer.

Solution: use a grace period. Only clear state flags if the heartbeat is significantly newer (several minutes) than the flag timestamp. A reflexive heartbeat from injection is seconds old; a real interaction is minutes newer.

### 4. Peer Protocol

Direct session-to-session communication, independent of external I/O.

**Messages are sequentially numbered JSON files** in a git-tracked directory. The filename encodes sender, recipient, and ordering. Each message contains the sender, recipient, subject, body, and an optional reply-to reference.

**Delivery flow:**
1. Write the message file
2. Append a human-readable summary to a log file
3. Git commit and push
4. Signal the recipient's tmux session (the "doorbell")

**Why git?**
1. **Persistence.** Messages survive restarts, crashes, and context compaction.
2. **Observability.** The human operator can read the full conversation on GitHub.
3. **Sync.** If sessions run on different machines, git push/pull handles it.

Sessions maintain a **peer registry** mapping peer names to tmux session names. On startup and after compaction, each session scans for unread messages addressed to it.

### 5. Lifecycle Management

**Auto-start:** A SessionStart hook launches the watcher and watchdog if they aren't already running. Use a lock file AND process liveness checks — if the lock exists but processes died, restart them. Wire this into session startup so the infrastructure is always available.

**Post-compaction recovery:** When a session's context gets compressed, it loses awareness of pending work. A post-compaction hook re-injects state by scanning for:
- Pending work items (stored but not yet shipped)
- Unread peer messages
- Session identity (PID, peer name)

This means a session that just lost its entire context can orient itself from the filesystem in seconds.

## Shared State Design

The filesystem is your message bus. Structure it around individual work items:

```
project/
├── scripts/                # Your watcher, watchdog, send tools
├── state/                  # Runtime state (gitignore this)
│   ├── work/<item-id>/     # Per-item workspace
│   │   ├── input.json      # The incoming work item
│   │   ├── responses/      # One file per contributing session
│   │   └── status.json     # Tracking: received, responded, shipped
│   └── seen-ids            # Already-processed item IDs
├── chat/                   # Peer messages (git-tracked)
│   ├── messages/           # Numbered JSON files
│   └── log.md              # Human-readable conversation log
```

Ephemeral state (PID-scoped) goes in `/tmp/` — heartbeat files, process locks, session manifests. Anything that needs to survive a restart goes in the project directory.

**Gitignore the runtime state directory.** It contains work items, responses, and status — operational data that shouldn't be in version control. The peer chat directory IS tracked — that's the audit trail.

### Response Files

Each session's response should be self-describing. Include:
- **Who** wrote it (session identifier)
- **When** (timestamp)
- **What type** — contribution, pass, or supplementary note
- **Ordering hint** — primary vs. supplementary, so assembly is mechanical
- **What they saw** — IDs of other responses visible when writing

The "what they saw" field creates a partial ordering. Later responders can build on earlier ones, and you can reconstruct the information flow after the fact.

## Best Practices

### 1. Let the filesystem be the message bus

Don't build a message queue. Directories and JSON files are the shared data structure. Every component reads and writes files. This is debuggable (`ls`, `cat`, `jq`), persistent (survives crashes), and requires zero infrastructure.

### 2. Use tmux as the attention mechanism, not a transport

The tmux signal is a doorbell, not a mailbox. It says "look at this" — it doesn't carry the payload. The payload lives in the filesystem. This separation means messages aren't lost if the session is busy when the doorbell rings.

### 3. Separate the I/O loop from the decision-making

The watcher handles mechanics. The watchdog handles lifecycle. Agent sessions handle thinking and responding. No component does two jobs. This makes each component independently testable and replaceable.

### 4. Track what you've seen, not what exists

Every polling component maintains its own "seen" list. The watcher tracks seen item IDs. The peer protocol tracks seen message filenames per peer. This is idempotent — reprocessing the same directory twice is safe.

### 5. Design for compaction

Agent sessions will lose context. Plan for it:
- Post-compaction hooks re-inject essential state
- All state lives in files, not in the agent's memory
- Pending work is discoverable from the filesystem alone
- A session that just lost context should be able to orient itself in under a minute

### 6. Git is your audit trail

Every peer message is committed. Every push is logged. The human operator can read the full conversation history, see who said what, and verify nothing was tampered with. This isn't overhead — it's the trust mechanism.

### 7. One heartbeat is enough

You might be tempted to add multiple heartbeat types (polling, interaction, inference). Don't. One heartbeat per session, updated on user/agent interaction. The watchdog uses it for one decision: "is this session idle?" Everything else is over-engineering.

### 8. Handle the feedback loop

Watchdog injection triggers hooks that update the heartbeat. This makes the session look active, preventing re-wake — but also clears idle-detection state. Use a time-based grace period: only clear state flags if the heartbeat is significantly newer than the flag.

### 9. Make responses self-describing

Each response file should contain enough metadata for mechanical assembly — who wrote it, when, what role (primary vs. supplementary), what they saw before writing. No intelligence needed at the I/O layer. Sort by role, concatenate, add separators, ship.

### 10. Idempotent everything

Startup checks a lock AND verifies processes are alive. Polling checks seen-IDs before processing. Peer scans check read-trackers before alerting. Every operation should be safe to repeat. Crashes will happen. Compaction will happen. Idempotency makes recovery automatic.

## What Makes This Different

- **No framework.** bash + tmux + git + filesystem. Runs anywhere Claude Code runs.
- **No hierarchy.** Any session can initiate work, contribute to shared tasks, or communicate with peers.
- **No shared context.** Each session has its own context window, its own project focus. Coordination happens through files, not through a shared memory space.
- **Transparent to the operator.** Every message, response, and decision is a file you can read. The git log is the audit trail. The log file is the conversation in plain English.
- **Resilient.** Sessions crash, contexts compact, processes restart. The filesystem persists. The auto-start hooks recover. Nothing depends on a single process staying alive.

## Limitations and Trust Model

- **Same machine or shared filesystem.** The peer protocol requires filesystem access between sessions. For distributed setups, git push/pull adds latency but works.
- **tmux dependency.** The doorbell mechanism requires tmux. This is standard for Claude Code but wouldn't work for headless deployments.
- **Concatenation, not reconciliation.** If two sessions write contradictory responses, the assembly is concatenation with separators. The "saw prior" field mitigates this — later responders build on earlier ones — but there's no conflict resolution.
- **Flat trust.** All sessions running as the same user are equally trusted. Internal authentication between scripts running as the same Unix user isn't a meaningful security boundary — if one session is compromised, the user account is compromised. For multi-user or multi-agent setups, add authentication at the filesystem level (Unix permissions, separate user accounts).
- **Security is at the perimeter.** External I/O (email, webhooks) should be authenticated and validated before work items reach the shared filesystem. The internal coordination layer trusts what's on disk. This is the same model as any application that trusts its own database.
- **Content injected via tmux becomes agent input.** The watchdog injects email subjects and response commands into agent terminals. A malicious email subject becomes part of the agent's prompt. Your email service or external I/O layer should sanitize inputs — particularly subjects and metadata — before they reach the shared filesystem. This is a prompt injection surface by design (the doorbell IS the prompt). Defend at the perimeter, not inside the hub.
- **Wake-up interrupts active work.** The watchdog sends Ctrl-C before injecting a wake message, which will interrupt any running command in the session. The idle threshold (default 5 minutes) provides a safety margin, but don't set it too low or you'll kill active work.
- **Watcher must be a singleton.** Multiple watchers polling the same inbox will race on seen-IDs and status files. Run exactly one watcher. The watchdog can safely run alongside it since it only reads state.

---

*Developed and tested with Claude Code running concurrent sessions. The architecture has handled multi-day operation including sleep/wake cycles, context compaction recovery, and peer coordination without data loss.*
