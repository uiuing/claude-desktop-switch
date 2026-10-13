---
description: Re-render the README images from demo data and review them
---

1. Run `zsh scripts/screenshots.sh` (about 30 seconds; windows are drawn off-screen with demo data only).
2. Open and look at `docs/images/hero-en-light.jpg`, `hero-en-dark.jpg`, `hero-zh-Hans-light.jpg`, `conversations-light.png`, `usage-light.png` and `social-preview.png`.
3. Check: no truncated text, no "example.com"-style or unmasked emails, the suggested account is highlighted in the menu panel, plan badges are visible, colors match light and dark mode, nothing looks broken or empty.
4. Report what changed and anything that looks wrong. If demo data needs adjusting, change `Sources/ClaudeSwitch/DemoData.swift` and render again.
