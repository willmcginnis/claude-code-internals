---
name: goal-selftest-met
description: Control fixture — same Stop prompt hook, but the body satisfies the condition on turn 1, so the hook should not block.
hooks:
  Stop:
    - matcher: ""
      hooks:
        - type: prompt
          prompt: "The assistant has written the word BANANA in its visible response."
          statusMessage: "checking for BANANA"
---

# goal-selftest-met

Reply with exactly one word: BANANA
