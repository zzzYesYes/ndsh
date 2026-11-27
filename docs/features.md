# ndsh features

The full inventory: what ndsh does, and the key or command that drives it.
Global keys are user config (`keys` in `setup()`, all nil by default) — the
`<leader>an*` bindings below are the README example, not defaults.
Panel-local keys are buffer-local to the panel and stable.

## Panel

The panel is two ordinary windows: message pane (readonly transcript) over
input pane. Layout adapts: with no file buffer up (empty window, dashboard,
scratch) it takes over the whole tab; with code buffers open it docks
(`layout = "right" | "bottom" | "float"`, `width`/`height` fractions).
Closing a full-tab takeover restores what was there — dashboards and other
wipe-hidden buffers are preserved across cycles — or quits like `:q` on the
last window (`restore = "quit" | "dashboard" | "scratch" | fun(win)`).

| Action | Key / command |
|---|---|
| Toggle the panel | `toggle` key, `:NDSHToggle` |
| Open / close explicitly | `:NDSHOpen` / `:NDSHClose` |
| Close panel (from pane) | `q` in the message pane |
| Jump to input | `i` in the message pane |

## Sessions

One runtime multiplexes any number of conversations, each with its own
transcript, status, and wire session. Sessions are provisional until their
first message — toggling around never fills the store with empties. Names
auto-title from the first prompt (a `/rename`d name is kept).

| Action | Key / command |
|---|---|
| New session | `new_session` key, `:NDSHNew [name]`, `/new [name]` in the input |
| Session navigator | `sessions` key, `:NDSHSessions` — telescope preview shows the transcript tail; `<C-d>` deletes the entry (confirm) |
| Resume last session | `resume` key, `:NDSHResume` |
| Rename | `:NDSHRename [name]`, `/rename <name>` |
| Delete current | `:NDSHDelete` — falls back to the next session, or a fresh provisional one |

Sessions persist across nvim restarts: the registry (`sessions.json`) plus a
rendered transcript per session (`transcripts/<id>.md`) beside the store.
Restored sessions return detached; activating one reloads its transcript and
resumes the wire session with full context. Wire sessions are stored per
working directory by dsh, so a session restored under another cwd starts
fresh (transcript kept).

## Transcript navigation

| Action | Key / command |
|---|---|
| Scan messages | `messages` key, `:NDSHMessages`, `s` in the message pane — telescope picker, fuzzy on full text, live preview |
| Next / previous block | `J` / `K` in the message pane — tool outputs unfold; one way, no wrap |
| Folds | `<Tab>` / `za` toggle, `zR` / `zM` open/close all |
| Search | `/` (native) |

## Models and reasoning

`:NDSHConnect` picks a provider, stores its API key (owner-only at
`stdpath("data")/ndsh/credentials.json`), and offers the provider's live
model catalog (fetched over HTTP; free text fallback). `:NDSHModel` switches
models — active route, configured `dsh.models`, stored models, discovered
catalog entries, and an "other model…" free-text entry per connected
provider. `:NDSHReasoning` switches reasoning effort (`off`/`low`/`high`/
`max` on the DeepSeek adapter; `auto` = server default).

The SDK fixes provider/model/effort at `initialize`, so switching restarts
the runtime; sessions resume on the new route with their context. The last
route (provider, model, effort) persists across nvim restarts.

The input pane winbar shows agent status and model on the left; right-aligned
the reasoning effort, plan/build mode, working directory, and context usage
(`high · plan · ~/proj · 12k/128k · 10%`).

## Input pane

`<C-s>` sends (insert and normal mode; `keys.send`); insert `<CR>` is a plain
newline, normal `<CR>` sends. `/` offers `<C-x><C-u>` completion with live
highlighting for local (`/new`, `/rename`) and runtime (`/compact`, `/goal`,
`/plan`) commands. `keys.tabnext`/`tabprev` can remap buffer-style tab keys
to real tabpages inside the panel.

