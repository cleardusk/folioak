# Development

Folioak is a native macOS app with an embedded `folioak` CLI. Both use the same download engine; there is no server to deploy.

## Start

Use an Apple Silicon Mac, Xcode or Command Line Tools, and Python 3.9+. Clone the repository, then run:

```sh
./build.command          # Build dist/Folioak.app and the embedded CLI
./test.command          # Offline regression tests
./test.command --stress # Queue lifecycle and resource checks
./package.command       # Build and verify DMG / ZIP
```

The first build or test run needs internet access to fetch pinned media dependencies and compile them. Later runs verify and reuse `build/media-tools/`; regression tests themselves run offline. Run the app from `dist/Folioak.app`. CI uses the toolchain documented in [Build & release](RELEASING.md).

## Find the code

| Area | Files | Responsibility |
| --- | --- | --- |
| Download engine | `Core.swift`, `DownloadError.swift`, `Messages.swift`, `BrowserAuthentication.swift`, `PDF.swift`, `Media.swift`, `Files.swift`, `Douyin.swift`, `Shared.swift`, `AssetNaming.swift` | Parse links, schedule requests, validate files, run media tools and coordinate concurrent processes |
| Application state | `App.swift`, `Workspace.swift`, `WorkspacePersistence.swift`, `Library.swift` | Queue lifecycle, preferences, saved history and libraries; a dedicated component serializes disk access |
| Interface | `WorkspaceView.swift`, `LibraryPresentation.swift`, `AssetNamingSettings.swift`, `Interaction.swift`, `SidebarMotion.swift`, `Theme.swift`, `Shortcuts.swift` | Views, native controls, keyboard interaction and appearance |
| Command line | `CLI.swift` | Arguments, progress, structured output and exit codes |
| Packaging | `Tools/`, `build.command`, `package.command` | Pinned dependencies, signing and verified release artifacts |

Swift sources live in `Sources/`; tests live in `Tests/`. `App.swift` also contains the app lifecycle and settings view. The current build uses explicit source lists in `build.command` and `test.command`; add new Swift files to the relevant lists.

## Make a change

- Keep download and file handling in the shared engine so the app and CLI behave consistently.
- Keep UI mutations on the main actor. Propagate cancellation to network requests and child processes; never mark a file saved before validation.
- New download errors and queue diagnostics use stable `DiagnosticMessage` identifiers and arguments. Preserve the legacy `error` / `message` text fields and schema 1 for older readers; optional payloads allow current rendering to evolve without matching stored prose. Unknown identifiers and legacy records keep readable fallbacks.
- Browser authentication is explicitly injected into the engine and disabled by default. Tests must use synthetic preferences, mock processes and fixtures; never read a developer's browser cookies or test a real signed-in session.
- Use isolated temporary directories and preferences in tests. Do not commit personal paths, downloads, credentials, logs, caches, `build/`, or `dist/`.
- Run checks relevant to the change. Media-engine changes also need the bundled-tool tests; `--live` deliberately contacts real services and is optional.
- Keep visible controls and copy minimal. Verify changed interactions in light/dark appearance and at the minimum window size.

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Release and dependency changes follow [Build & release](RELEASING.md); bundled components have [separate licenses](Resources/MediaComponents.md).

Project source is licensed under [MIT](LICENSE). Keep its copyright notice when redistributing source or binaries; third-party component licenses still apply.

Run `FOLIOAK_TEST_OPTIMIZE=1 ./test.command --large-library-only` to measure queries, asynchronous persistence, and main-actor responsiveness with 20,000 records under release optimization. Use `FOLIOAK_TEST_OPTIMIZE=1 ./test.command --stress --snapshots` for full stress and visual checks; `./test.command --files-only` exercises common-file download and library recovery fixtures.

Naming regressions use `--naming-only`; `--grid-only` covers native list/grid selection and focus, bilingual light/dark snapshots and actual 20,000-item viewport mounting. `--progress-only` checks real URLSession delegate callbacks, known/unknown totals, cancellation and arXiv pacing with offline fixtures. Public-link reproduction stays separate from the offline suite.

For file-detail and original-source changes, `./test.command --details-only --snapshots` runs focused provenance, persistence compatibility, file metadata and native detail-layout checks. It skips unrelated CLI builds and media-tool integration tests; the default full suite still includes these regressions.

Local interaction recording is isolated in `InteractionTrace.swift`, with opt-in controls in `InteractionTraceSettings.swift`. Keep event fields closed and typed: never pass user text, paths, URLs or diagnostic arguments. Record semantic actions at shared entry points and phase transitions, not individual progress callbacks. Run `./test.command --trace-only` for opt-in behavior, bounded buffering/retention, export/recovery, privacy and main-thread ingestion against a 20,000-record library. Use `FOLIOAK_TEST_OPTIMIZE=1` for release performance measurements. Trace tests use isolated preferences and temporary directories.

Run `./test.command --lifecycle-only` for focused queue admission, draft/IME preservation, catalog recovery after a failed write, and PDF-import termination checks. It uses temporary files and isolated preferences, and skips unrelated CLI builds and media-tool integration tests; the full suite includes the same checks.

After building the test target, run `./build/CoreTests --stress-only` to check 200 queue lifecycles, storage budgets and the 20,000-record library independently of native interaction fixtures.

Intelligent Input uses `SmartInput.swift` (contracts/routing), `SmartResolver.swift` (bounded ReAct loop and network tools), `SmartDownload.swift` (cancellable UI sessions), and `DownloadModel`'s durable submission boundary. Run `./test.command --smart-only --snapshots` for isolated credentials, scripted model/tool responses, malformed results, deadlines, cancellation, per-output options, persistence, and native UI checks. `--smart-core-only` runs the same non-UI tests without requiring an unlocked display. Native UI tests still require a separate unlocked run. `--smart-live` explicitly contacts DeepSeek and public pages, using `DEEPSEEK_API_KEY` or `FOLIOAK_DEEPSEEK_KEY_FILE` (a local dotenv/key file); never copy credentials into the repository or logs. Live probes report sample latency and counts, not an SLA, and verify one real PDF download through an isolated queue with temporary files and preferences.
