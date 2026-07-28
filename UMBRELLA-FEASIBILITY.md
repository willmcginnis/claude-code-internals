# Umbrella skill for Claude Code's slash commands — feasibility

Claude Code **2.1.220**, assessed 2026-07-28. Companion to
[`SLASH-COMMAND-REACHABILITY.md`](SLASH-COMMAND-REACHABILITY.md), which established the
four-tier model and the dual-registration mechanism. This document does the next step: it
**enumerates every command individually**, gives each an autonomy verdict, and answers
whether a single skill granting Claude autonomous access to them is worth building.

**Answer up front: no.** Build a ~10-line `claude -p` wrapper for `/usage` if anything, and
keep this file as the reference. Section 4 justifies that with the numbers.

## What this corrects in the prior doc

| Prior claim | Corrected |
|---|---|
| **101** distinct command names | **108**. The prior scan anchored on `{type:"…"` and so missed six objects that put `description:`/`name:`/`aliases:` before `type:` — `/bug`, `/chrome`, `/keybindings`, `/release-notes`, `/rewind`, `/sandbox` — plus `/vim` and `/output-style` (built by a factory) and `/schedule` (upsell stub + bundled skill). |
| 18 dual-registered | **20**. `/config` and `/context` also carry both. |
| Tier C = "18, headless-capable" | **21 are actually headless-reachable** (probed), and the membership differs. `supportsNonInteractive` is *not* the gate — `isEnabled` is, and it evaluates at runtime. `/version` and `/skill-doctor` carry `supportsNonInteractive:!0` and are **not** reachable; `/agents`, `/clear`, `/compact`, `/config`, `/context`, `/design`, `/recap`, `/reload-skills`, `/__remote-workflow` and `/workflow-launch-exec` are, and were not in the prior list. |
| `/ultrareview` is Tier C | True, but for a reason the prior doc didn't have: it has a *real* `local` twin **and** a second, hidden C4E upsell stub. `/ultraplan`, `/teleport`, `/remote-control`, `/schedule`, `/autofix-pr` have only the stub — `supportsNonInteractive:!1`, `isHidden:!0`. A scan that counts stub registrations as headless paths would mis-tier all six. |

## Method and evidence grades

Every row is marked `probed`, `read-from-binary`, or `inferred`.

- **read-from-binary** — a rescan of `strings -a -n 6 ~/.local/share/claude/versions/2.1.220`,
  key-order-independent: anchor on every `type:"local"|"local-jsx"|"prompt"`, walk back to the
  enclosing `{`, then parse depth-1 fields with a brace/string-aware walker (no regex).
  Completeness check: of 43 `supportsNonInteractive` sites, 41 fall inside a captured object;
  the 2 that don't are a string-table entry and the filter function itself. All 28
  `requires:{ink:!0}` and all 18 `thinClientDispatch:` sites are owned. Factories were
  enumerated separately (`$2d` → 2 commands, `gyr` → 6 upsell stubs, 7 `prompt` loaders).
- **probed** — `claude -p "/cmd" --model claude-haiku-4-5 --output-format json`, run from the
  trusted scratch dir `/private/tmp`, **twice**, stdin closed.
- **inferred** — 4 commands were deliberately not probed because the probe itself would have a
  side effect: `/heapdump` (writes to `~/Desktop`), `/update` (would relaunch the binary), and
  `/design-consent` + `/design-revoke` (real account-state changes that should stay
  human-in-the-loop). Their rows say `*inferred*`.
- A further 6 — the `prompt`/bundled-skill commands `/init`, `/insights`, `/review`,
  `/statusline`, `/team-onboarding`, `/schedule` — were not probed either, because they cost
  real inference and have side effects (`/init` writes CLAUDE.md, `/schedule` creates a cloud
  routine). They need no probe: `WUe` admits every `prompt` command, and they are visible in
  the live Skill-tool listing, which is the authoritative source for Tier A. Their rows say
  `read-from-binary + live Skill listing`.

### On probe stochasticity

The brief warned that byte-identical probes on this system have given opposite results. **They
did not here, and there is a mechanical reason.** The clean run was 98 commands × 2 runs = 196
runs, with **zero splits — 100 % agreement — and a total cost of $0.0000**; every run reported
`num_turns: 0`. Local slash commands are dispatched and answered *before* any model call, so
there is no sampling step to be stochastic about. Stochasticity should be expected only for
`prompt`-type commands and for the one local command that hands control to the agent loop
(`/goal <condition>`), which is why those were either not probed or probed bare.

That the whole sweep is free is itself a load-bearing fact for section 3: the subprocess bridge
costs nothing per call, so its weakness is not price — it is scope.

