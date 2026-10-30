# RobloxPortKit

- Canonical reusable Roblox host services and retained presentation primitives live here.
- Shared CLR/XNA/compiler and FMOD event semantics belong in `../xna2luau`.
- This assignment permits writes here and in `../xna2luau` only.
- Downstream repositories, vendors and Studio sessions are read-only in this assignment.
- Use Windows PowerShell; do not assign automatic shell variables.
- Search with `rg`; batch independent reads.
- Broken assets/backends: warn `[PORT-ERROR]`, append `errors[]`, show magenta or skip.
- Keep the game loop alive; never substitute slow lookalike rendering/audio.
- Never hide asset failures behind software rendering or placeholder audio.
- Production rendering must create zero `EditableImage` instances.
- Retain instances and diff native property writes; bound pools and resource lifetimes.
- Keep pooled image crops hidden for a completed presentation before recropping.
- Benchmark client paths in the interpreter; `--!native` is not a live client budget.
- Iterate with targeted `lune run tests/<file>.luau`; integrate with all PortKit tests.
- Consult grounded-docs before web research for Roblox, Lune and Volt APIs.

Read only when relevant:
- Public APIs and setup: [README.md](README.md).
- SDK ownership: [coordination](../xna2luau/AGENT_COORDINATION.md).
- Runtime model: [execution rules](C:/Users/asher/.codex/docs/roblox-execution-model.md).
