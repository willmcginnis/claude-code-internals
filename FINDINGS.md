# Can Claude Code set its own `/goal` or `/loop`?

**Short answer: yes to both — but by different routes, and only one of them is the route you'd guess.**

Investigated against the locally installed build, **Claude Code 2.1.220**
(`~/.local/share/claude/versions/2.1.220`, Mach-O arm64, Bun-compiled). Claims below are
from the shipped binary plus live headless runs on this machine, not from docs.

| | `/loop` | `/goal` |
|---|---|---|
| What it is | a **bundled skill** (instructions) | a **`local-jsx` command** (UI code) |
| Model can invoke the command itself? | **Yes** — it's in the Skill-tool listing | **No** — Claude cannot type `/goal` |
| Model can produce the *effect*? | Yes, trivially | **Yes** — via a skill-declared `Stop` prompt hook |
| Underlying machinery | `CronCreate` / `ScheduleWakeup` tools | session-scoped `Stop` hook, `type: "prompt"` |
| Who evaluates | nothing — fixed wall-clock | a second, cheap model (Haiku by default) |

The original hunch was **right about `/loop`** ("just one of those internal cron things")
and **half right about `/goal`** — the Haiku evaluator is real, but `/goal` is not a skill,
so the "ultracode is just instructions" shape does *not* describe it. The effect is still
reachable, through a mechanism that turns out to be more general than `/goal` itself.

---

## 1. `/loop` — instructions over two ordinary tools

`/loop` is a bundled skill. Its whole job is to tell the model which tool to call:

```
Usage: /loop [interval] <prompt>
Run a prompt or slash command on a recurring interval.
Intervals: Ns, Nm, Nh, Nd (e.g. 5m, 30m, 2h, 1d). Minimum granularity is 1 minute.
```

Two modes, and the skill body is a decision between them:

**Interval mode** (`/loop 5m /babysit-prs`) → the skill instructs:

> 1. Convert `<interval>` … 2. … with:
>    - `cron`: the expression from step 1
>    - `prompt`: the literal string `<<loop.md>>`
>    - `recurring`: `true`
> 3. Briefly confirm … 4. **Then immediately run … now** … Don't wait for the first cron fire.

**Dynamic mode** (`/loop <prompt>`, no interval — "let the model self-pace") → the skill
instructs the model to call `ScheduleWakeup` with `delaySeconds` / `prompt` / `reason`
before ending each turn, and `stop: true` to end the loop.

Both `CronCreate` and `ScheduleWakeup` are **ordinary tools already exposed to the model**.
Nothing gates them behind the slash command. So Claude has three self-direction routes here,
in increasing directness:

1. `Skill(skill: "loop")` — the model invoking the same skill the user's `/loop` invokes.
2. `CronCreate({cron: "*/5 * * * *", prompt: "...", recurring: true})` — skip the skill.
3. `ScheduleWakeup({delaySeconds: 1200, prompt: "...", reason: "..."})` — self-paced.

### The sentinel trick

`CronCreate`'s `prompt` is not the user's text — it's a literal sentinel, one of
`<<loop.md>>`, `<<loop.md-dynamic>>`, `<<autonomous-loop>>`, `<<autonomous-loop-dynamic>>`.
Per the binary, it

> expands at fire time to the full loop.md contents on first delivery (and whenever loop.md
> has been edited since last fire), and to a short reminder on subsequent unchanged fires.
> The long instructions stay in the cached message-prefix.

That's a prompt-cache optimisation: the expensive instruction block is written once into the
cached prefix, and later fires cost only the reminder. Worth stealing as a pattern.

### Cron constraints that matter

From the live `CronCreate` schema:

- **Session-only.** "Jobs live only in this Claude session — nothing is written to disk, and
  the job is gone when Claude exits." The `durable` parameter exists but "has no effect."
- **Recurring jobs auto-expire after 7 days**, firing one final time.
- **Jobs only fire while the REPL is idle** (not mid-query).
- Deterministic jitter: recurring tasks fire up to 10% of period late (max 15 min).
- `ScheduleWakeup`'s `delaySeconds` is clamped to `[60, 3600]`.