## Approvals and questions

Tool approvals (`dsh.approval`) and structured user questions
(`dsh.user_questions`) arrive as server requests answered through `vim.ui`:
allow once / reject / cancel, with the tool's arguments shown when the
`tool/call` event arrived first. Dismissing is never an approval.

## Account balance

`/usage` (or `:NDSHUsage`) prints the active provider's account balance as a
transcript notice. Balance APIs are provider-specific; `provider_api.lua`
ships adapters for DeepSeek (CNY, topped-up/granted breakdown) and Kimi
(USD, cash/voucher breakdown — usable once dsh ships a Kimi runtime
adapter; see TODO.md). Providers without a balance API (or a `balance =
{ url, parse }` override in config) get an honest notice instead.

## Connecting providers

`:NDSHConnect` lists the configured providers. DeepSeek offers two paths:
pasting an API key (masked entry, validated against the model catalog
before storing, with the console URL in the prompt) or browser login, which
boots the managed runtime in web profile so you can complete the account
login in the browser; the token persists in the dsh profile and needs no
API key afterwards.

**Multi-provider via pi-ai routes.** The runtime's pi-ai adapter ships ~25
provider routes (moonshotai, moonshotai-cn, anthropic, openai, google,
groq, mistral, openrouter, xai…) but mounts dormant until a route is
configured. ndsh manages that for you (`lua/ndsh/routes.lua`): connecting a
route provider writes the route into a marked block of
`~/.dsh/profiles/sdk/cordis.patch.yml` (source of truth: `routes.json`
beside the credentials store; your own patch content is untouched), and
picking a discovered model in `:NDSHModel` auto-declares it on the route.
Presets included: Kimi `kimi.ai` and Kimi `kimi.com` — independent
platforms with independent keys, pick the one matching where your key was
created — Anthropic, and OpenAI. More presets are one table entry away.

## Runtime

The runtime connects at plugin load and when the panel opens
(`dsh.auto_connect`). Resolution order: `dsh.cmd`, `dsh` on `$PATH`, the
managed bootstrap runtime, then `~/workspace/deepseek-harness` via pnpm.
With nothing resolvable, first use offers to download a pinned Node.js
(`dsh.node_version`) and `@deepseek-ai/dsh` (`dsh.version`) into
`stdpath("data")/ndsh/bootstrap`; `:NDSHInstallRuntime` repeats or repairs
it. `:NDSHStop` / `:NDSHRestart` manage the process; `:NDSHLog` shows its
captured stderr.

## Configuration reference

`setup({})` fields (see `:help ndsh-config` for details):

| Field | Default | Meaning |
|---|---|---|
| `layout` | `"right"` | `"right"` \| `"bottom"` \| `"float"` dock (empty tabs always take over) |
| `width` / `height` | `0.4` / `0.3` | dock size as a fraction of the editor |
| `input_height` | `8` | input pane rows |
| `keys` | all nil | see above; `send` defaults to `{ "<C-s>" }` |
| `restore` | `"quit"` | takeover-close behavior: `"quit"` \| `"dashboard"` \| `"scratch"` \| `fun(win)` |
| `store_path` | nil | credentials/session store location |
| `persist_sessions` | `true` | registry + transcripts survive restarts |
| `dsh.cmd` | nil | explicit runtime argv |
| `dsh.auto_connect` | `true` | connect at plugin load |
| `dsh.provider` / `dsh.model` | deepseek | active route |
| `dsh.models` | `{}` | extra routes for `:NDSHModel` |
| `dsh.reasoning_effort` | nil | effort at initialize; nil = server default |
| `dsh.reasoning_efforts` | off/low/high/max | picker choices for `:NDSHReasoning` |
| `dsh.version` / `dsh.node_version` | pinned | managed bootstrap versions |
| `dsh.approval` / `dsh.user_questions` | `true` | server request bridges |
| `dsh.env` | `{}` | extra runtime environment |
