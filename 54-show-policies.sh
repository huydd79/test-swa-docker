#!/bin/bash
# 54-show-policies.sh [prod|dev] - Show the SWA policy of each environment (default: both):
#   trust domain, server group (x509pop CA), server components, node group template + registration policies.
source "$(dirname "$0")/lib.sh"
for e in ${1:-$ENVS}; do
  env_load "$e"
  echo "===== $ENV : trust domain $TD"
  api GET "/trust-domains/$TD/server-groups/$SG"
  [ "$CODE" = 200 ] || { echo "  server group $SG: HTTP $CODE"; continue; }
  CA=$(jq -r '.node_attestation.x509pop.ca_certificates // .attestation.x509pop.ca_certificates // empty' <<<"$BODY")
  echo "server group : $SG  (x509pop CA: $( [ -n "$CA" ] && openssl x509 -noout -subject <<<"$CA" | sed 's/^subject=//' || echo none))"
  api GET "/trust-domains/$TD/server-groups/$SG/components"
  echo "servers      : $(jq -r '[.. | objects | select(has("authn_id") or has("authentication")) | .name] | unique | join(", ")' <<<"$BODY")"
  api GET "/trust-domains/$TD/server-groups/$SG/node-groups/$NG"
  [ "$CODE" = 200 ] || { echo "  node group $NG: HTTP $CODE"; continue; }
  echo "node group   : $NG (workload_type $(jq -r .workload_type <<<"$BODY"), updated $(jq -r .updated_at <<<"$BODY"))"
  jq '.workload_configuration' <<<"$BODY"
done