---

## 2. `/goal` — a UI command wrapping a mechanism the model *can* reach

`/goal` is registered as a `local-jsx` slash command ("Set a goal Claude checks before
stopping", args `[<condition> | clear]`). `local-jsx` commands are React components executed
by the client — they are not prompt-expanding, so they never appear in the model's Skill
listing and **the model cannot invoke `/goal`**.

But the thing it *does* is small. De-minified from the binary:

```js
function Xdr(e, t) {                       // e = condition text
  let r = Yks(); if (r !== null) return …  // gates: trust + hooks-not-restricted
  let n = kt();                            // session id
  for (let i of Jdr(t.getAppState(), n))   // remove any existing goal hook
      t.sessionHooksRegistry.remove(n, "Stop", i);
  t.sessionHooksRegistry.add(n, "Stop", "", { type: "prompt", prompt: e });
  let o = { condition: e, iterations: 0, setAt: Date.now(), tokensAtStart: $E() };
  return t.setAppState(i => ({ ...i, activeGoal: o })), …
}
```

**`/goal` is one line of real work: register a session-scoped `Stop` hook of `type: "prompt"`
whose prompt is the condition.** Everything else is bookkeeping and UI.

On success it injects this directive into the conversation:

> A session-scoped Stop hook is now active with condition: "…". Briefly acknowledge the goal,
> then immediately start (or continue) working toward it — treat the condition itself as your
> directive and do not pause to ask the user what to do. The hook will block stopping until
> the condition holds. It auto-clears once the condition is met — do not tell the user to run
> `/goal clear` after success; that's only for clearing a goal early.

Other details from the binary:

- Condition length cap: **4000 characters**.
- Clear aliases: `clear`, `stop`, `off`, `reset`, `none`, `cancel`.
- Two gates, both hard: **trusted workspace**, and hooks not restricted
  (`disableAllHooks` / `allowManagedHooksOnly` in settings or policy).

### The evaluator (the "Haiku reviewer")

A `prompt` hook is evaluated by a separate model call. Its system prompt:

> You are evaluating a hook condition in Claude Code. Judge whether the user-provided
> condition is met. Your response must be a JSON object with one of these shapes:
> `{"ok": true, "reason": "…"}` / `{"ok": false, "reason": "…"}`

and for the `Stop` case the user message is:

> Based on the conversation transcript above, has the following stopping condition been
> satisfied? Answer based on transcript evidence only.

Which model? From the hook schema:

```js
model: E.string().optional().describe(
  'Model to use for this prompt hook (e.g., "claude-sonnet-5"). '
  + 'If not specified, uses the default small fast model.')
```

So Haiku is the **default, not a hard-wire** — a prompt hook may name its own evaluator model.
(The sibling `agent` hook type says "If not specified, uses Haiku" explicitly.)

The evaluator reads **only the transcript**. When it doesn't fit, the binary truncates and
instructs: *"if the required evidence may be in the omitted prefix, return `{"ok": false,
"reason": "insufficient evidence in transcript"}`"*. This is the mechanical reason a goal must
be phrased as something **demonstrable in surfaced output** — the existing
`claude-code-goal-command` skill already says this, and the binary confirms why.

There is also a "condition judged impossible" branch, which appears to be the anti-infinite-loop
escape (see the open question at the end).

---

## 3. The general mechanism: skills can declare hooks

This is the finding that makes `/goal` self-settable, and it is more useful than `/goal`.

The hooks settings schema is:

```js
voe = E.partialRecord(E.enum(cB), E.array(sLi()))
sLi = E.object({ matcher: E.string().optional(), hooks: E.array(Tql()) })
Tql = E.discriminatedUnion("type", [BashCommand, Prompt, Agent, Http, McpTool])
```

Note what is **absent**: any per-event restriction on hook type. Any of the five hook types is
valid on any event, including `Stop`.

> ⚠️ The docs embedded in the binary's own `update-config` skill claim prompt hooks are
> "Only available for tool events: PreToolUse, PostToolUse, PermissionRequest." **That line is
> stale.** It is contradicted by the schema above and by `/goal` itself, which registers a
> prompt hook on `Stop`. Verified false empirically in §4.

And the skill loader parses `hooks:` out of **skill frontmatter** with that same schema:

```js
if ((i || s.isSkillMode) && a.hooks) {
  let j = voe().safeParse(a.hooks);
  if (j.success) B = j.data;
  else w(`Invalid hooks in plugin skill '${e}': ${j.error.message}`);
}
…
hooks: B,
skillRoot: (i || s.isSkillMode) && B ? o : void 0,
```

So: **a skill can ship a `Stop` prompt hook in its frontmatter, and invoking that skill installs
a goal.** The Skill tool is model-invocable. That closes the loop.

### Gotcha: a skill-set goal is invisible to `/goal`

`/goal`'s own teardown selects only hooks with `matcher === "" && skillRoot === undefined`:

```js
function Jdr(e, t) {
  let r = [];
  for (let n of Rlt(e, t, "Stop").get("Stop") ?? []) {
    if (n.matcher !== "" || n.skillRoot !== void 0) continue;   // ← skips skill hooks
    for (let o of n.hooks) if (o.type === "prompt") r.push(o);
  }
  return r;
}
```

A skill-installed goal carries a `skillRoot`, so **`/goal clear` will not clear it**, bare
`/goal` will not report it, and the status indicator won't show it. Cuts both ways: your goal
survives a user's `/goal clear`, and the user has no obvious off switch. Ship an off switch.

---

## 4. Empirical verification

All runs headless on this machine, driver pinned to `claude-haiku-4-5` to keep cost down.
Fixtures in `experiments/`, raw JSON alongside them.

### 4a. Stop + prompt hook from a settings file

`--settings` pointing at a file containing a `Stop` → `type: "prompt"` hook, condition
*"The assistant has written the word BANANA in its visible response."*, prompt `"Say exactly:
hello there. Nothing else."` — i.e. a condition the driver will not satisfy on its own.

