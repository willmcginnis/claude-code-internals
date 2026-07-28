# Experiments — raw record

Fixtures and unedited results behind [`../FINDINGS.md`](../FINDINGS.md) §4. Run against
Claude Code **2.1.220** on 2026-07-27, driver pinned to `claude-haiku-4-5`.

## `settings-goal/` — Stop prompt hook from a settings file

Proves the embedded docs' "prompt hooks are tool-events-only" line is stale: a `Stop` hook of
`type: "prompt"` loads from a settings file and blocks stopping.

```bash
claude -p "Say exactly: hello there. Nothing else." --model claude-haiku-4-5 \
  --settings experiments/settings-goal/stop-prompt-hook.settings.json --output-format json
```

| File | `num_turns` | result | note |
|---|---|---|---|
| `run-notmet-1turn.json` | 1 | `hello there.` | evaluator fired once, did not block |
| `run-notmet-10turns.json` | 10 | `''` | evaluator fired ~10×, blocked 9 extra turns |

Same config, opposite outcomes — the evaluator is a model judgement, not a predicate. Treat
single runs as anecdote.

## `skill-goal/` — Stop prompt hook from **skill frontmatter**

The self-direction case: no user typed `/goal`, the *model* invoked a skill and the skill's
frontmatter installed the completion condition.

```bash
cd experiments/skill-goal
claude -p "Use the goal-selftest skill." --model claude-haiku-4-5 --output-format json
```

| Skill | `num_turns` | result | evaluator calls |
|---|---|---|---|
| `goal-selftest` (condition not met) | 12 | `''` | ~10 |
| `goal-selftest-met` (met on turn 1) | 3 | `BANANA` | 1 |

## Reading the JSON

`modelUsage` is the load-bearing field. Two distinct model entries means the evaluator ran as
a separate call; its `cacheCreationInputTokens` scales with transcript × turn count, so it is
the cheapest way to count how many times the hook fired.

```bash
python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
print(d['num_turns'], repr(d['result'])[:80])
for m,u in d['modelUsage'].items(): print(' ',m,u['outputTokens'],u['cacheCreationInputTokens'])
" run-met-3turns.json
```

## Gotchas that cost time

- **Untrusted workspace fails silently.** First attempts ran in `$TMPDIR`: exit 0, empty
  stdout, no hook, no error. Project settings and hooks are dropped in untrusted directories.
  Run from a trusted tree.
- **Plain `-p` hides the evidence.** A blocked goal loop ends with an empty result, which is
  indistinguishable from a crash. Use `--output-format json`.
- **`--debug` did not surface hook lines** on stderr in headless mode, despite the binary
  containing `Hooks: Processing prompt hook with prompt: …` and friends. The JSON usage
  numbers were the only reliable signal.
