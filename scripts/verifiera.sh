#!/usr/bin/env bash
# Verifierar delmomenten efter deploy. Användning: ./scripts/verifiera.sh [prod|test]
set -uo pipefail

MILJO="${1:-prod}"
if [ "$MILJO" = "prod" ]; then RG="rg-nordvik"; else RG="rg-nordvik-$MILJO"; fi

OUT="$(az deployment group list -g "$RG" --query "[?properties.provisioningState=='Succeeded'] | sort_by(@, &properties.timestamp) | [-1].properties.outputs" -o json)"
FUNC="$(jq -r '.funktionsapp.value' <<<"$OUT")"
HOST="$(jq -r '.hostnamn.value' <<<"$OUT")"
DATA="$(jq -r '.dataLagring.value' <<<"$OUT")"

OK=0; FEL=0
check() { if [ "$1" = "0" ]; then echo "  [OK]  $2"; OK=$((OK+1)); else echo "  [FEL] $2"; FEL=$((FEL+1)); fi; }
rubrik() { echo; echo "== $*"; }

rubrik "Compute: portalen svarar"
HALSA="$(curl -s "https://$HOST/halsa")"
echo "  /halsa -> $HALSA"
[ "$(jq -r '.app' <<<"$HALSA" 2>/dev/null)" = "ok" ]; check $? "Function-appen kör"
[ "$(jq -r '.lagring' <<<"$HALSA" 2>/dev/null)" = "ok" ]; check $? "Appen når lagringen via private endpoint och managed identity"
[ "$(jq -r '.flode' <<<"$HALSA" 2>/dev/null)" = "konfigurerat" ]; check $? "Power Automate-URL är konfigurerad"

rubrik "IAM: inloggning krävs för formuläret"
KOD="$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/felanmalan")"
echo "  /felanmalan utan inloggning -> HTTP $KOD"
[[ "$KOD" =~ ^(302|401)$ ]]; check $? "Oinloggade skickas till Entra ID-inloggning"

rubrik "IAM: rolltilldelningar i $RG"
az role assignment list --all \
  --query "[?ends_with(scope, '/$RG') || contains(scope, '/$RG/')].{roll:roleDefinitionName, vem:principalName || principalId, typ:principalType, scope:scope}" -o table

rubrik "Storage: säkerhetsinställningar för $DATA"
az storage account show -n "$DATA" -g "$RG" \
  --query "{publiktNatverk:publicNetworkAccess, publikaBlobbar:allowBlobPublicAccess, nycklar:allowSharedKeyAccess, tls:minimumTlsVersion, sku:sku.name}" -o table
[ "$(az storage account show -n "$DATA" -g "$RG" --query allowBlobPublicAccess -o tsv)" = "false" ]; check $? "Publik blobåtkomst avstängd"
[ "$(az storage account show -n "$DATA" -g "$RG" --query allowSharedKeyAccess -o tsv)" = "false" ]; check $? "Åtkomstnycklar avstängda (bara Entra ID)"

rubrik "Nätverk: lagringen ska INTE gå att nå härifrån (internet)"
if az storage blob list --account-name "$DATA" -c felanmalningar --auth-mode login --num-results 1 -o none 2>/tmp/nv-fel.txt; then
  check 1 "Lagringen nåddes utifrån, det ska inte gå"
else
  echo "  Förväntat fel: $(head -c 160 /tmp/nv-fel.txt | tr '\n' ' ')"
  check 0 "Lagringen är stängd för publikt nätverk"
fi
PE_STATUS="$(az network private-endpoint show -g "$RG" -n "pe-nordvik-blob$([ "$MILJO" = prod ] || echo "-$MILJO")" \
  --query 'privateLinkServiceConnections[0].privateLinkServiceConnectionState.status' -o tsv)"
[ "$PE_STATUS" = "Approved" ]; check $? "Private endpoint godkänd ($PE_STATUS)"
echo "  NSG-regler:"
for nsg in $(az network nsg list -g "$RG" --query '[].name' -o tsv); do
  az network nsg rule list -g "$RG" --nsg-name "$nsg" \
    --query "[].{nsg:'$nsg', namn:name, prio:priority, riktning:direction, atkomst:access, port:destinationPortRange}" -o table
done

rubrik "Taggar: alla resurser ska ha miljo, avdelning och fastighet"
az resource list -g "$RG" --query "[].{namn:name, miljo:tags.miljo, avdelning:tags.avdelning, fastighet:tags.fastighet}" -o table
SAKNAS="$(az resource list -g "$RG" --query "length([?tags.miljo==null || tags.avdelning==null || tags.fastighet==null])" -o tsv)"
[ "$SAKNAS" = "0" ]; check $? "Inga otaggade resurser ($SAKNAS saknar taggar)"

echo
echo "Resultat: $OK OK, $FEL FEL"
[ "$FEL" = "0" ]
