# CLAUDE.md

Repository engineering rules are in [AGENTS.md](AGENTS.md). Setup, architecture, and verification commands are in [README.md](README.md).

MacInkostomo is a native SwiftUI app with an in-process Swift `InkOSCore`. The app has no browser interface, local server, port, Node runtime, or CLI bridge. New product behavior must enter through typed `InkOSLibrary` functions and a focused native core module.

Never commit `data/`, `book/`, credentials, user state, backups, or build output.

## Turn discipline

- Do not end your turn while the current task is unfinished. If you wrote that
  you will do something (e.g. "Fixing it", "I will update X"), you MUST perform
  that action with tool calls in the same turn — never announce an action and
  then stop.
- Only stop with `end_turn` when the task is complete, or you genuinely need
  user input to proceed. Never stop merely to summarize next steps.
- If a tool call fails, diagnose and retry with an adjusted approach instead of
  abandoning the task.