```
num_turns = 10        result = ''       cost = $0.133
  claude-haiku-4-5            in=90 out=1707  cacheCreate=991     ← driver
  claude-haiku-4-5-20251001   in=27 out=766   cacheCreate=52663   ← evaluator, ~10 calls
```

Two distinct model entries in `modelUsage` is the signature: the evaluator is a genuinely
separate call, and the ~52 k cache-creation tokens are the transcript being re-sent each Stop.
**The turn count proves the hook blocked stopping and drove 9 extra autonomous turns.**

*(A first run of the same config returned `num_turns = 1` with the evaluator firing once —
the evaluation is a model judgement and is not deterministic. Don't treat a single run as
proof of either outcome.)*

### 4b. Stop + prompt hook from **skill frontmatter** — the self-direction case

`experiments/skill-goal/.claude/skills/goal-selftest/SKILL.md`, invoked by the *model* with
`"Use the goal-selftest skill."`:

```
num_turns = 12        result = ''       cost = $0.256
  claude-haiku-4-5            in=99 out=1973  cacheCreate=59505
  claude-haiku-4-5-20251001   in=27 out=951   cacheCreate=55281   ← evaluator, ~10 calls
```

**This is the headline result.** No user typed `/goal`. The model invoked a skill; the skill's
frontmatter installed a `Stop` prompt hook; the session then looped autonomously under
Haiku-evaluated supervision.

### 4c. Control — condition satisfiable immediately

Identical hook, body changed to `Reply with exactly one word: BANANA`:

```
num_turns = 3         result = 'BANANA'  cost = $0.086
  claude-haiku-4-5            in=19 out=162   cacheCreate=34953
  claude-haiku-4-5-20251001   in=3  out=42    cacheCreate=5446    ← evaluator, ONE call
```

Evaluator ran **once**, returned met, did not block, session ended cleanly with the result.
The contrast against 4b (10 evaluator calls, empty result) isolates the blocking behaviour to
the evaluator's verdict rather than to anything else in the setup.

### Observed cost shape

