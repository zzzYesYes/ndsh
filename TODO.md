# TODO

Next steps for ndsh, roughly in priority order.

## Done: docs + session UX batch

README rewritten in the standard plugin shape with docs/features.md as the
detailed inventory; CI runs all six suites; sessions auto-title from the
first prompt and stay provisional until it; the navigator previews
transcript tails and deletes entries with <C-d>; the reasoning-effort
picker and winbar indicator ship with per-route persistence.

## Rendering

- **Approval diffs**: the card shows tool arguments via tool/call
  correlation; rendered diffs for file edits need the arguments on the
  approval request itself (upstream).
- **Multi-select user questions**: toggle several options for
  `multiSelect` questions instead of single-select.

## Upstream (fork of deepseek-harness)

Per docs/upstream-sdk-plan.md, in priority order:

1. Mid-session model switch (`session/set_model`) — unblocks live
   `:NDSHModel` without a runtime restart.
2. Session history read (`session/history`) — unblocks transcript rebuild
   after resume.
3. Token-level streaming notification — unblocks typewriter rendering;
   the chat writer's incremental `append()` path is ready for it.
4. Model catalog query — replaces the HTTP discovery in
   lua/ndsh/models_catalog.lua.
5. Command catalog — upstream PR to mount the full builtin set in the sdk
   profile, or a profile patch today.
6. `session/close` + `session/delete` — real deletion, not just detach.
7. Approval requests carrying tool arguments/diffs — unblocks richer
   approval cards without callId correlation.
