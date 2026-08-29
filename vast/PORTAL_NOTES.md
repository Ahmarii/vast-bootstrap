# Vast Portal Notes

Date: 2026-08-28

What the original `vastai/comfy:v0.30.0-cuda-13.2-py312` portal does:

- `/opt/supervisor-scripts/instance_portal.sh` starts a FastAPI app from `/opt/portal-aio/portal/portal.py` on `127.0.0.1:11111`.
- `/opt/supervisor-scripts/caddy.sh` runs `/opt/portal-aio/caddy_manager/caddy_config_manager.py`, which reads `PORTAL_CONFIG` or `/etc/portal.yaml` and writes `/etc/Caddyfile`.
- The frontend card layout is rendered by `/opt/portal-aio/portal/templates/index.html` and `/opt/portal-aio/portal/static/assets/portal.js`.
- App cards come from `PORTAL_CONFIG` entries in this format:
  `hostname:external_port:internal_port:path:name`

What broke in our custom setup:

- We replaced the stock portal with a lightweight Python server but did not answer `HEAD` requests.
- Vast’s open-button readiness check appears to require a successful `HEAD` response.
- Earlier templates also mapped `-p 1111:11111`, while our custom server listened on `1111`. That mismatch was unnecessary for the custom portal path.

What we changed:

- The custom portal now listens on `OPEN_BUTTON_PORT` directly.
- It answers both `GET` and `HEAD` on `/`, `/healthz`, `/status.json`, and `/debug.json`.
- The UI now mirrors the Vast portal structure:
  - sidebar with machine stats
  - application cards
  - advanced connection details
  - provisioning phase
  - live log tails
  - tracked model file sizes
- Template env now uses `-p 1111:1111`.
- Template env also carries a valid `PORTAL_CONFIG` value so a future switch back to the stock portal remains straightforward.

Recommendation:

- Keep the custom portal as the open-button target because it is available immediately and can show bootstrap progress before ComfyUI is ready.
- Keep `PORTAL_CONFIG` populated anyway. It costs almost nothing and preserves compatibility with the stock Vast portal stack.

Update on August 29, 2026:

- The template `onstart` path now fetches `rtxez_onstart_entrypoint.sh`, not the heavy bootstrap directly.
- That entrypoint writes an initial `status.json`, launches the Vast-style custom portal immediately on `OPEN_BUTTON_PORT`, and only then fetches and launches `rtxez_onstart_bootstrap_v2.sh`.
- Result: the portal becomes visible first, while node installs and model downloads continue behind it.