The evaluator is cheap *per call* but re-reads the transcript every Stop, so its cost tracks
**transcript size × turn count**, not condition complexity. In 4b the evaluator cost
(~$0.070) slightly exceeded the driver's (~$0.063). On a real session with a large transcript
and an Opus driver the ratio flips, but the evaluator is not free — budget it.

### Reproduce

```bash
cd experiments/skill-goal
claude -p "Use the goal-selftest skill." --model claude-haiku-4-5 --output-format json
```

Two environment notes that cost time here:

- **The workspace must be trusted.** A first attempt in `$TMPDIR` silently produced empty
  output and exit 0 — no error, no hook, nothing. Untrusted directories drop project settings
  and hooks on the floor in headless mode. Run from a trusted tree, or pass `--settings`.
- **Use `--output-format json`.** Plain `-p` prints only the final result, and a blocked goal
  loop ends with an empty result — which looks identical to a crash. `num_turns` and
  `modelUsage` in the JSON are what actually tell you the hook fired.

---

## 5. Recipes

### Claude sets its own loop

```jsonc
// interval — same thing /loop 5m does
CronCreate({ cron: "*/5 * * * *", prompt: "<the work>", recurring: true })

// self-paced — same thing /loop with no interval does
ScheduleWakeup({ delaySeconds: 1200, prompt: "<the work>", reason: "watching CI run" })
```

Or `Skill(skill: "loop")` to get the full decision procedure. Note the CLAUDE.md standing
guidance already applies: don't schedule short-interval wakeups to poll harness-tracked work.

### Claude sets its own goal

Ship a skill whose frontmatter declares the condition:

```yaml
---
name: ship-it
description: Work until the test suite is green and the result has been shown.
hooks:
  Stop:
    - matcher: ""
      hooks:
        - type: prompt
          prompt: "`just check` has been run and its full output, showing zero failures, appears in the transcript."
          statusMessage: "checking just check is green"
---
Run `just check`, fix what it reports, and show the final output.
```

Then `Skill(skill: "ship-it")`. Constraints carried over from `/goal`, all confirmed above:

- The condition must be **checkable from surfaced transcript output alone** — the evaluator
  cannot run commands or read files.
- It must be **finishable without the human**, or the loop just spins.
- Trusted workspace + hooks enabled, or the hook silently never registers.
- **Provide an off switch** — `/goal clear` will not touch it (§3).

Useful knobs the `/goal` UI never exposes, all in the prompt-hook schema:

| Field | Use |
|---|---|
| `model` | evaluate with something stronger than Haiku for a subtle condition |
| `timeout` | seconds for the evaluation |
| `once` | intended to run-and-remove — but see the caveat below |
| `continueOnBlock` | sets `continue` on the `block` decision when `ok` is false |
| `statusMessage` | spinner text while evaluating |
| `if` | permission-rule syntax to filter when the hook runs |

**Caveat on `once: true`:** in run 4a the hook carried `once: true` and still fired ~10 times.
Whatever `once` removes, it did not survive re-derivation from the settings file each Stop.
Do not rely on it to bound a loop.

---

## 6. Provenance — who wrote what

- **`/goal` and `/loop` are Anthropic built-ins**, shipped in the Claude Code binary. `/goal`
  has existed since v2.1.139.
- **`~/.claude/skills/claude-code-goal-command` is ours.** Two commits, both 2026-07-03:
  `1bb7c14` "skill: seed for /goal command (points to AKB canonical page)" (18 lines, a seed
  pointing at the AKB canonical page) and `4641541` adding the "picking a good goal" guide.
  Authored in a session running Opus 4.8 per the commit trailer. It is a documentation seed —
  it does not implement anything.
- Its guidance holds up against the binary. The two load-bearing claims — evaluator sees only
  surfaced output, and a goal must be finishable without the human — are both confirmed
  mechanically above. Worth adding to it: the skill-frontmatter route, and that `/goal clear`
  does not clear a skill-set goal.

---

## 7. Round two — can Claude create a goal at *runtime*?

The §3 route bakes a **fixed** condition into a skill file at authoring time. That is create-and-read,
not CRUD. Round two asked whether Claude can install an *arbitrary* condition mid-session.

