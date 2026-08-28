param(
  [Parameter(Mandatory = $true)]
  [string]$ProvisioningScriptUrl,

  [string]$TemplateFile = "D:\01-WNORKDESK\MINIKrea2\vast\template_rtxez_provisioned.json",

  [string]$VastApiToken = $env:VAST_API_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $VastApiToken) {
  throw "Set VAST_API_TOKEN in your shell or pass -VastApiToken explicitly."
}

if (-not (Test-Path -LiteralPath $TemplateFile)) {
  throw "Template file not found: $TemplateFile"
}

$raw = Get-Content -LiteralPath $TemplateFile -Raw
$body = $raw.Replace("PROVISIONING_SCRIPT_URL", $ProvisioningScriptUrl)

$headers = @{
  Authorization = "Bearer $VastApiToken"
  "Content-Type" = "application/json"
}

$response = Invoke-RestMethod `
  -Method Post `
  -Uri "https://console.vast.ai/api/v0/template" `
  -Headers $headers `
  -Body $body

$response | ConvertTo-Json -Depth 10
