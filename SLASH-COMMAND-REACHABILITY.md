# Which slash commands can Claude reach internally? — CC **2.1.220**

> ## ⚠️ CORRECTED 2026-07-28 — read this before the numbers below
>
> A dedicated follow-up pass ([`UMBRELLA-FEASIBILITY.md`](UMBRELLA-FEASIBILITY.md), 196 probe
> runs) falsified three claims in this file. They are corrected inline, but the headline:
>
> | This file originally said | Actually |
> |---|---|
> | **101** commands | **108** — the scan anchored on `{type:"` and missed six objects that put `description:`/`name:`/`aliases:` first (`/bug`, `/chrome`, `/keybindings`, `/release-notes`, `/rewind`, `/sandbox`), plus `/vim` + `/output-style` (factory-built) and `/schedule` |
> | **18** dual-registered | **20** (`/config` and `/context` also carry both) |
> | `supportsNonInteractive` marks the headless-capable set | **`isEnabled` is the real gate, and it evaluates at RUNTIME.** Predicting from the flag alone is **28% wrong** (8/29) |
>
> Concretely: **`/version` and `/skill-doctor` are NOT reachable** despite carrying the flag —
> `/version` is `isEnabled:()=>!1`, hardcoded false (verified independently). And
> `/ultraplan`, `/teleport`, `/remote-control`, `/schedule`, `/autofix-pr` expose only a hidden
> Claude-for-Enterprise upsell stub with `supportsNonInteractive:!1`, so counting them as
> headless paths mis-tiers all five.
>
> The authoritative mechanism is `WUe()`: headless admits `prompt` commands plus `local`
> commands carrying `supportsNonInteractive`; **`local-jsx` is excluded wholesale.**
>
> **The lesson, since it generalizes:** a static scan of a registration shape predicted
> reachability 28% wrong, because the real gate is a *function evaluated at runtime*. Reading
> the declared flag is not reading the behaviour.

Version-pinned by construction: the registry is compiled into the binary and drifts every
release. Re-run the extractor (below) against a new build rather than trusting this list.

## Method, and its limits

Command objects are compiled as JS literals of the shape
`{type:"...",name:"...",description:"..."}`. `bin/ccstr` + a `str.find` scan over a
`strings -a` dump of `~/.local/share/claude/versions/2.1.220` yields **101 distinct command
names** across four registration shapes.

**What is verified vs. inferred.** The registration *types* are read directly from the
binary — that part is solid. Reachability was empirically tested for `/goal` only
(headless probe, below). The other 100 are classified by registration shape, which is
strong evidence but not a per-command test. Treat Tier C/D membership as "the binary says
so", not "I ran it."

One shape is deliberately under-counted: only **7** literal `{type:"prompt"}` objects exist,
because bundled skills (`loop`, `schedule`, `simplify`, `run`, …) are *constructed at load
time* by the skill loader (`return {type:"prompt", name:e, …}`), not written as literals. So
**the authoritative list of model-invocable commands is the live Skill-tool listing, not this
scan.** The scan is authoritative for everything else.

## The four tiers

### Tier A — the model invokes it directly

Anything registered `type:"prompt"` becomes a Skill, and the Skill tool is model-facing.
These are ordinary instructions the model follows; nothing special about them.

Read the session's own skill listing for the current set — it includes `loop`, `schedule`,
`simplify`, `run`, `init`, `review`, `security-review`, `update-config`, `claude-api`,
`dataviz`, and the artifact skills, among others.

### Tier B — model cannot invoke the command, but *can* reach the same destination

The interesting tier, and the one the question was really about. The command is UI-side, but
the effect it produces is not privileged — it is reachable through ordinary model-facing
tools.

| Command | Model-facing route to the same destination |
|---|---|
| `/loop` | The `loop` skill is itself Tier A, but you can skip it: `CronCreate` (interval mode) and `ScheduleWakeup` (dynamic mode) are plain tools. `/loop` is only instructions over them. |
| `/goal` | Register a `Stop` hook of `type:"prompt"` — which is `/goal`'s entire implementation. Skills may declare `hooks:` in frontmatter, so **invoking a skill installs a goal**. Verified: drove 12 autonomous turns. Caveat: a skill-set goal carries a `skillRoot`, and `/goal clear` deliberately skips those, so it has no UI off switch. |
| `/rename` | `claude-rename-chat-title` writes a sentinel a `UserPromptSubmit` hook consumes — a session can title itself. |
| `/context`, `/status` | Read the same state from `~/.claude/` and the session transcript. |

**The generalisable rule:** before concluding the model can't do something a slash command
does, check whether the command is *doing* anything privileged or merely *orchestrating*
tools the model already has. `/loop` is pure orchestration. `/goal` is one hook registration.
Neither is gated.

### Tier C — headless-capable, but not model-invocable in-session (18)

These carry **both** a `local-jsx` and a `local` registration; the `local` twin sets
`supportsNonInteractive: true`, so `claude -p "/cmd …"` works. A model cannot call them in
its own session, but a *subprocess* it spawns can.

```
/auto-mode-setup  /autocompact  /color   /effort   /exit    /extra-usage
/fast             /goal         /import  /mcp      /model   /rename
/skill-doctor     /stop         /ultrareview        /usage
/usage-credits    /version
```

**Verified for `/goal`:** `claude -p "/goal say BANANA then stop"` → `num_turns 1`,
result `BANANA`, and **two models in `modelUsage`** (driver + the Haiku evaluator) — proving
the goal was both set and evaluated in headless mode.

> ⚠️ This corrects an earlier claim in `FINDINGS.md` that `/goal` is "local-jsx, so
> unreachable." That was true of the *interactive* registration and missed the
> `goalNonInteractive` twin. The in-session conclusion is unchanged — the model still cannot
> type `/goal` — but "no non-interactive path exists" was wrong.

### Tier D — genuinely UI-only (56)

Pure `local-jsx`, no `local` twin, no headless path. Mostly things that are inherently
interactive (`/login`, `/theme`, `/resume`, `/permissions`, `/help`, `/ide`, `/plan`) or that
render a panel (`/workflows`, `/artifacts`, `/status`).

Plus **20 `local`-only** commands (`/clear`, `/compact`, `/config`, `/context`, `/agents`,
`/recap`, `/update`, …) — non-interactive-capable but with no UI component.

## Reproducing this on a new version

```bash
V=~/.local/share/claude/versions/<new-version>
strings -a -n 6 "$V" > /tmp/cc-strings.txt
./bin/ccstr 'name:"goal"' --window 400        # confirm the object shape still holds
```

Then re-run the tier scan (the `python3` block in this box's session log). **Check the
object shape first** — if Anthropic changes how commands are registered, a scan that finds
"0 commands" looks identical to a scan that ran correctly against a build with none.

## Open

- Tier C membership is untested beyond `/goal`. If any specific command matters, probe it —
  one `claude -p` run settles it (`claude-self-review` § "Mode zero").
- No `SlashCommand`-style tool exists in 2.1.220's model-facing tool set, which is what makes
  Tier B necessary. If one ever ships, Tiers B and C collapse into A.