### Mid-session file writes do NOT take effect (verified)

| Test | Wrote the file? | Evaluator in `modelUsage`? |
|---|---|---|
| Claude writes `.claude/settings.local.json`, then stops | yes | **no** |
| Claude writes `.claude/settings.local.json`, works several turns, then stops | yes | **no** |
| Claude writes a skill with `hooks:` frontmatter, then invokes it | yes | **no** |
| *Control:* the same settings file present **at session start** | — | **yes** |

The control is the clincher — same bytes, only the timing differs. It ran the complete cycle for
the first time: hook blocked, reason fed back, Claude worked toward the condition, wrote BANANA,
evaluator returned met, session ended (`num_turns` 5, result *"…BANANA."*).

**Hooks and skills are enumerated at session start.** The binary does contain reload machinery —
`ConfigChange` / `FileChanged` hook events exist, and there are log strings for *"Plugin hooks:
reloading due to plugin-affecting settings change"* — but that reload path is scoped to **plugin**
hooks and did not pick up project settings or a new skill in any run here.

### The dynamic engine: a Stop **command** hook

A `command` hook computes its verdict by running a shell command **at Stop time**, so its decision
can depend on live filesystem state even though the hook itself is static:

```json
{"type": "command",
 "command": "if [ -f goal-satisfied.marker ]; then echo '{}'; else touch goal-satisfied.marker; echo '{\"decision\":\"block\",\"reason\":\"Goal not met yet: …\"}'; fi"}
```

```
num_turns = 2    result = "…BANANA\n\nI've included the word BANANA as specified in the goal."
MODELS: ['claude-haiku-4-5']          ← ONE model. No evaluator. Zero token cost.
```

First Stop blocked and fed the `reason` back; Claude complied; second Stop passed. This is the
only verified route to **runtime-variable** goal conditions, and it is free.

### Two engines, different jobs

| | Prompt hook (`/goal`'s engine) | Command hook |
|---|---|---|
| Judge | Haiku reading the transcript | shell running the real check |
| Condition | static, fixed at authoring time | dynamic, read from a file at run time |
| Cost | an evaluator call every Stop (~$0.07/run observed) | zero |
| Fails when | evidence isn't surfaced in the transcript | the condition isn't mechanically checkable |
| Best for | "the writeup reads clearly" | "`just check` exits 0" |

For anything mechanically checkable the command hook is **strictly better**: it runs the actual
check instead of inferring from transcript text, and it doesn't burn tokens to do it. Reserve the
Haiku evaluator for genuinely fuzzy conditions.

### Hook events actually supported

The binary's event enum is far larger than its own docs table (which lists 10):

```
PreToolUse  PostToolUse  PostToolUseFailure  PostToolBatch  PermissionRequest
PermissionDenied  Notification  UserPromptSubmit  UserPromptExpansion
SessionStart  SessionEnd  Stop  StopFailure  SubagentStart  SubagentStop
PreCompact  PostCompact  TeammateIdle  TaskCreated  TaskCompleted
Elicitation  ElicitationResult  ConfigChange  InstructionsLoaded
CwdChanged  FileChanged  DirectoryAdded  MessageDisplay
```

`TaskCompleted`, `FileChanged`, `SubagentStop` and `ConfigChange` all look useful for
agent-driven control loops and are undocumented in the shipped help text.

## Open questions

- **What terminated the not-met runs?** Both blocked runs ended after 10–12 turns with an
  empty result rather than running to a cap. The binary has a "Prompt hook condition judged
  impossible" branch, which is the plausible terminator, but I did not confirm that is what
  fired — the debug logging for it never surfaced on stderr in headless mode. If you intend to
  rely on goal loops running long, establish the real ceiling first.
- **Does a skill-installed `Stop` hook survive `--resume`?** `/goal`'s own hook does (it is
  restored from session state). A `skillRoot` hook's persistence across resume is untested.
- **`SubagentStop`** appears in the same evaluator code path, with a distinct prompt ("verify
  that the agent completed the given plan"). Per-subagent completion conditions look reachable
  by the same mechanism; not explored.
