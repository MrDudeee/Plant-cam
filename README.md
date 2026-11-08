# Plant Cam

An iPhone app that lets Claude look at plant photos while the app is open, and plays them back as a timelapse for each view (side, overhead, node close-ups).

## How it fits together

- **app/**: the iPhone app. It asks for Photos access and, while it's on screen, answers Claude's requests through the relay.
- **relay/**: a small Cloudflare Worker. Claude connects to `/mcp`; the app connects to `/phone`. The relay passes requests and photos between them and stores nothing.
- **.github/workflows/**: builds that run on GitHub. The relay deploys on Linux machines; the app builds on Mac machines and goes to TestFlight. "Check app" compiles the app without signing on every change, so mistakes show up early.
- **build-logs** (branch): each workflow saves a short result file there (`check.txt`, `build.txt`) so problems can be read without digging through the Actions pages.

No passwords, keys, or photos live in this repository. Keys are kept in the repository's Actions secrets, and the relay password is typed into the app.

## Relay protocol (app side)

The relay sends the app: `{"type":"request","id":"…","tool":"list_photos","args":{…}}`

The app answers with any number of `{"type":"part","id":"…","content":[…]}` messages and then one `{"type":"done","id":"…","content":[…]}`, or `{"type":"error","id":"…","message":"…"}`. Content items use the MCP shapes: `{"type":"text","text":"…"}` or `{"type":"image","data":"<base64 JPEG>","mimeType":"image/jpeg"}`. One image per message keeps each message small.

The app sends `{"type":"ping"}` every 20 seconds; the relay answers `{"type":"pong"}`.

## Secrets (Settings > Secrets and variables > Actions)

| Name | What it is |
| --- | --- |
| `RELAY_TOKEN` | A long random password shared by the relay, the app, and the Claude connector |
| `CLOUDFLARE_API_TOKEN` | Lets GitHub deploy the relay |
| `CLOUDFLARE_ACCOUNT_ID` | Your Cloudflare account ID |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_KEY_P8` | The full text of the downloaded `.p8` key file |
| `APPLE_TEAM_ID` | Your Apple Developer team ID |
