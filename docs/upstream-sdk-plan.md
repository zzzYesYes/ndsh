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
5. **Command catalog, two related asks.** The SDK server resolves slash
   commands against the booted profile's catalog, and the shipped sdk
   profile mounts only `compact`, `goal`, `plan`; `export`
   (dsh-session-log-export), `feedback` (dsh-command-feedback), and
   `permission` (dsh-permission-presets) resolve as plain prompts (verified
   against a live runtime). Two options, both worth recording:
   - **Upstream PR**: mount the full builtin catalog in the sdk profile
     (or ship it as a documented sdk-full variant), so SDK clients get the
     same commands as the Web/Desktop profiles. We plan to fork dsh and
     send this PR.
   - **Profile patch (available today)**: ndsh could ship a cordis patch
     mounting the three command-provider plugins into the sdk profile at
     launch. Untested: whether their service dependencies exist in
     `dsh-base` (permission presets likely yes — preset events already
     flow; feedback may need the account/telemetry plane). A spike would
     turn load failures into the exact upstream evidence.
   - **Discovery**: whichever way, a catalog query (`commands/list`) lets
     clients stop mirroring the command set by hand — ndsh currently
     hardcodes {compact, goal, plan} for highlight and completion.
6. **Session lifecycle on the wire.** The SDK has `session/resume` but no
   `session/close` or `session/delete`, so deleting a session client-side
   leaves the wire agent running until the next runtime restart and leaves
   dsh's persisted store entry on disk. Add both methods so "delete" can
   mean "really gone" — belongs in the same fork PR family as item 5.

## Until then

- Model switching restarts the runtime (`:NDSHModel`), losing live context.
- Resume renders a notice instead of the historical transcript.
- Assistant output renders per committed message, not per token.
