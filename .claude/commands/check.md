---
description: Run the localization check and both test suites, then summarize
---

Run these from the repository root, one after another, and keep going even if one fails:

1. `python3 scripts/check-localization.py`
2. `swift test`
3. `swift test --scratch-path .build/write-tests -Xswiftc -DCLAUDE_WRITE_ENABLED`

Then report in a few lines: which steps passed, and for each failure the test or file, the assertion or error, and the most likely cause in the code. Do not change any code unless asked.