**One split did occur, and it was my bug, not the system's.** A first pass used a
`while read … done < todo.txt` loop, which let `claude -p` slurp the remaining file as stdin:
`/rename` renamed the session to the contents of the todo list, and `/goal` received that list
as a goal condition — so it set a hook, entered the agent loop, and its two runs disagreed
(`num_turns` 2 vs 7, one erroring, $0.06 each). Re-run with `</dev/null`, bare `/goal` returns
`No goal set. Usage: /goal <condition>` deterministically at `num_turns: 0` and $0.00. Every
probe reported below is from the clean run. The verdicts were unchanged by the fix, because
command-name dispatch happens before argument handling — but the incident is the reason the
reproduction recipe at the end insists on closing stdin.

## The mechanism, read from the binary

Two functions decide everything.

```js
// non-interactive command set
function WUe(e){ if(H5()) return [];                       // H5() = Mt.disableSlashCommands
  return e.filter((t)=> t.type==="prompt" && !t.disableNonInteractive
                     || t.type==="local"  && t.supportsNonInteractive ) }

function _n(){ return !Mt.isInteractive }                  // "am I headless?"
```

So in a `claude -p` session the reachable set is exactly **`prompt` commands + `local`
commands whose `supportsNonInteractive` is set** — `local-jsx` is excluded wholesale. That is
the entire dual-registration story: a command wanting a headless path ships a second `local`
object, usually `isEnabled:()=>_n()` with `isHidden` inverted, so the two never collide.

Dispatch produces three distinguishable outcomes, and the distinction is load-bearing:

| Outcome | Telemetry code | Meaning |
|---|---|---|
| real output | — | reachable |
| `/X isn't available in this environment.` | `cmd_unavailable_headless` | the name **is** in the built-in registry (`eae()`), but `WUe` filtered it out |
| `Unknown command: /X` | `cmd_unknown` | the name is not in the registry *at all* in this mode |

### `supportsNonInteractive` is not a reliable predictor — this matters for the whole idea

32 commands carry `supportsNonInteractive:!0` on a `local` registration. Probed:

| Static prediction | Wrong | Rate |
|---|---|---|
| `supportsNonInteractive:!0` alone | 8 of 29 probed | **28 %** |
| …also discarding `isEnabled:()=>!1` (`/version`, `/pause-memory`, `/update`) | 6 of 27 | **22 %** |
| …also discarding runtime/statsig-gated `isEnabled` (`/import` → `tengu_import`, `/auto-mode-setup` → `tengu_auto_mode_config`, `/autocompact` → `p2d()`, `/stop` → is-background-session) | **2** of 27 | **7 %** |

