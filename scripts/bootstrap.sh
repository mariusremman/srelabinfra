#!/usr/bin/env bash
# Engangsoppsett: lager en Entra-app med federert identitet (OIDC) for GitHub Actions,
# gir den tilgang til subscriptionen, registrerer resource providers og setter
# variabler/secrets i GitHub-repoet.
#
# Krav: az login (Owner på subscriptionen), gh auth login.
# Bruk:  ./scripts/bootstrap.sh <subscription-id> [github-repo] [miljø]
set -euo pipefail

SUBSCRIPTION_ID="${1:?Oppgi subscription-id}"
REPO="${2:-mariusremman/srelabinfra}"
ENVIRONMENT="${3:-dev}"
APP_NAME="gh-${REPO//\//-}"

az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)

echo ">> Registrerer resource providers"
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL Microsoft.KeyVault \
  Microsoft.ManagedIdentity Microsoft.Network Microsoft.OperationalInsights Microsoft.Insights; do
  az provider register --namespace "$ns" --output none
done

echo ">> Oppretter/finner Entra-app $APP_NAME"
CLIENT_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
fi
az ad sp show --id "$CLIENT_ID" --output none 2>/dev/null || az ad sp create --id "$CLIENT_ID" --output none
SP_OBJECT_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)

echo ">> Federerte credentials (main, pull_request, environment:$ENVIRONMENT)"
add_fic() {
  local name="$1" subject="$2"
  if ! az ad app federated-credential list --id "$CLIENT_ID" --query "[?name=='$name']" -o tsv | grep -q .; then
    az ad app federated-credential create --id "$CLIENT_ID" --output none --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }"
  fi
}
add_fic "main" "repo:${REPO}:ref:refs/heads/main"
add_fic "pull-request" "repo:${REPO}:pull_request"
add_fic "env-${ENVIRONMENT}" "repo:${REPO}:environment:${ENVIRONMENT}"

echo ">> Rolletildelinger på subscription"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
# Contributor for ressursene, RBAC Administrator for rolletildelingene i Bicep (AcrPull, KV Secrets User).
for role in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$SCOPE" --output none
done

echo ">> GitHub-variabler og secrets i $REPO"
gh api --method PUT "repos/${REPO}/environments/${ENVIRONMENT}" --silent
gh variable set AZURE_CLIENT_ID --repo "$REPO" --body "$CLIENT_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUBSCRIPTION_ID"
gh variable set ENVIRONMENT_NAME --repo "$REPO" --body "$ENVIRONMENT"

if ! gh secret list --repo "$REPO" | grep -q '^POSTGRES_ADMIN_PASSWORD'; then
  PG_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)Aa1!"
  gh secret set POSTGRES_ADMIN_PASSWORD --repo "$REPO" --body "$PG_PASSWORD"
  echo "   Genererte POSTGRES_ADMIN_PASSWORD (lagret som GitHub secret)."
fi

echo ""
echo "Ferdig. Kjør workflowen 'infra' (Actions -> infra -> Run workflow) eller push til main."
