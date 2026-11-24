# TODO

Next steps for ndsh, roughly in priority order.

## Done: M4 session persistence + resume + deletion

Registry persists to sessions.json; stored sessions restore detached and
resume on activation (`session/resume`); `:NDSHDelete` removes sessions
after confirmation. Remaining wire gaps are upstream items 2 and 6 in
docs/upstream-sdk-plan.md.

## Rendering

- **Richer approval cards**: show tool arguments (and diffs for file
  edits) in the approval prompt before allowing.
- **Multi-select user questions**: toggle several options for
  `multiSelect` questions instead of single-select.

## UX polish

- **Auto-title sessions** from the first prompt instead of `chat N`.
- **Telescope preview** of the transcript tail in the session navigator.

## Docs

- **Rewrite README in the usual nvim plugin shape**: intro with a
  screenshot/demo, requirements, install (lazy.nvim spec), and a keymaps
  table. Move the feature inventory into a detailed doc (every feature,
  its default keys and its :NDSH* command), cross-linked with
  doc/ndsh.txt.

## Upstream (fork of deepseek-harness)

Per docs/upstream-sdk-plan.md, in priority order:

1. Mid-session model switch (`session/set_model`) — unblocks live
   `:NDSHModel` without a runtime restart.
2. Session history read (`session/history`) — unblocks transcript rebuild
   after resume.
3. Token-level streaming notification — unblocks typewriter rendering;
   the chat writer's incremental `append()` path is ready for it.
4. Model catalog query — unblocks live model discovery in `:NDSHModel`.
5. Command catalog — upstream PR to mount the full builtin set in the sdk
   profile, or a profile patch today.
6. `session/close` + `session/delete` — real deletion, not just detach.

## Ops

- CI (GitHub Actions) running the six suites headlessly:
  deps, unit, smoke, features, restart, integration.
