#!/usr/bin/env bash
# Skriver ut hela miljöns konfiguration per delmoment, som underlag till dokumentationen.
# Användning: ./scripts/oversikt.sh [prod|test] | tee oversikt.txt
set -uo pipefail

MILJO="${1:-prod}"
if [ "$MILJO" = "prod" ]; then RG="rg-nordvik"; SUFFIX=""; else RG="rg-nordvik-$MILJO"; SUFFIX="-$MILJO"; fi

OUT="$(az deployment group list -g "$RG" --query "[?properties.provisioningState=='Succeeded'] | sort_by(@, &properties.timestamp) | [-1].properties.outputs" -o json)"
FUNC="$(jq -r '.funktionsapp.value' <<<"$OUT")"
DATA="$(jq -r '.dataLagring.value' <<<"$OUT")"
HOSTST="$(jq -r '.hostLagring.value' <<<"$OUT")"
FUNC_ID="$(az functionapp show -g "$RG" -n "$FUNC" --query id -o tsv)"

rubrik() { echo; echo "================================================================"; echo "  $*"; echo "================================================================"; }
del()    { echo; echo "--- $*"; }
prova()  { "$@" 2>/dev/null || echo "  (kunde inte läsas)"; }

echo "Översikt för $RG, $(date '+%Y-%m-%d %H:%M')"

rubrik "RESURSGRUPP: alla resurser"
prova az resource list -g "$RG" --query "sort_by(@, &type)[].{Namn:name, Typ:type, Plats:location}" -o table

rubrik "1 COMPUTE: Function App på Flex Consumption"
prova az resource show --ids "$FUNC_ID" --api-version 2024-04-01 --query "{Namn:name, Status:properties.state, Plan:properties.sku, Runtime:join(' ', [properties.functionAppConfig.runtime.name, properties.functionAppConfig.runtime.version]), MaxInstanser:properties.functionAppConfig.scaleAndConcurrency.maximumInstanceCount, MinneMB:properties.functionAppConfig.scaleAndConcurrency.instanceMemoryMB, BaraHttps:properties.httpsOnly, Adress:properties.defaultHostName}" -o yaml
del "Plan"
prova az appservice plan list -g "$RG" --query "[].{Namn:name, Sku:sku.name, Niva:sku.tier}" -o table
del "Hälsokontroll /halsa"
curl -s "https://$(az functionapp show -g "$RG" -n "$FUNC" --query defaultHostName -o tsv)/halsa"; echo

rubrik "2 IAM: identiteter och behörigheter"
del "Function-appens managed identity"
prova az functionapp identity show -g "$RG" -n "$FUNC" --query "{Typ:type, ObjectId:principalId}" -o table
del "Inloggning med Entra ID (App Service Authentication)"
prova az resource show --ids "$FUNC_ID/config/authsettingsV2" --api-version 2024-04-01 --query "{Aktiverad:properties.platform.enabled, InloggningKravs:properties.globalValidation.requireAuthentication, OinloggadeSkickasTill:properties.globalValidation.redirectToProvider, Undantag:join(', ', properties.globalValidation.excludedPaths)}" -o table
del "Entra ID-grupper"
prova az ad group list --filter "startswith(displayName,'grp-nordvik')" --query "[].{Grupp:displayName, Beskrivning:description}" -o table
del "Appregistrering för inloggningen"
prova az ad app list --display-name "app-nordvik-felanmalan$SUFFIX" --query "[].{Namn:displayName, AppId:appId, Inloggning:signInAudience}" -o table
del "Rolltilldelningar (least privilege)"
prova az role assignment list --all --query "[?ends_with(scope, '/$RG') || contains(scope, '/$RG/')].{Roll:roleDefinitionName, Vem:principalName || principalId, Typ:principalType, Omfang:scope}" -o table

