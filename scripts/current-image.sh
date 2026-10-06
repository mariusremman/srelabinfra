#!/usr/bin/env bash
# Finner imaget container appen kjører nå, slik at en infra-deploy ikke ruller
# tilbake til placeholder-imaget etter at app-repoet har deployet sin versjon.
# Skriver CONTAINER_IMAGE til $GITHUB_ENV (eller stdout lokalt).
set -euo pipefail

rg="rg-${NAME_PREFIX}-${ENVIRONMENT_NAME}"
app="ca-${NAME_PREFIX}-${ENVIRONMENT_NAME}"

image=$(az resource show \
  --resource-group "$rg" \
  --name "$app" \
  --resource-type Microsoft.App/containerApps \
  --query "properties.template.containers[0].image" \
  --output tsv 2>/dev/null || true)

# Placeholder-imaget håndteres i Bicep (tom verdi = placeholder på port 80).
if [[ "$image" == mcr.microsoft.com/k8se/quickstart* ]]; then
  image=""
fi

echo "Gjeldende image: ${image:-<placeholder>}"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "CONTAINER_IMAGE=${image}" >> "$GITHUB_ENV"
else
  echo "export CONTAINER_IMAGE=${image}"
fi
