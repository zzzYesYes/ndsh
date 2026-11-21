# Upstream: fork and modify the dsh SDK (planned)

ndsh consumes the dsh SDK protocol (`dsh --profile sdk`) as an external
client. Some features ndsh wants are not exposed on today's wire. The plan
is to fork `deepseek-harness` and extend the SDK protocol there, then
consume the fork. Per dsh convention, every protocol change updates the
protocol package, the jsonrpc server, the TypeScript client, the Python
SDK, and the wire docs in the same PR.

## Wishlist (priority order)

1. **Mid-session model switch.** dsh core supports per-session model
   selection (Web UI, ACP `session/set_config_option`), but the SDK binds
   provider/model at `initialize`. Add e.g. `session/set_model` to
   `HarnessSdkRequestMap`, recording the Session selection effective at the
   next step. Unblocks: `:NDSHModel` as a live switch with conversation
   continuity (today it restarts the runtime).
2. **Session history read.** No wire method returns a session's committed
   events, so a resumed session's history is invisible to clients. Add
   e.g. `session/history` (paged event read). Unblocks: transcript rebuild
   after `:NDSHResume` / nvim restart.
3. **Token-level streaming.** Live `agent/assistant-stream` chunks
   currently reach only the Web Session-follow adapter; SDK clients see
   assistant output only when `assistant/message` commits. Add an opt-in
   chunk notification. Unblocks: typewriter rendering — ndsh's chat writer
   already has the incremental `append()` path for it.
4. **Model catalog query.** No way to list available routes/models over
   the wire. Would let `:NDSHModel` offer live discovery instead of static
   config.

## Until then

- Model switching restarts the runtime (`:NDSHModel`), losing live context.
- Resume renders a notice instead of the historical transcript.
- Assistant output renders per committed message, not per token.
