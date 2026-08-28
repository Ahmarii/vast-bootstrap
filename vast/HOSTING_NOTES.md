# Hosting the Provisioning Script

Use a raw HTTPS URL. Vast pulls the script directly, so fancy pages are useless here.

Best option:
- GitHub repo or GitHub gist, then use the raw file URL

Why:
- Cheap
- Stable enough
- Easy to version
- Easy to replace without rebuilding the template

What not to do:
- Do not point Vast at a normal GitHub HTML page
- Do not use a local file path from your PC
- Do not rely on this workspace folder unless it is inside a real git repo that you can publish

Recommended layout:
- `provision_rtxez_base.sh`
- later add workflow-specific scripts like `provision_krea2_edit.sh` and `provision_minimax_h3_rtx_ez.sh`

Example raw URLs:
- `https://raw.githubusercontent.com/<user>/<repo>/main/vast/provision_rtxez_base.sh`
- `https://gist.githubusercontent.com/<user>/<gist-id>/raw/provision_rtxez_base.sh`

Recommendation:
- Start with a dedicated GitHub repo just for Vast bootstrap scripts. Keep it tiny and boring.