The two the static read cannot explain at all are **`/exit`** (ungated `supportsNonInteractive:!0`
twin, yet answers `cmd_unavailable_headless`) and **`/skill-doctor`** (`isEnabled:()=>_n()`,
yet answers `cmd_unknown` — meaning its name isn't even in `eae()` headlessly). Both results
were identical across two runs.

**Consequence for the umbrella idea:** any skill generated from a static scan of the binary
would ship confidently wrong availability claims for roughly a quarter of the commands it
covers, and would have no way to detect that. Only probing settles it, and probes are
version-pinned — the registry is compiled in and drifts every release.

## Is there a generic bridge?

Three candidates. Only one is generic.

1. **A model-facing `SlashCommand` tool — does not exist in 2.1.220.** Verified: zero
   occurrences of a tool named `SlashCommand`; the three string hits are internal function
   names (`processSlashCommand`, `getDisableSlashCommands`, `peelStackedPromptCommands`). If
   one ever ships, most of this analysis collapses.
2. **A headless subprocess (`claude -p "/cmd"`) — genuinely generic**, and cheap: one wrapper
   covers all 21 reachable commands, each costing $0.00 and a couple of seconds because they
   never reach a model. This is the only reusable mechanism available.
3. **Hooks / file writes — bespoke per command.** `/goal` is a `Stop` hook of `type:"prompt"`;
   `/rename` is a sentinel consumed by a `UserPromptSubmit` hook; `/config`, `/permissions`,
   `/hooks`, `/sandbox`, `/keybindings` are settings-file edits. Nothing factors out — each is
   its own small piece of work with its own failure mode.

## 1. Complete inventory — all 108 commands

Shape key: `jsx` = `local-jsx` · `loc` = `local` · `prm` = `prompt` · `jsx*` = built by the
`$2d` deprecation-stub factory · `loc*` = built by the `gyr` Claude-for-Enterprise upsell
factory (`isHidden:!0`, `supportsNonInteractive:!1`).

Tier (per `SLASH-COMMAND-REACHABILITY.md`): **A** the model invokes it directly (it is a
Skill) · **C** headless-capable via a subprocess · **D** UI-only · **?** deliberately not
probed. Tier B of the prior doc is not a column here — "the same destination is reachable by
other means" is what the **Autonomy** column now says per command.

Evidence grade: **probed** = two `claude -p` runs, agreeing unless a split is noted ·
`read-from-binary` = read from the 2.1.220 registration object, not executed · *inferred* =
not probed because the probe would have had a side effect.

Counts: 21 Tier C · 77 Tier D · 6 Tier A · 4 not probed.

| # | Command | Shape | Tier | What it does | Autonomy | How / why | Evidence |
|---|---|---|---|---|---|---|---|
| 1 | `/__remote-workflow` | loc | C | Run the workflow script delivered in this session env (server-launched only) | **pointless** | Only meaningful inside a remote CCR session; errors `not-remote-session` locally. | **probed** — OK |
| 2 | `/add-dir` | jsx | D | Add a working directory to the session | **blocked** | Live-session permission scope. `additionalDirectories` in settings.json affects FUTURE sessions only. | **probed** — UI-ONLY |
| 3 | `/advisor` | jsx | D | Let Claude consult a stronger model at key moments | **native** | Agent tool with a `model` override does exactly this, on demand. | **probed** — UI-ONLY |
| 4 | `/agents` | loc | C | (removed) points you at .claude/agents/ | **native** | Agent tool + Read/Write on `~/.claude/agents/*.md`. | **probed** — OK |
| 5 | `/artifacts` | jsx | D | Browse published/shared artifacts | **blocked** | Renders an interactive panel; no headless twin. | **probed** — UI-ONLY |
| 6 | `/auto-mode-setup` | loc+jsx | D | Set up/customise auto mode | **blocked** | Twin gated on statsig `tengu_auto_mode_config.envOnboarding`; off — probe returns UI-only. | **probed** — UI-ONLY |
| 7 | `/autocompact` | loc+jsx | D | Configure the auto-compact window size | **bridgeable** | Write the autocompact keys to settings.json (or `claude -p '/config ...'`); twin's `p2d()` gate is off. | **probed** — UI-ONLY |
| 8 | `/autofix-pr` | jsx | D | Monitor and autofix issues with the current PR | **native** | Bash + `gh` does this directly; the command is a C4E upsell stub. | **probed** — UI-ONLY |
| 9 | `/background` | jsx | D | Send this session to the background | **blocked** | Mutates the live session's foreground state. | **probed** — UI-ONLY |
| 10 | `/branch` | jsx | D | Branch the conversation at this point | **blocked** | Transcript-tree surgery on the live session. | **probed** — UI-ONLY |
| 11 | `/brief` | jsx | D | Toggle brief-only mode | **pointless** | Pure output-display toggle for the human. | **probed** — UI-ONLY |
| 12 | `/btw` | jsx | D | Ask a quick side question without interrupting | **native** | Agent tool — spawn a subagent for the side question. | **probed** — UI-ONLY |
| 13 | `/bug` | jsx | D | Report a bug / share your conversation | **blocked** | Interactive upload+consent flow. | **probed** — UI-ONLY |
| 14 | `/cd` | jsx | D | Move this session to a new working directory | **blocked** | Live-session `originalCwd` mutation; a Bash `cd` does not persist. | **probed** — UI-ONLY |
| 15 | `/chrome` | jsx | D | Open Claude in Chrome settings | **pointless** | claude.ai-surface setting; nothing for an agent. | **probed** — UI-ONLY |
| 16 | `/clear` | loc | C | Start a new session with empty context | **blocked** | Headless twin works but clears the SUBPROCESS. Cannot clear own live context. | **probed** — OK |
| 17 | `/color` | loc+jsx | C | Set the prompt bar colour | **pointless** | Cosmetic; headless twin recolours the throwaway subprocess. | **probed** — OK |
| 18 | `/compact` | loc | C | Summarise the conversation to free context | **blocked** | Headless twin compacts the SUBPROCESS. No model-facing self-compaction. | **probed** — OK |
| 19 | `/config` | loc+jsx | C | Set a setting by key | **native** | settings.json is a file — Read/Write it. `update-config` skill is Tier A. | **probed** — OK |
| 20 | `/context` | loc+jsx | C | Show current context usage | **blocked** | Headless twin reports the SUBPROCESS's context (measured 24.9k/200k), not the caller's. | **probed** — OK |
| 21 | `/copy` | jsx | D | Copy Claude's last response to clipboard | **native** | Bash `pbcopy`. | **probed** — UI-ONLY |
| 22 | `/daemon` | jsx | D | Manage background services and routines | **native** | Bash `launchctl` / the daemon config files. | **probed** — UNKNOWN |
| 23 | `/design` | loc | C | Grant or revoke Claude access to Design projects | **bridgeable** | Headless twin dispatches; `claude -p '/design consent'` performs the grant out-of-session. | **probed** — OK |
| 24 | `/design-consent` | loc | ? | Grant Claude agent access to Design projects | **bridgeable** | Hidden local twin, supportsNonInteractive; subprocess route. NOT probed (state-changing). | *inferred* — not probed (side effects) |
| 25 | `/design-login` | jsx | D | Authorize design-system access | **blocked** | Interactive OAuth; binary explicitly says it requires an interactive terminal. | **probed** — UI-ONLY |
| 26 | `/design-revoke` | loc | ? | Revoke Claude agent access to Design projects | **bridgeable** | Same as design-consent. NOT probed (state-changing). | *inferred* — not probed (side effects) |
| 27 | `/desktop` | jsx | D | Continue the session in Claude Desktop | **blocked** | Hands the live session to a GUI app. | **probed** — UI-ONLY |
| 28 | `/diff` | jsx | D | View uncommitted changes and per-turn diffs | **native** | Bash `git diff`; per-turn diffs are in the transcript. | **probed** — UI-ONLY |
| 29 | `/effort` | loc+jsx | C | Set effort level for model usage | **bridgeable** | Cannot change own live effort; subagent frontmatter `effort:` and settings.json do set it. | **probed** — OK |
| 30 | `/exit` | loc+jsx | D | Exit the session | **blocked** | Probe returns UI-only despite an ungated `supportsNonInteractive` twin (see anomalies). | **probed** — UI-ONLY |
| 31 | `/export` | jsx | D | Export the conversation to a file or clipboard | **native** | Read the session JSONL under `~/.claude/projects/<slug>/` directly. | **probed** — UI-ONLY |
| 32 | `/extra-usage` | loc+jsx | C | (renamed) redirects to /usage-credits | **pointless** | Deprecated alias; prints a redirect notice. | **probed** — OK |
| 33 | `/fast` | loc+jsx | C | Toggle fast mode | **blocked** | Headless twin dispatches but replies 'not available in the Agent SDK'. | **probed** — OK |
| 34 | `/feedback` | jsx | D | Send feedback to Anthropic | **pointless** | Human-to-vendor channel. | **probed** — UI-ONLY |
| 35 | `/focus` | jsx | D | Toggle focus view | **pointless** | Pure TUI display mode. | **probed** — UI-ONLY |
| 36 | `/fork` | jsx | D | Spawn a background agent inheriting the conversation | **native** | Agent tool with `subagent_type: "fork"`. | **probed** — UI-ONLY |
| 37 | `/goal` | loc+jsx | C | Set a goal Claude checks before stopping | **bridgeable** | Its whole implementation is a session Stop hook of type `prompt`; skills may declare `hooks:` in frontmatter, so invoking a skill installs a goal (verified by prior work in this box, 12 autonomous turns). | **probed** — OK |
| 38 | `/heapdump` | loc | ? | Dump the JS heap to ~/Desktop | **pointless** | A subprocess dumps the SUBPROCESS's heap. NOT probed (writes to ~/Desktop). | *inferred* — not probed (side effects) |
| 39 | `/help` | jsx | D | Show help and available commands | **native** | The command list is static; this document is the better answer. | **probed** — UI-ONLY |
| 40 | `/hooks` | jsx | D | View hook configurations | **native** | Read `~/.claude/settings.json` / project settings. | **probed** — UI-ONLY |
| 41 | `/ide` | jsx | D | Manage IDE integrations and show status | **blocked** | Talks to an attached IDE extension over the live session's channel. | **probed** — UI-ONLY |
| 42 | `/import` | loc+jsx | D | Import config from another AI coding agent | **native** | Twin gated off by statsig `tengu_import`; but reading a codex/gemini config and writing settings.json is plain file work. | **probed** — UI-ONLY |
| 43 | `/init` | prm | A | Initialize CLAUDE.md with codebase documentation | **native** | `type:"prompt"` — a Skill; the model invokes it directly. | read-from-binary + live Skill listing |
| 44 | `/insights` | prm | A | Generate a report analyzing your sessions | **native** | `type:"prompt"` — a Skill. | read-from-binary + live Skill listing |
| 45 | `/install` | jsx | D | Install the Claude Code native build | **blocked** | Probe: `Unknown command` headless. Installer is interactive. | **probed** — UNKNOWN |
| 46 | `/install-github-app` | jsx | D | Set up Claude GitHub Actions for a repo | **blocked** | Interactive OAuth + repo picker. | **probed** — UI-ONLY |
| 47 | `/install-slack-app` | loc | D | Install the Claude Slack app | **blocked** | `supportsNonInteractive:!1`; interactive install. | **probed** — UI-ONLY |
| 48 | `/keybindings` | loc | D | Open your keyboard shortcuts file | **native** | Read/Write `~/.claude/keybindings.json`; `keybindings-help` skill is Tier A. | **probed** — UI-ONLY |
| 49 | `/login` | jsx | D | Sign in / switch Anthropic accounts | **blocked** | Must stay human-in-the-loop. | **probed** — UI-ONLY |
| 50 | `/logout` | jsx | D | Sign out | **blocked** | Credential mutation; HIL. | **probed** — UI-ONLY |
| 51 | `/loops` | jsx | D | List, create, and delete loops | **native** | `CronCreate` / `ScheduleWakeup` are plain model-facing tools; `loop` is a Tier-A skill. | **probed** — UI-ONLY |
| 52 | `/mcp` | loc+jsx | C | Manage MCP servers | **bridgeable** | Headless twin reports server status; durable enable/disable is a `.mcp.json` / settings write. Reconnect affects only the subprocess. | **probed** — OK |
| 53 | `/memory` | jsx | D | Open a memory file in your editor | **native** | Read/Write CLAUDE.md and `~/.claude/projects/*/memory/`. | **probed** — UI-ONLY |
| 54 | `/mobile` | jsx | D | Show QR code to download the mobile app | **pointless** | QR code for a human. | **probed** — UI-ONLY |
| 55 | `/model` | loc+jsx | C | Set the AI model for Claude Code | **bridgeable** | Cannot change own live model; the Agent tool's `model` param and settings.json do. Headless twin also prints the available-model list. | **probed** — OK |
| 56 | `/output-style` | jsx* | D | (deprecated) moved to /config | **pointless** | Deprecation stub, gated off by statsig `tengu_maple_sundial`. | **probed** — UI-ONLY |
| 57 | `/passes` | jsx | D | Share a free week of Claude Code | **pointless** | Referral flow. | **probed** — UI-ONLY |
| 58 | `/pause-memory` | loc | D | Pause automemory for this session | **blocked** | `isEnabled:()=>!1` — hard-disabled in this build. | **probed** — UI-ONLY |
| 59 | `/permissions` | jsx | D | Manage allow/deny tool permission rules | **native** | Read/Write settings.json; `update-config` skill is Tier A. | **probed** — UI-ONLY |
| 60 | `/plan` | jsx | D | Enable plan mode or view the session plan | **blocked** | Entering plan mode is a live-session mode switch (only ExitPlanMode is model-facing). | **probed** — UI-ONLY |
| 61 | `/plugin` | jsx | D | Manage Claude Code plugins | **bridgeable** | Plugin config is on disk and writable; activating changes in the LIVE session needs /reload-plugins, which is blocked. | **probed** — UI-ONLY |
| 62 | `/powerup` | jsx | D | Interactive feature lessons | **pointless** | Tutorial for a human. | **probed** — UI-ONLY |
| 63 | `/privacy-settings` | jsx | D | View and update privacy settings | **blocked** | Account-level consent UI. | **probed** — UI-ONLY |
| 64 | `/pro-trial-expired` | jsx | D | Options shown when the Pro trial ends | **pointless** | Upsell panel. | **probed** — UI-ONLY |
| 65 | `/radio` | loc | D | Listen to Claude FM lo-fi radio | **pointless** | Opens a browser to a stream. | **probed** — UI-ONLY |
| 66 | `/rate-limit-options` | jsx | D | Options shown when rate limit is reached | **pointless** | Upsell panel. | **probed** — UI-ONLY |
| 67 | `/recap` | loc | C | Generate a one-line session recap | **native** | Read the session's own JSONL and summarise; the headless twin sees an empty subprocess. | **probed** — OK |
| 68 | `/release-notes` | jsx | D | View release notes | **native** | Read the local release index / WebFetch the changelog. | **probed** — UI-ONLY |
| 69 | `/reload-plugins` | loc | D | Activate pending plugin changes | **blocked** | `supportsNonInteractive:!1`; live-session-only effect. | **probed** — UI-ONLY |
| 70 | `/reload-skills` | loc | C | Pick up skills changed on disk | **blocked** | Headless twin reloads the SUBPROCESS's skills (measured: 'Reloaded skills: 137'). Caller's set is untouched. | **probed** — OK |
| 71 | `/remote-control` | jsx | D | Control this session from your phone | **blocked** | Pairs the live session to a remote controller. | **probed** — UI-ONLY |
| 72 | `/remote-env` | jsx | D | Choose the default environment for cloud agents | **bridgeable** | A persisted preference — writable in config. | **probed** — UI-ONLY |
| 73 | `/rename` | loc+jsx | C | Rename the current conversation | **bridgeable** | `claude-rename-chat-title` writes a sentinel a UserPromptSubmit hook consumes, so a session can title itself. | **probed** — OK |
| 74 | `/resume` | jsx | D | Resume a previous conversation | **blocked** | Interactive session picker. | **probed** — UI-ONLY |
| 75 | `/review` | prm | A | Review a GitHub pull request | **native** | `type:"prompt"` — a Skill. | read-from-binary + live Skill listing |
| 76 | `/rewind` | loc | D | Restore code and/or conversation to an earlier point | **blocked** | `supportsNonInteractive:!1`; conversation rewind is live-session-only (code side is `git`). | **probed** — UI-ONLY |
| 77 | `/sandbox` | jsx | D | View and configure sandbox settings | **native** | Sandbox config lives in settings.json — Read/Write it. | **probed** — UI-ONLY |
| 78 | `/schedule` | loc*+prm | A | Create and manage scheduled remote agents | **native** | Bundled skill (Tier A); the model invokes it via the Skill tool. | read-from-binary + live Skill listing |
| 79 | `/scroll-speed` | jsx | D | Adjust mouse wheel scroll speed | **pointless** | TUI preference. | **probed** — UI-ONLY |
| 80 | `/session` | jsx | D | Show cloud session URL and QR code | **blocked** | Live remote-session identity. | **probed** — UI-ONLY |
| 81 | `/setup-bedrock` | jsx | D | Reconfigure Amazon Bedrock auth/region/models | **blocked** | Interactive credential wizard. | **probed** — UI-ONLY |
| 82 | `/setup-vertex` | jsx | D | Reconfigure Google Vertex auth/project/region | **blocked** | Interactive credential wizard. | **probed** — UI-ONLY |
| 83 | `/skill-doctor` | loc+jsx | D | Show which loaded skills are unused and costing context | **blocked** | Probe: `Unknown command` headless (see anomalies). Needs the live session's loaded-skill accounting. | **probed** — UNKNOWN |
| 84 | `/skills` | jsx | D | List available skills | **native** | The Skill-tool listing is already in the model's context. | **probed** — UI-ONLY |
| 85 | `/status` | jsx | D | Show version, model, account, connectivity, tool status | **bridgeable** | Assemble the equivalent from `claude --version`, `~/.claude.json`, and a `claude -p '/model'` / `'/mcp'` subprocess. | **probed** — UI-ONLY |
| 86 | `/statusline` | prm | A | Set up the status line UI | **native** | `type:"prompt"` — a Skill. | read-from-binary + live Skill listing |
| 87 | `/stickers` | loc | D | Order Claude Code stickers | **pointless** | Merch form. | **probed** — UI-ONLY |
| 88 | `/stop` | loc+jsx | D | Stop this background session | **blocked** | `isEnabled:rs` — only registered when the session IS a backgrounded one. | **probed** — UI-ONLY |
| 89 | `/subtask` | jsx | D | Send a subagent off with your full context | **native** | Agent tool (`subagent_type: "fork"`) is exactly this. | **probed** — UI-ONLY |
| 90 | `/tasks` | jsx | D | View and manage everything running in the background | **native** | TaskList / BashOutput / `claude-code-list-tasks`. | **probed** — UI-ONLY |
| 91 | `/team-onboarding` | prm | A | Help teammates ramp on Claude Code | **native** | `type:"prompt"` — a Skill. | read-from-binary + live Skill listing |
| 92 | `/teleport` | jsx | D | Resume a Claude Code session from claude.ai | **blocked** | Cross-surface session handoff. | **probed** — UI-ONLY |
| 93 | `/terminal-setup` | jsx | D | Configure terminal key bindings / bell | **blocked** | Mutates the terminal emulator's own config. | **probed** — UI-ONLY |
| 94 | `/theme` | jsx | D | Change the theme | **pointless** | Cosmetic. | **probed** — UI-ONLY |
| 95 | `/tui` | jsx | D | Set the terminal UI renderer | **pointless** | Cosmetic. | **probed** — UI-ONLY |
| 96 | `/ultraplan` | jsx | D | Draft an editable plan in Claude Code on the web | **blocked** | No enabled headless twin; the `local` registration is a C4E upsell stub with `supportsNonInteractive:!1`. | **probed** — UI-ONLY |
| 97 | `/ultrareview` | loc+jsx | C | Find and verify bugs in your branch via CC on the web | **bridgeable** | Real headless twin (`isEnabled:()=>_n()&&hee()`); dispatched in probe, refused only for want of a git repo. Run `claude -p '/ultrareview'` from a repo. | **probed** — OK |
| 98 | `/update` | loc | ? | Switch to the latest version | **bridgeable** | `isEnabled:()=>!1` in-session, but the updater is reachable from Bash. NOT probed (would relaunch). | *inferred* — not probed (side effects) |
| 99 | `/upgrade` | jsx | D | Upgrade to Max for higher limits | **pointless** | Billing upsell. | **probed** — UI-ONLY |
| 100 | `/usage` | loc+jsx | C | Show session cost, plan usage, and limit contributors | **bridgeable** | The best win: the PLAN-usage half is ACCOUNT-global, so a subprocess's answer is true for the caller (measured 'Current session: 44% used · resets Jul 28'). | **probed** — OK |
| 101 | `/usage-credits` | loc+jsx | C | Configure usage credits / request from admin | **pointless** | Headless twin just prints a claude.ai URL. | **probed** — OK |
| 102 | `/version` | loc+jsx | D | Print the version this session is running | **native** | Bash `claude --version`. In-session twin is `isEnabled:()=>!1`; probe returns `Unknown command`. | **probed** — UNKNOWN |
| 103 | `/vim` | jsx* | D | (deprecated) moved to /config | **pointless** | Deprecation stub, gated off by statsig `tengu_maple_sundial`. | **probed** — UI-ONLY |
| 104 | `/voice` | loc | D | Toggle voice mode | **pointless** | Needs a microphone; `supportsNonInteractive:!1`. | **probed** — UI-ONLY |
| 105 | `/web-setup` | jsx | D | Set up Claude Code on the web with GitHub | **blocked** | Interactive OAuth. | **probed** — UI-ONLY |
| 106 | `/wellbeing` | jsx | D | Configure break reminders and quiet hours | **pointless** | Nudges for a human. | **probed** — UI-ONLY |
| 107 | `/workflow-launch-exec` | loc | C | Execute a server-launched workflow handoff | **pointless** | Only fires for `workflow_launch` event sessions. | **probed** — OK |
| 108 | `/workflows` | jsx | D | Browse running and completed workflows | **native** | Workflow commands are constructed as `type:"prompt"` — they appear to the model as skills. | **probed** — UI-ONLY |

## 2. Autonomy verdicts

| Verdict | Count | Share | Meaning |
|---|---:|---:|---|
| `native` | 31 | 29 % | A model-facing tool or a plain file read/write already produces the effect. Nothing to build. |
| `bridgeable` | 15 | 14 % | Reachable, but only via a concrete mechanism named in the table (subprocess / hook / settings write). |
| `blocked` | 37 | 34 % | Needs the interactive UI, or mutates live-session state a subprocess cannot touch. |
| `pointless` | 25 | 23 % | Cosmetic, merch, upsell, human-nudge, or remote-session-only. Nothing for an agent to gain. |

### The distinction that decides the whole question: a subprocess is a different session

21 commands are headless-reachable. That number flatters the idea, because
`claude -p "/cmd"` runs in a **fresh, throwaway session**. Split the 21 by whether the
subprocess's answer or effect is true for the *caller*:

**Transfers to the caller (9)** — account-, config-, or repo-scoped:
`/usage` · `/usage-credits` · `/extra-usage` · `/config` · `/model` (the available-model list) ·
`/mcp` (configured-server list) · `/design` · `/agents` · `/ultrareview`

**Does not transfer (10)** — the subprocess acts on itself:
`/context` · `/clear` · `/compact` · `/color` · `/effort` · `/fast` · `/goal` · `/recap` ·
`/reload-skills` · `/rename`

**Remote-session-only (2)**: `/__remote-workflow` · `/workflow-launch-exec`

Two measurements make the middle column concrete rather than theoretical:

- `/context` in a subprocess reported **`Tokens: 24.9k / 200k (12%)`** — the subprocess's own
  context, not the caller's. A skill offering "run `/context` to see your context usage" would
  hand Claude a confidently wrong number.
- `/reload-skills` reported **`Reloaded skills: 137 skills available`** — it reloaded the
  subprocess's skill set and exited. The caller's set is untouched.

These are exactly the commands an agent would most want (how full is my context? re-read my
skills? compact myself?), and they are precisely the ones the bridge cannot deliver. The
mechanism is generic; the *value* is not.

### What's left that is both unique and useful

Of the 9 that transfer, subtract those already reachable natively — `/config` (settings.json is
a file), `/mcp` (servers are in the tool list and `.mcp.json`), `/model`'s list (static),
`/agents` (a fixed removal notice), `/usage-credits` + `/extra-usage` (they print a URL) — and
those that should stay human-in-the-loop (`/design consent|revoke` grants account access), and
the residue is:

- **`/usage`** — plan-usage percentages and reset times, not readable any other way from the
  filesystem. Measured: `Current session: 59% used · resets Jul 28 at 2:40am · Current week
  (all models): 69% used · Current week (Fable): 5% used`. It read **44 %** early in this
  investigation and **59 %** an hour later, having tracked the quota this very session burned —
  which is the proof that the figure is account-global and therefore genuinely true for the
  caller, not an artefact of the subprocess.
- **`/ultrareview`** — dispatches a cloud review of the current branch. Real, but heavyweight,
  and it needs a git repo (the probe was refused: *"`/private/tmp` is not inside
  one"*), so it must be invoked with the repo as cwd.

**One clearly valuable command, one heavyweight one.**

## 3. Would an umbrella skill work?

Mechanically, partly. As an investment, no.

**What would work.** A single skill *can* enumerate all 108 and *can* carry one generic helper
that shells out to `claude -p "/cmd"`. That helper is ~10 lines, costs $0.00 per call, and
covers every reachable command. There is no per-command work needed for the subprocess tier.

**What would not work.**

1. **The bridgeable tier does not factor.** 15 commands, and the generic subprocess mechanism
   is the *actual* bridge for only 7 (`/usage`, `/mcp`, `/ultrareview`, `/design`, `/model`'s
   list, and — inferred, not probed — `/design-consent` + `/design-revoke`). For the other 8 the subprocess
   runs the command against the wrong session, so the real bridge is something else and
   individually shaped: `/goal` is a `Stop` hook declared in skill frontmatter; `/rename` is a
   sentinel file plus a `UserPromptSubmit` hook; `/effort` and `/model` are settable only for
   *subagents*, via Agent-tool parameters, never for the live session; `/plugin` is writable on
   disk but needs `/reload-plugins` — which is blocked — to take effect. Each is bespoke, and
   several already have dedicated tooling elsewhere in the estate
   (`claude-rename-chat-title`; `CronCreate`/`ScheduleWakeup` for `/loops`).
2. **The skill would be 60 % filler.** 37 `blocked` + 25 `pointless` = 62 of 108 rows whose
   entire content is "you cannot" or "don't bother". Another 31 are `native` — telling Claude
   to use the Agent tool for `/subtask`, `git diff` for `/diff`, `pbcopy` for `/copy`. That is
   a reference table, not a capability.
3. **It would go stale silently and in the dangerous direction.** The registry is compiled into
   the binary; 2.1.217→2.1.220 are four releases in a week. A stale row that says "blocked" is
   harmless. A stale row that says "run `claude -p '/X'`" becomes a command Claude runs and
   misreads. And per the table above, a statically-generated skill starts 22–28 % wrong on
   day one.
4. **Loaded-context cost against near-zero behaviour change.** The net new capability is
   `/usage` plus a heavyweight `/ultrareview`. Everything else is either already available or
   genuinely unreachable.

**Where the effort/value cliff sits.** It is very sharp, and it sits after the *first* command.
A `claude -p '/usage'` wrapper is roughly an hour including tests and delivers the one unique
capability. Extending to "all reachable commands" costs several times that and delivers
`/ultrareview` plus a set of session-scoped commands that report the wrong session. Extending
to "all 108 with per-command bridges" is days of work, most of it documenting impossibility.

## 4. Recommendation

**Don't build the umbrella skill.** Build a subset — arguably a subset of one — and keep this
file as the reference.

Justified by the numbers: of 108 commands, **29 % are already native** (no skill needed),
**23 % are pointless** for an agent, **34 % are blocked**, and of the **14 % bridgeable** the
generic mechanism reaches only 7. After removing the ones whose subprocess answer is about the
wrong session, and the ones already reachable by reading a file, the umbrella's unique
contribution is **`/usage`** and **`/ultrareview`** — two commands out of 108, or **under 2 %**.

Concretely:

1. **Do** — keep this document as the reference (it is the answer to "can Claude invoke /X?",
   and answering that from scratch costs a binary rescan plus ~200 probes). Per
   `documentation-doctrine`, a 108-row lookup table is reference material, not an always-loaded
   skill.
2. **Consider** — a small `claude -p '/usage'` helper, if plan-usage visibility is actually
   wanted mid-session. Check first whether `~/dev/claude-usage-fetch` or the `context-gauge`
   skill already covers it; the estate rule is don't default to greenfield. If built, it is a
   helper with a test, not a skill.
3. **Don't** — generate a skill from a static scan of the binary. Section "supportsNonInteractive
   is not a reliable predictor" is the specific reason: it would be wrong about a fifth to a quarter of
   what it claims, silently, and would drift further every release.
4. **Revisit if** — Anthropic ships a model-facing `SlashCommand` tool. That single change
   would move most of Tier D into reach and make an umbrella worth having. It does not exist in
   2.1.220; a one-line check (`ccstr '"SlashCommand"'`) re-tests it on any new build.

## Reproducing on a new version

```bash
V=~/.local/share/claude/versions/<new-version>
strings -a -n 6 "$V" > /tmp/cc-strings.txt
./bin/ccstr 'type:"local-jsx"' --window 200      # confirm the object shape still holds
./bin/ccstr '"SlashCommand"'                     # 0 hits = no generic model-facing bridge yet
```

Then rescan anchoring on `type:"…"` in **any** key position (not `{type:"…"` — that is the bug
that cost the prior doc six commands), and re-probe. The probe loop must close stdin:

```bash
claude -p "/$name" --model claude-haiku-4-5 --output-format json </dev/null
```

Classify on the result string: real output = reachable; `isn't available in this environment` =
registered but headless-filtered; `Unknown command` = absent from the registry in this mode.

## Noticed but out of scope

- **`~/dev/claude-code-goal-and-loop-self-direction/CLAUDE.md` carries a burn note that expires
  2026-08-10**, owned by session `1071d9d5`. Untouched here.
- **The box directory is not a trusted Claude Code workspace** (`hasTrustDialogAccepted: false`
  in `~/.claude.json`), which is why all probes ran from `/private/tmp`. Worth
  accepting trust if headless probes become routine here.
- **The account-`b` credential slot referenced by the box's CLAUDE.md resume line is empty**
  (`~/.claude-<credential-slot>` contains no credential files), so probes ran on the default
  account. If the box is meant to bill account `b`, that binding is currently broken.
- **`/agents` is gone as a wizard** — its headless twin now returns only a notice pointing at
  `.claude/agents/`. Any estate doc still describing `/agents` as an interactive editor is
  stale.
- **Six commands are Claude-for-Enterprise upsell stubs** (`gyr` factory: `/ultraplan`,
  `/ultrareview`, `/teleport`, `/remote-control`, `/schedule`, `/autofix-pr`), hidden and
  disabled unless the account is API-key-based. They are invisible on a subscription account,
  which is a plausible source of confusion when comparing command lists across accounts.
- **`/vim` and `/output-style` are deprecation stubs** gated behind statsig
  `tengu_maple_sundial` (default off) that say "moved to /config". They will start appearing
  when that flag flips.
