#!/usr/bin/env bash
# Återskapar Nordviks hyresgästportal från repot: infrastruktur (ARM) + appkod.
#
# Användning (från repo-roten, t.ex. i Azure Cloud Shell):
#   ./scripts/deploy.sh prod        -> rg-nordvik
#   ./scripts/deploy.sh test        -> rg-nordvik-test (likadan miljö för test/demo)
#
# Valfria miljövariabler:
#   FLOW_URL   HTTP-URL:en från Power Automate-flödet (annars frågar skriptet)
#   ADMIN_IP   din publika IP om du tillfälligt vill nå datalagringen utifrån
#   AUTO=1     hoppa över bekräftelsen efter what-if
set -euo pipefail

MILJO="${1:-prod}"
case "$MILJO" in
  prod)      RG="rg-nordvik";        SUFFIX="" ;;
  test|demo) RG="rg-nordvik-$MILJO"; SUFFIX="-$MILJO" ;;
  *) echo "Okänd miljö '$MILJO'. Använd prod, test eller demo."; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/infra/azuredeploy.json"
PARAMS="$ROOT/infra/azuredeploy.parameters.$MILJO.json"
[ -f "$PARAMS" ] || PARAMS="$ROOT/infra/azuredeploy.parameters.test.json"
LOCATION="$(jq -r '.parameters.location.value' "$PARAMS")"
APPREG_NAMN="app-nordvik-felanmalan$SUFFIX"

ANV="$(jq -r '.parameters.anvandarnamn.value' "$PARAMS")"
if [[ "$ANV" == "bytmig" || ! "$ANV" =~ ^[a-z0-9]{2,13}$ ]]; then
  echo "Sätt ditt användarnamn (2-13 tecken, a-z och 0-9) i $PARAMS först."
  exit 1
fi

steg() { echo; echo "==> $*"; }

steg "1/8 Registrerar resursproviders (Microsoft.App krävs för Flex Consumption)"
for p in Microsoft.App Microsoft.Web Microsoft.Storage Microsoft.Network; do
  az provider register --namespace "$p" --wait -o none
done
az provider register --namespace Microsoft.Consumption -o none 2>/dev/null || true

steg "2/8 Resursgrupp $RG i $LOCATION"
az group create -n "$RG" -l "$LOCATION" -o none \
  --tags foretag="Nordvik Fastigheter AB" projekt=hyresgastportal miljo="$MILJO" \
         avdelning="$(jq -r '.parameters.avdelning.value' "$PARAMS")" fastighet=gemensam skapad-av=deploy.sh

steg "3/8 Entra ID-grupper för rollerna"
grupp() {
  local namn="$1" beskrivning="$2" id
  id="$(az ad group list --display-name "$namn" --query '[0].id' -o tsv)"
  if [ -z "$id" ]; then
    id="$(az ad group create --display-name "$namn" --mail-nickname "$namn" \
          --description "$beskrivning" --query id -o tsv)"
    echo "   skapade $namn" >&2
  else
    echo "   $namn finns redan" >&2
  fi
  echo "$id"
}
FORVALTARE_ID="$(grupp grp-nordvik-forvaltare 'Nordvik förvaltare: hanterar felanmälningar och kontrakt')"
EKONOMI_ID="$(grupp grp-nordvik-ekonomi 'Nordvik ekonomi: läsande insyn i kontrakt och kostnader')"

steg "4/8 Power Automate och appregistrering"
if [ -z "${FLOW_URL:-}" ]; then
  read -r -s -p "   Klistra in HTTP-URL:en från flödets trigger (Enter = hoppa över): " FLOW_URL || true
  echo
fi
[ -n "$FLOW_URL" ] || echo "   OBS: ingen FLOW_URL, anmälningar sparas men ingen notis skickas."
CLIENT_ID="$(az ad app list --display-name "$APPREG_NAMN" --query '[0].appId' -o tsv)"

PARAM_ARGS=(--parameters "@$PARAMS"
  "forvaltareGroupId=$FORVALTARE_ID"
  "ekonomiGroupId=$EKONOMI_ID"
  "flowUrl=$FLOW_URL"
  "authClientId=$CLIENT_ID"
  "adminIpAdress=${ADMIN_IP:-}")

steg "5/8 What-if (förhandsgranskning)"
az deployment group what-if -g "$RG" --template-file "$TEMPLATE" "${PARAM_ARGS[@]}"
if [ "${AUTO:-0}" != "1" ]; then
  read -r -p "Fortsätt med deploy? [j/N] " svar
  [[ "$svar" =~ ^[jJ]$ ]] || { echo "Avbrutet."; exit 0; }
fi

deploya() {
  az deployment group create -g "$RG" -n "nordvik-$(date +%Y%m%d-%H%M%S)" \
    --template-file "$TEMPLATE" "${PARAM_ARGS[@]}" --query properties.outputs -o json
}

steg "6/8 Deploy av infrastrukturen"
OUT="$(deploya)"
FUNC="$(jq -r '.funktionsapp.value' <<<"$OUT")"
HOST="$(jq -r '.hostnamn.value' <<<"$OUT")"
REDIRECT="https://$HOST/.auth/login/aad/callback"

steg "7/8 Inloggning med Entra ID"
if [ -z "$CLIENT_ID" ]; then
  CLIENT_ID="$(az ad app create --display-name "$APPREG_NAMN" --sign-in-audience AzureADMyOrg \
               --web-redirect-uris "$REDIRECT" --enable-id-token-issuance true --query appId -o tsv)"
  az ad sp create --id "$CLIENT_ID" -o none 2>/dev/null || true
  echo "   skapade appregistreringen $APPREG_NAMN ($CLIENT_ID), deployar igen med inloggning på"
  PARAM_ARGS[5]="authClientId=$CLIENT_ID"
  OUT="$(deploya)"
else
  az ad app update --id "$CLIENT_ID" --web-redirect-uris "$REDIRECT" --enable-id-token-issuance true -o none
  echo "   appregistreringen finns, redirect-URI uppdaterad"
fi

steg "8/8 Deploy av appkoden (remote build)"
TMP="$(mktemp -d)"
( cd "$ROOT/app" && zip -r -q "$TMP/app.zip" . -x '.venv/*' '__pycache__/*' 'local.settings.json' )
az functionapp deployment source config-zip -g "$RG" -n "$FUNC" --src "$TMP/app.zip" --build-remote true -o none
rm -rf "$TMP"

echo
echo "Klart."
echo "  Portal:        $(jq -r '.portalUrl.value' <<<"$OUT")"
echo "  Hälsokontroll: https://$HOST/halsa"
echo "  Datalagring:   $(jq -r '.dataLagring.value' <<<"$OUT") (ingen publik åtkomst)"
echo "Rolltilldelningar kan ta några minuter att slå igenom. Kör sedan ./scripts/verifiera.sh $MILJO"
