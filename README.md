# claude-code-internals

Empirical findings about how Claude Code actually works, established by reading
the shipped binary and probing the running build -- not by reading the docs.

Each finding states its version, because this surface drifts every release.
Current pin: **2.1.220**.

## Contents

| File | What it establishes |
|---|---|
| [`FINDINGS.md`](FINDINGS.md) | How `/goal` and `/loop` are implemented, and which parts a model can reach on its own. Covers the `Stop` prompt-hook mechanism behind `/goal`, the cron/wakeup tools behind `/loop`, skill-declared hooks, and the two goal "engines" (LLM-evaluated vs shell-evaluated). |
| [`SLASH-COMMAND-REACHABILITY.md`](SLASH-COMMAND-REACHABILITY.md) | All 101 registered slash commands, sorted into four reachability tiers. |
| [`experiments/`](experiments/) | Fixtures and unedited run output behind every claim. |
| `bin/ccstr` | Slices fixed-string matches out of a `strings` dump of the binary. |

## Method

Claims here are one of two kinds, and they are labelled:

* **Read from the binary** -- registration shapes, schemas, de-minified source.
  Solid, and reproducible with the included tooling.
* **Probed** -- a real headless run whose output is committed under
  `experiments/`.

Two working rules came out of doing this, and they generalize past this repo:

1. **Where a claim is executable, run it instead of reasoning about it.** Three
   confident claims here were falsified by a ~$0.10 probe -- including the
   shipped documentation's own description of where prompt hooks are allowed.
2. **Probes against an LLM-in-the-loop system are stochastic.** Two
   byte-identical runs produced opposite outcomes (1 turn vs 10). A single run
   banks whichever draw it got, so anything load-bearing here was run at least
   twice and the spread reported.

## Reproducing

```bash
V=~/.local/share/claude/versions/<version>
strings -a -n 6 "$V" > /tmp/cc-strings.txt
./bin/ccstr 'sessionHooksRegistry.add' --window 900
```

Check the object shape still holds before trusting a scan: if the registration
format changes, a scan finding nothing looks exactly like a correct scan of a
build that has none.
