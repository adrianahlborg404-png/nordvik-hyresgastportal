#!/usr/bin/env bash
# Tar bort en miljö (resursgruppen med allt i). Användning: ./scripts/ta-bort.sh test
set -euo pipefail
MILJO="${1:?Ange miljö: test, demo eller prod}"
if [ "$MILJO" = "prod" ]; then RG="rg-nordvik"; else RG="rg-nordvik-$MILJO"; fi
read -r -p "Ta bort $RG och ALLT i den, inklusive sparade anmälningar? Skriv namnet för att bekräfta: " svar
[ "$svar" = "$RG" ] || { echo "Avbrutet."; exit 1; }
az group delete -n "$RG" --yes --no-wait
echo "Borttagning av $RG startad. Entra-grupperna (delas mellan miljöer) och appregistreringen app-nordvik-felanmalan för miljön ligger kvar i Entra ID."
