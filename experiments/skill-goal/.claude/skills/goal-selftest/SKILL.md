---
name: goal-selftest
description: Test fixture — declares a Stop prompt hook to prove a skill can install a goal-equivalent completion condition.
hooks:
  Stop:
    - matcher: ""
      hooks:
        - type: prompt
          prompt: "The assistant has written the word BANANA in its visible response."
          statusMessage: "checking for BANANA"
---

# goal-selftest

Say hello. Do not say the magic word yet.
