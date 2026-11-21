# TODO

Next steps for ndsh, roughly in priority order.

## M4: session persistence + resume

Persist the conversation registry (id, name, provider/model, cwd) in the
store. On nvim start, offer to reattach sessions via `session/resume`;
activating a stored session resumes its wire session on the runtime.
Known caveat: without a history-read method on the SDK wire, the transcript
starts empty with a "session resumed" notice (history read is wishlist #2
in docs/upstream-sdk-plan.md).

## Rendering

- **Reasoning blocks**: render assistant thinking as dimmed, collapsible
  sections (currently skipped by the projection).
- **Richer approval cards**: show tool arguments (and diffs for file
  edits) in the approval prompt before allowing.
- **Multi-select user questions**: toggle several options for
  `multiSelect` questions instead of single-select.

## UX polish

- **Auto-title sessions** from the first prompt instead of `chat N`.
- **Spinner** in the input winbar while a session is running.
- **Telescope preview** of the transcript tail in the session navigator.

## Upstream (fork of deepseek-harness)

Per docs/upstream-sdk-plan.md, in priority order:

1. Mid-session model switch (`session/set_model`) — unblocks live
   `:NDSHModel` without a runtime restart.
2. Session history read (`session/history`) — unblocks transcript rebuild
   after resume.
3. Token-level streaming notification — unblocks typewriter rendering;
   the chat writer's incremental `append()` path is ready for it.
4. Model catalog query — unblocks live model discovery in `:NDSHModel`.

## Ops

- CI (GitHub Actions) running the five suites headlessly:
  deps, unit, smoke, features, integration.
