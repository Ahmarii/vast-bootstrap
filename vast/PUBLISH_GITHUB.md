# Publish the Vast Bootstrap Files

This folder is not a git repo right now, so GitHub Raw does not exist yet. That is the whole problem.

## What to publish

At minimum, publish these files:

- `vast/provision_rtxez_base.sh`
- `vast/template_rtxez_provisioned.json`
- `vast/create_provisioned_template.ps1`

## Recommended repo

Create a tiny separate repo just for Vast bootstrap files. Do not dump your whole local workspace into it unless you enjoy future cleanup pain.

Suggested repo name:

- `vast-bootstrap`

Suggested structure:

```text
vast-bootstrap/
  vast/
    provision_rtxez_base.sh
    template_rtxez_provisioned.json
    create_provisioned_template.ps1
    HOSTING_NOTES.md
    PUBLISH_GITHUB.md
```

## GitHub web flow

1. Create a new repo on GitHub.
2. Upload the `vast/` folder contents.
3. Open `vast/provision_rtxez_base.sh` on GitHub.
4. Click `Raw`.
5. Copy the raw URL.

Raw URL should look like this:

```text
https://raw.githubusercontent.com/<your-user>/vast-bootstrap/main/vast/provision_rtxez_base.sh
```

## Git CLI flow

If you want the actual commands:

```bash
mkdir vast-bootstrap
cd vast-bootstrap
git init
mkdir vast
cp /path/to/provision_rtxez_base.sh vast/
cp /path/to/template_rtxez_provisioned.json vast/
cp /path/to/create_provisioned_template.ps1 vast/
cp /path/to/HOSTING_NOTES.md vast/
cp /path/to/PUBLISH_GITHUB.md vast/
git add .
git commit -m "Add Vast bootstrap scripts"
git branch -M main
git remote add origin https://github.com/<your-user>/vast-bootstrap.git
git push -u origin main
```

On Windows PowerShell, use `Copy-Item` instead of `cp` if needed.

## Create the provisioned template after publishing

Once you have the raw URL:

```powershell
$env:VAST_API_TOKEN = "your_vast_api_token"
powershell -ExecutionPolicy Bypass -File D:\01-WNORKDESK\MINIKrea2\vast\create_provisioned_template.ps1 `
  -ProvisioningScriptUrl "https://raw.githubusercontent.com/<your-user>/vast-bootstrap/main/vast/provision_rtxez_base.sh"
```

That creates the second Vast template with `PROVISIONING_SCRIPT` already wired in.

## Recommendation

Do the GitHub repo first. After that, the next useful step is not more template fiddling. It is expanding `provision_rtxez_base.sh` so it installs the node packs and downloader stack automatically.
