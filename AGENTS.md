# Repository Guidelines

## Project Structure & Module Organization

This is a Node.js ESM application with a SwiftUI macOS wrapper. `server.js` defines the Express server, API routes, static hosting, and long-running workflow endpoints. Shared backend modules live in `lib/`: status constants, state storage, InkOS integration, Fanqie access, import logic, paths, jobs, and book settings. Browser assets live in `public/` (`index.html`, `app.js`, `style.css`). The Xcode project is `ChapterPublisher.xcodeproj`; native sources live in `macos/ChapterPublisher/`. Runtime data is persisted under `data/` and `book/`; treat it as private user data, not fixtures.

## Build, Test, and Development Commands

- `npm install` installs the Express dependency from `package-lock.json`.
- `npm start` runs `node server.js` and serves the app at `http://localhost:3456`.
- `node server.js` is equivalent for quick local runs.
- `npm test` runs the Node.js regression suite.
- `pnpm --dir inkos install --frozen-lockfile && pnpm --dir inkos build` prepares the vendored InkOS CLI.
- `open ChapterPublisher.xcodeproj` opens the macOS project.

There is no frontend compile step or linter.

## Coding Style & Naming Conventions

Use modern JavaScript ESM syntax (`import`/`export`) and 2-space indentation. Prefer small helper functions near their route or module owner. Use `const` by default and `let` only for reassignment. Keep backend status values centralized in `lib/status.js`; if status strings change, update the independent frontend copies in `public/app.js` as well. Preserve Chinese UI strings and chapter content exactly unless the task asks for copy changes.

## Testing Guidelines

Run `npm test` for backend helper and request-boundary coverage. Also verify changes manually by starting the server, opening `http://localhost:3456`, and exercising the affected workflow. For persistence-related changes, inspect `data/state.json` before and after the action. For InkOS or Fanqie paths, validate failure handling as well as the successful path because they involve subprocesses and external services. For native changes, build the shared `ChapterPublisher` scheme with an explicit writable `-derivedDataPath` and test both attaching to an existing service and owning the service lifecycle.

## Commit & Pull Request Guidelines

This repository has no existing commit history to follow. Use clear, imperative commit subjects such as `Add Fanqie login state handling` or `Fix chapter reimport status reset`. Pull requests should describe the user-facing change, list manual verification steps, mention touched data files or external tools, and include screenshots for visible UI changes.

## Security & Configuration Tips

The server binds locally and has no authentication; do not expose it publicly. Keep filesystem paths centralized in `lib/paths.js`. Avoid committing private runtime state, cookies, or generated backups from `data/` unless explicitly required.