rubrik "3 NÄTVERK OCH SÄKERHET"
del "VNet och subnät"
prova az network vnet subnet list -g "$RG" --vnet-name "vnet-nordvik$SUFFIX" --query "[].{Subnat:name, Adresser:addressPrefix, HarNsg:networkSecurityGroup!=null, Delegering:delegations[0].serviceName, PrivatUtgaende:defaultOutboundAccess==\`false\`}" -o table
del "NSG-regler"
for nsg in $(az network nsg list -g "$RG" --query '[].name' -o tsv); do
  az network nsg rule list -g "$RG" --nsg-name "$nsg" \
    --query "sort_by(@, &priority)[].{NSG:'$nsg', Regel:name, Prio:priority, Riktning:direction, Atkomst:access, Fran:sourceAddressPrefix, Till:destinationAddressPrefix, Port:destinationPortRange}" -o table
done
del "VNet-integration för Function-appen"
prova az resource show --ids "$FUNC_ID" --api-version 2024-04-01 --query "{Subnat:properties.virtualNetworkSubnetId}" -o tsv
del "Private endpoint"
prova az network private-endpoint list -g "$RG" --query "[].{Namn:name, Status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, Tjanst:privateLinkServiceConnections[0].groupIds[0]}" -o table
prova az network nic show -g "$RG" -n "nic-nordvik-pe$SUFFIX" --query "{Natverkskort:name, PrivatIP:ipConfigurations[0].privateIPAddress}" -o table
del "Privat DNS: lagringens namn pekar på det privata IP:t"
prova az network private-dns record-set a list -g "$RG" -z privatelink.blob.core.windows.net --query "[].{Namn:name, IP:aRecords[0].ipv4Address}" -o table
del "Försök att nå lagringen från internet (ska misslyckas)"
if az storage blob list --account-name "$DATA" -c felanmalningar --auth-mode login --num-results 1 -o none 2>/tmp/nv-oversikt.txt; then
  echo "  Lagringen nåddes utifrån. Det ska inte gå!"
else
  echo "  Blockerad, som förväntat: $(head -c 120 /tmp/nv-oversikt.txt | tr '\n' ' ')"
fi

rubrik "4 STORAGE"
for st in "$DATA" "$HOSTST"; do
  del "Lagringskonto $st"
  prova az storage account show -g "$RG" -n "$st" --query "{Sku:sku.name, PubliktNatverk:publicNetworkAccess, StandardRegel:networkAcls.defaultAction, PublikaBlobbar:allowBlobPublicAccess, Atkomstnycklar:allowSharedKeyAccess, MinTls:minimumTlsVersion, BaraHttps:enableHttpsTrafficOnly}" -o table
  prova az storage container-rm list -g "$RG" --storage-account "$st" --query "[].{Container:name, PublikAtkomst:publicAccess}" -o table
done
del "Livscykelregler för $DATA"
prova az storage account management-policy show -g "$RG" --account-name "$DATA" --query "policy.rules[].{Regel:name, Prefix:join(', ', definition.filters.prefixMatch), TillCoolEfterDagar:definition.actions.baseBlob.tierToCool.daysAfterModificationGreaterThan, RaderasEfterDagar:definition.actions.baseBlob.delete.daysAfterModificationGreaterThan}" -o table
del "Mjuk radering för $DATA"
prova az storage account blob-service-properties show -g "$RG" --account-name "$DATA" --query "{BlobbarDagar:deleteRetentionPolicy.days, ContainrarDagar:containerDeleteRetentionPolicy.days}" -o table

rubrik "5 IaC: deployer från ARM-templaten"
prova az deployment group list -g "$RG" --query "sort_by(@, &properties.timestamp)[].{Deploy:name, Status:properties.provisioningState, Tid:properties.timestamp}" -o table

rubrik "KOSTNAD OCH UPPFÖLJNING"
del "Taggar per resurs"
prova az resource list -g "$RG" --query "[].{Namn:name, miljo:tags.miljo, avdelning:tags.avdelning, fastighet:tags.fastighet, projekt:tags.projekt}" -o table
del "Budget"
prova az consumption budget list --resource-group "$RG" --query "[].{Budget:name, Belopp:amount, Period:timeGrain, Larm:join(', ', keys(notifications))}" -o table

echo
echo "Klart."
