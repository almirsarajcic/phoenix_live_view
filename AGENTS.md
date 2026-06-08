# AGENTS.md

This is the `phoenix_live_view` library itself (server-rendered, real-time UIs over WebSockets). It is a dual Elixir + TypeScript codebase: the runtime lives in `lib/`, the JS client in `assets/js/phoenix_live_view/`. Supported Elixir, Phoenix, and Node versions live in `mix.exs` and `package.json` / `.github/workflows/ci.yml` — check there rather than duplicating them here.

This is the LiveView source, not an app that uses LiveView. Match the existing code; this repo's house style differs from a generated Phoenix app. When in doubt, read a neighbouring file and copy its conventions.

This file covers the codebase and its house style. PR etiquette (fork, topic branch off `main`, rebase — never merge — upstream, focused commits) lives in the [Phoenix CONTRIBUTING.md](https://github.com/phoenixframework/phoenix/blob/main/CONTRIBUTING.md).

## Development commands

Run Elixir commands from repo root. npm scripts also run from root (Playwright `cd`s into `test/e2e` itself).

- Install deps: `mix deps.get && npm install` (or `npm run setup`, which runs both).
- Full Elixir tests: `mix test` (CI: `mix test --cover --export-coverage default --warnings-as-errors`).
- Single test file: `mix test test/phoenix_live_view/integrations/stream_test.exs`
- Single test by line: `mix test test/phoenix_live_view/integrations/stream_test.exs:42`
- Scope to a dir: `mix test test/phoenix_live_view/integrations` (no separate unit/integration tasks or tags — one `mix test` runner).
- JS unit tests (jest + jsdom): `npm run js:test` (= `npm run build && jest`); watch `js:test.watch`; coverage `js:test.coverage`. Tests in `assets/test/*_test.ts`.
- E2E (Playwright, Chromium/Firefox/WebKit): `npm run e2e:test` (= `mix assets.build && cd test/e2e && npx playwright install && npx playwright test`). UI mode `-- --ui`; single test `-- tests/streams.spec.js:9 --project chromium --headed`; debug `-- ... --debug`. Server boots via `MIX_ENV=e2e mix run test/e2e/test_helper.exs`.
- Elixir format: `mix format` (CI: `mix format --check-formatted`). `.formatter.exs` uses `import_deps: [:phoenix]`, plugin `Phoenix.LiveView.HTMLFormatter`, and `tag_formatters: %{script: Prettier}` (custom `lib/prettier.ex` formats `<script>` bodies).
- JS format (prettier): `npm run js:format` (CI: `js:format.check`).
- JS lint (eslint, `eslint.config.js`): `npm run js:lint`. JS typecheck: `npm run typecheck:tests`.
- Elixir "lint" = compile clean: `mix compile --warnings-as-errors` (no credo/dialyzer/sobelow configured).
- Build JS assets: `mix assets.build` (alias: `npm run build` = tsc emitting only `.d.ts`, then esbuild bundles `module`/`cdn`/`cdn_min`/`main`). Watch: `mix assets.watch`. esbuild is driven by Mix via `config/config.exs` (injects `LV_VSN`), NOT npm; output → `priv/static/phoenix_live_view.{esm,cjs,min}.js` + `.js` + sourcemaps.
- Other aliases: `docs` (ex_doc + TypeDoc JS docs via `generate_js_docs`). npm: `setup`, `cover`, `cover:merge`, `cover:report`.

## Before you push

Run what CI runs. A green local run of these is the bar for a PR:

```bash
mix format --check-formatted
mix test --warnings-as-errors
npm run build && npm run typecheck:tests
npm run js:lint && npm run js:format.check
npm run js:test
```

E2E (`npm run e2e:test`) is heavier; run it when you touch the JS client or DOM patching.

## Pull request hygiene

- **Never** commit the compiled client bundles. `priv/static/phoenix_live_view.{js,cjs.js,esm.js,min.js}` and their `.map` files are git-tracked, but **maintainers rebuild and commit them themselves** in dedicated `Update assets` / `Release` commits. Feature PRs ship source only (`assets/js/**`, `lib/**`, tests). Including bundles causes merge conflicts and unreviewable minified diffs.
- **Always** ship JS client changes as the TypeScript/source edit under `assets/js/phoenix_live_view/`, not as edits to `priv/static/`.
- `assets/js/types/` (`.d.ts`) is generated and gitignored — never commit it.
- Keep PRs focused. **Never** edit CI config (`.github/workflows/`), the `Makefile`, or `mix.exs` metadata as a side-effect of a feature PR unless that IS the change.
- The only contributing guide is README "## Contributing", which defers to the [Phoenix Contributing guide](https://github.com/phoenixframework/phoenix/blob/master/CONTRIBUTING.md). There is no `CONTRIBUTING.md` here.

## Elixir house style

Formatting is enforced only by `mix format` (there is no Credo or Dialyzer). The conventions below are not caught by the formatter — match them by hand.

### Comments

- **Write comments sparingly.** Existing lib files sit around 1–6% comment lines. Comment the non-obvious *why* (a race condition, a deployment edge case, an ordering constraint), never the *what* the code already states.
- **Never** narrate the next line (`# Collect the messages`, `# No more`). Delete those.
- **Never** use banner separators (`# ------------------`), section headers like `# Public API` / `# Private helpers`, or boxed comment blocks. They appear nowhere else in `lib/`.
- **Never** leave internal tracking refs in comments (`B1`, `G2`, `H3`, design-doc shorthand). Comments must read for a stranger, not a checklist.
- Keep each comment to a line or two. If you need a paragraph, the code or a `@doc`/`@moduledoc` is the right home.

### Docs and typespecs

- The first paragraph of any `@doc`/`@moduledoc`/`@typedoc` is the summary — keep it to one line (Phoenix's rule of thumb: anything over ~80 characters makes an ugly summary). Put details in later paragraphs.
- For **functions, macros, and callbacks, say what it will do**: "Returns true if the socket is connected.", "Invoked when the LiveView is terminating.", "Renders a template." **Never** start with "This function…".
- For **modules, protocols, and types, say what it is**: "Conveniences for working with HTML strings and templates." (a noun phrase, not "This module…").
- Include doctest-friendly `## Examples` where it helps.
- Internal modules use `@moduledoc false`. Most of `lib/` is `@moduledoc false`; only the public API surface is documented.
- **Never** pair `@doc false` with a long leading `#` comment block. If an internal function needs explaining, give it a normal `@doc """..."""` (it stays private because the module is `@moduledoc false`), like its neighbours.
- `@spec` is sparse in this repo (a minority of lib files use it; core modules like `channel.ex` have none). Don't blanket-spec an `@moduledoc false` module — match the surrounding file.

### Naming and structure

- **One `alias` per line.** **Never** group aliases as `alias Foo.{Bar, Baz}` — that form appears zero times in `lib/`.
- Predicates end in `?` (`connected?`, `changed?`). Guards use `defguard` with an `is_` prefix.
- Prefer `@impl true` for callback implementations; the explicit `@impl SomeBehaviour` form is used only occasionally.
- Public API before private helpers within a module; group related clauses together. Let the formatter handle pipelines, indentation, and spacing.
- Hard-wrap doc strings and comments at ~100 characters (Phoenix's documentation convention).

### Tests

- One `mix test` runner — no unit/integration split via tags. Unit tests in `test/phoenix_live_view/`, full-stack tests in `test/phoenix_live_view/integrations/`, shared fixtures in `test/support/live_views/`.
- Test names carry the description. **Never** prefix `describe`/`test` blocks with banner comments restating the name. Look at `integrations/stream_async_test.exs` for the density to match.
- Test-support modules are self-documenting by name; only comment a fixture when its purpose is genuinely non-obvious.

## Architecture

The repo ships three layers, all under `lib/`: the **HEEx compiler + `Phoenix.Component`**, the **LiveView runtime**, and the bundled **JS client** (`assets/js/`). `phoenix`, `phoenix_html`, `phoenix_pubsub`, `plug` are external deps (Channel/Socket transport, Router, `Phoenix.Token`, `Phoenix.HTML.Safe`) — not vendored here.

### HEEx / template compilation
The `~H` sigil (`lib/phoenix_component.ex`) compiles via `Phoenix.LiveView.TagEngine` (`lib/phoenix_live_view/tag_engine.ex`, generic HTML-aware tag/slot/component engine) with `Phoenix.LiveView.HTMLEngine` (`lib/phoenix_live_view/html_engine.ex`, HTML5 tag handler) on top of the change-tracking EEx engine `Phoenix.LiveView.Engine` (`lib/phoenix_live_view/engine.ex`). `attr`/`slot` declarations: `lib/phoenix_component/declarative.ex`.

### Diff/render engine
- Compile-time (`lib/phoenix_live_view/engine.ex`): templates become `%Phoenix.LiveView.Rendered{static, dynamic, fingerprint, root}`. `static` = literal string segments (sent once); `dynamic` = `fn track_changes? -> [...] end` returning iodata, `nil` (unchanged), or nested `%Rendered{}`/`%Comprehension{}`/`%Component{}`. Change tracking uses `assigns.__changed__` + per-dynamic taint analysis to emit `nil` for unchanged dynamics. The moduledoc here is the authoritative explanation.
- Comprehensions (`%Phoenix.LiveView.Comprehension{}`): for-loops emit shared static once + per-entry vars; `:key`/`:stream` enable keyed diffing.
- Runtime (`lib/phoenix_live_view/diff.ex`): `Diff.render/4` walks `%Rendered{}` vs prior fingerprints into a compact wire map (`:s` static, `:c` components, `:k`/`:kc` keyed, `:e` events, `:r` reply, `:t` title, `:p` template, `:stream`). `to_iodata/2` reconstructs full HTML for the dead render.

### Server lifecycle (dead render → connected mount)
- Public API/behaviour: `Phoenix.LiveView` (`lib/phoenix_live_view.ex`) — `mount/3`, `handle_params/3`, `handle_event/3`, `render/1`, navigation helpers.
- Dead render (HTTP, no process): router-installed `Phoenix.LiveView.Plug` → `Controller.live_render` → `Phoenix.LiveView.Static` (`lib/phoenix_live_view/static.ex`). Builds a transient `%Socket{}`, runs mount + `handle_params`, renders once, embeds signed `phx_session`/`phx_static`/`phx_main` tokens (token vsn 6).
- Connected mount (WebSocket): `Phoenix.LiveView.Socket` (`lib/phoenix_live_view/socket.ex`) routes `lv:*` → `Phoenix.LiveView.Channel`, `lvu:*` → `UploadChannel`. The channel verifies the session token, reconstructs the socket, **runs mount + `handle_params` again**, sends initial diff.
- The core process is `Phoenix.LiveView.Channel` (`lib/phoenix_live_view/channel.ex`, `use GenServer, restart: :temporary`) — one per connected LiveView. Mount runs in `handle_info({Phoenix.Channel, ...})`; events arrive as `%Phoenix.Socket.Message{}`, route to a LiveComponent if `payload["cid"]` is present else `view_handle_event/3`. Rendering: `handle_changed` → `render_diff` → `Diff.render` → push `"diff"`. Monitors transport/parent/upload/async pids for cleanup.
- Shared plumbing: `Phoenix.LiveView.Utils` (configure_socket, mount/params callers, change tracking), `Phoenix.LiveView.Renderer`, lifecycle hooks in `Phoenix.LiveView.Lifecycle` (per-stage hook lists; `on_mount`, `attach_hook`; `{:cont,...}`/`{:halt,...}` run before each view callback).

### LiveComponents
`Phoenix.LiveComponent` (`lib/phoenix_live_component.ex`), stateful, keyed by `id`. Templates emit `%Phoenix.LiveView.Component{}`. All cid bookkeeping lives in `Phoenix.LiveView.Diff`: each component gets an integer cid; state stored per cid; wire diff places components under `:c`. Events carry `cid` so the channel re-renders only that component, not the parent. `send_update` → `Diff.update_component`.

### Routing & navigation
`Phoenix.LiveView.Router` (`lib/phoenix_live_view/router.ex`): `live/4` registers routes → `Phoenix.LiveView.Plug` with `{view, action, opts, live_session}` metadata; `live_session/3` groups routes sharing session/on_mount/root_layout and bounds navigation. `Phoenix.LiveView.Route` classifies nav as `:internal` (same live_session+view → re-run `handle_params`), `:external`, or `:error`. `push_patch` (same LiveView), `push_navigate` (new LiveView in same session, kills+respawns channel), `push_redirect`/`redirect` (full HTTP). `handle_params` is root-only.

### Uploads
Config `Phoenix.LiveView.UploadConfig` (`%UploadConfig{}`/`%UploadEntry{}`), orchestration `Phoenix.LiveView.Upload` (`allow_upload`, `generate_preflight_response`, `consume_uploaded_entries`). Each file gets its own `Phoenix.LiveView.UploadChannel` (topic `lvu:*`) receiving binary chunks, written via `UploadWriter`/`UploadTmpFileWriter`. Flow: LV channel `"allow_upload"`/`"progress"` → preflight tokens → client opens `lvu:` channels → chunks stream → `consume_uploaded_entries` in `handle_event`.

### JS commands
`Phoenix.LiveView.JS` (`lib/phoenix_live_view/js.ex`) builds a `%JS{ops: [...]}` struct; builders (`push`, `dispatch`, `toggle`, `transition`, `navigate`/`patch`, `focus`, `exec`, ...) append `[kind, args]`. Serialized to the client via `Phoenix.HTML.Safe` as a JSON ops array in a `phx-*` attribute; the JS client interprets ops without a server round-trip (except `push`/`exec`, which dispatch server events).

### Async & streams
- Async: `Phoenix.LiveView.Async` + `Phoenix.LiveView.AsyncResult`. `assign_async`/`start_async` spawn a monitored task; results route via `Channel.report_async_result` → `handle_async/3` or the targeted component. `%AsyncResult{loading, ok?, failed, result}` wraps the value. Warns if the socket/assigns is captured into the task closure.
- Streams: `Phoenix.LiveView.LiveStream` (`%LiveStream{}`). `stream`/`stream_insert`/`stream_delete` are NOT kept in assigns long-term; they flow through the diff as the `:stream` key, telling the client to insert/delete/reset DOM nodes by `dom_id` with no server-side list state.

### JS client (`assets/js/phoenix_live_view/`)
Mostly TypeScript; a few legacy `.js` (`rendered.js`, `js.js`, uploaders). Entry `index.ts` exports `LiveSocket`, `ViewHook`, `createHook`.
- `live_socket.ts` — `LiveSocket`: top-level orchestrator wrapping a Phoenix `Socket` (passed in by the user), manages root `View`s, binds DOM events, history/nav, debug/latency-sim, `reloadWithJitter` failsafe, `execJS`, `js()` facade, `replaceMain` for live nav.
- `view.ts` — `View` (one per LiveView): owns the Phoenix Channel `lv:<id>`, holds a `Rendered`, applies diffs, drives `DOMPatch`, manages hooks, form recovery, event pushing, uploads.
- Diff → DOM: channel `"diff"` → `View.applyDiff` → `Rendered.mergeDiff` (extracts reply/events/title, merges into kept tree) → `Rendered.toString()` → `View.performPatch` → `DOMPatch.perform` → `morphdom` (real npm `morphdom@2.7.8`, bundled not vendored). morphdom callbacks implement LV semantics: `getNodeKey` (id/`data-phx-id`), `phx-remove`, hook `destroyed`/`beforeUpdate`/`updated`, `ignore_attributes`, ref-lock cloning at `data-phx-ref-lock`, stream ordering via `dom_post_morph_restorer.ts`. So: `rendered.js` = diff merge + HTML generation; `dom_patch.ts` = morphdom application.
- Hooks: `view_hook.ts` (`ViewHook`) — callbacks `mounted`/`beforeUpdate`/`updated`/`destroyed`/`disconnected`/`reconnected`, API `pushEvent`/`pushEventTo`/`handleEvent`/`js()`/`this.el`/`this.liveSocket`. Built-ins in `hooks.ts` (`LiveFileUpload`, `LiveImgPreview`, `FocusWrap`, `InfiniteScroll`).
- JS commands: builder `js_commands.ts` (`liveSocket.js()`/`hook.js()`) → executor `js.js` (`JS.exec` dispatches `exec_<kind>`); server-emitted encoded `phx-*` commands funnel through the same executor.
- Uploads: `live_uploader.js` (`LiveUploader`, serialize/track files), `upload_entry.js` (`UploadEntry`, per-file progress), `entry_uploader.js` (`EntryUploader`, default chunked uploader on `lvu:<ref>`); external uploaders (e.g. S3) replace `EntryUploader` via the `uploaders` option.
- DOM helpers: `dom.ts` (`DOM` object of statics, private state in a WeakMap-style attribute). Constants/attributes in `constants.ts`.

### Tests & fixtures
- `test/phoenix_live_view/` — core unit tests; `integrations/` runs full-stack against a real endpoint.
- `test/phoenix_component/` — component-layer tests.
- `test/support/` — shared infra compiled into the app (`endpoint.ex`, `router.ex`, `live_views/` with ~26 fixture LiveViews). `.igniter.exs` lists `test/support` as a source folder.
- `test/e2e/` — Playwright suite + e2e LiveViews under `test/e2e/support/`.
- JS unit tests in `assets/test/` (jest, jsdom); `phoenix_live_view` aliases to `assets/js/phoenix_live_view/index.ts`.
