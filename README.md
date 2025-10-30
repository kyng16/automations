### One-click redeploy via GitHub Actions (recommended)

This repo includes a workflow at `.github/workflows/render-deploy.yml` that triggers a Render deploy using a Deploy Hook URL.

Steps:

1. In Render (Service → Settings → Deploy Hooks), copy the Deploy Hook URL.
2. In GitHub (Repository → Settings → Secrets and variables → Actions), add secret:
	- `RENDER_DEPLOY_HOOK_URL` = the hook URL from step 1
3. Push changes or run the workflow manually (Actions → Render Deploy → Run workflow).

The workflow posts to the hook; Render builds using the service’s configured settings. Make sure your service is configured to use Docker with:

- Repository: `kyng16/automations`
- Branch: `autoemotion`
- Dockerfile path: `server/Dockerfile`
- Build context/root directory: `server`
- Health check path: `/health`
- Environment: set `OPENAI_API_KEY` secret
If your existing service was created before adding `/transcribe` and is showing 404 for `/transcribe`, it is likely building from the wrong context or an old image. Create a new service using the blueprint or switch the existing one to Docker with root directory `server`.

### Verify deployment

 GET `/` returns JSON mentioning `POST /transcribe` and a recent `version`
If `/transcribe` is `404`, your service is serving an outdated build or the build context is not `server/`. Fix service settings or create a new service using the blueprint.

Render free plan has cold starts. First request may take ~20–40s. The client app warms up `/health` automatically and uses longer timeouts.
# autoemotion

A new Flutter project.

## OpenAI API integration

This app contains a minimal example of calling the OpenAI API (Chat Completions) from Flutter using a small service in `lib/services/openai_service.dart` and a simple UI in `lib/main.dart`.

How to run locally with your API key (PowerShell on Windows):

```
flutter pub get
flutter run --dart-define=OPENAI_API_KEY=sk-your_key_here
```

Notes:
- Your API key is read at compile time via `String.fromEnvironment('OPENAI_API_KEY')`.
- Default model is `gpt-4o-mini`. You can switch models from the app (gear/menu in the top bar). Options include `gpt-5`, `gpt-4o`, `gpt-4o-mini` (availability depends on your OpenAI account).
- Do not hardcode secrets in the source. For production apps, route OpenAI calls through your own backend to keep keys secure and add rate limiting.

## Server-first (proxy) setup

This repo also includes a tiny Dart server in `server/` that proxies requests to OpenAI. This is the recommended way to keep your OpenAI key off the client.

Run the server locally (PowerShell):

```
cd server
dart pub get
$env:OPENAI_API_KEY = 'sk-your_key_here'
dart run bin/server.dart
```

Then run the Flutter app pointing to the proxy:

```
cd ..
flutter run --dart-define=API_BASE_URL=http://localhost:8080
```

Notes:
- Client will call `POST {API_BASE_URL}/chat` with `{prompt, model?, system?}` and expects `{content}`.
- If `API_BASE_URL` is not provided, the client will call OpenAI directly (requires `OPENAI_API_KEY`).

### Runtime settings (no rebuild)

You can also set the proxy URL at runtime inside the app:

- Launch the app normally (no `--dart-define` needed).
- Tap the gear icon to set the proxy URL.
- Use the sparkle/menu icon to choose model (e.g., `gpt-5`).
- Choices are stored locally and applied on next launch.

## Deploy to Render.com

The repo includes `render.yaml` to create a Docker-based Web Service for the Dart server in `server/`.

Steps:
1. Push this repo to GitHub (or GitLab/Bitbucket).
2. In Render dashboard: New > Blueprint > Connect repo (it will detect `render.yaml`).
3. When the service appears, open its Settings > Environment and set `OPENAI_API_KEY` (make it a Secret). Redeploy.
4. After deploy, note the public URL, e.g. `https://autoemotion-server.onrender.com`.
5. Run the Flutter app with:

```
flutter run --dart-define=API_BASE_URL=https://autoemotion-server.onrender.com
```

Notes:
- Health check path `/health` is provided by the server for Render.
- The Dockerfile builds a native Dart executable for fast startup.

### Transcription endpoint (/transcribe) and verification

The server exposes `POST /transcribe` which forwards raw audio bytes to OpenAI Whisper and returns `{ "text": "..." }`.

Client behavior:
- The app calls only the proxy: `POST {API_BASE_URL}/transcribe` with `Content-Type: application/octet-stream` and `x-filename` header.
- No direct fallback is performed in the app (to avoid storing OpenAI keys on device). If `/transcribe` is missing, update/redeploy the server.

Quick checks after deploy:
1) Open your server base URL in a browser: `GET /` should include `"POST /transcribe"` in the routes and a `version` field.
2) Try `GET /transcribe` in the browser: should return `405 Method Not Allowed` JSON. If you see `404`, the deployment likely didn't pick up the updated code or the service root is misconfigured.
3) `GET /health` should return `{ "status": "ok" }`.

Manual curl checks (optional):

```bash
# Probe info
curl -s https://autoemotion-server.onrender.com/ | jq

# Probe /transcribe route exists (should be 405)
curl -i https://autoemotion-server.onrender.com/transcribe
```

If you still get `404` on `/transcribe`:
- Confirm your Render service uses this repo and `render.yaml` with `rootDir: server`.
- Verify auto-deploy triggered by the last commit that changed `server/bin/server.dart`.
- Manually hit Redeploy in Render.
- Check Logs for route list printed by `GET /`.

Security note:
- The app does not accept or store `OPENAI_API_KEY`. Keep your key only on the server (Render env var) and route all requests via the proxy.

## Emotion recognition (Polish)

Server exposes `POST /emotion` which classifies input text into one of:
`Radość`, `Złość`, `Strach`, `Smutek`, `Wstyd`.

Request body:

```
{
	"text": "bardzo się cieszę z wyniku!",
	"model": "gpt-4o-mini",          # optional
	"labels": ["Radość", "Złość", "Strach", "Smutek", "Wstyd"]  # optional
}
```

Response body:

```
{
	"label": "Radość",
	"confidence": 0.92,
	"scores": {"Radość":0.92, "Złość":0.02, "Strach":0.01, "Smutek":0.03, "Wstyd":0.02}
}
```

In the app, every user message is analyzed and a small chip with emotion and confidence appears under the message bubble.

## Voice input (press and hold 🎙️)

- Press and hold the mic button next to the input field, speak, then release.
- The recognized text fills the input automatically; on release it is auto-sent.
- Android: the app requests microphone permission on first use.
- iOS: Info.plist contains `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.


## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
