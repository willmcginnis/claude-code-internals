name: runtime-goal
description: Runtime-created goal fixture.
hooks:
  Stop:
    - matcher: ""
      hooks:
        - type: prompt
          prompt: "The assistant has written the word BANANA in its visible response."
---
Say hello.