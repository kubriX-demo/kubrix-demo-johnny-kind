#!/bin/bash

# just for troubleshooting
if [ "${KUBRIX_INSTALL_DEBUG}" == true ]; then
  set -x 
fi

fail() {
  echo $1
  exit "${2-1}"
}

check_tool() {
  tool=$1
  command=$2
  version_output="${3-}"
  version=$( ${command} ) || fail "prereq check failed: ${tool} not found"
  echo "${tool} found with version '${version}'"
}

check_variable() {
  variable=$1
  if [ -z "${!variable}" ]; then
    echo ""
    echo "prereq check failed: variable '${variable}' is blank or not set"
    exit 1
  else
    echo "${variable} is set to '${!variable}'"
  fi
}

check_prereqs() {
  echo ""
  echo "Checking prereqs ..."
  echo "arch: ${ARCH}"
  echo "os: ${OS}"

  # check tools
  check_tool yq "yq --version"
  check_tool jq "jq --version"
  check_tool kubectl "kubectl version --client=true"
  check_tool helm "helm version"
  check_tool curl "curl -V | head -1"

  if [[ "${KUBRIX_TARGET_TYPE}" =~ ^KIND.* || "${KUBRIX_CLUSTER_TYPE}" == "KIND" ]] ; then
    check_tool mkcert "mkcert --version"
  fi

  # check variables
  check_variable KUBRIX_REPO
  check_variable KUBRIX_REPO_BRANCH
  check_variable KUBRIX_REPO_USERNAME
  check_variable KUBRIX_REPO_PASSWORD
  check_variable KUBRIX_TARGET_TYPE

  echo "Prereq checks finished sucessfully."
  echo ""
}

convert_to_seconds() {
  local timestamp=$1
  if [[ "$ARCH" == "amd64" || "$ARCH" == "x86_64" ]]; then
    date -d "${timestamp}" '+%s'
  elif [[ "$ARCH" == "arm64" ]]; then
    date -j -f "%Y-%m-%dT%H:%M:%S" "${timestamp}" "+%s"
  else
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
  fi
}

utc_now_seconds() {
  if [[ "$ARCH" == "amd64" || "$ARCH" == "x86_64" ]]; then
    date --date=$(date -u +"%Y-%m-%dT%T") '+%s'
  elif [[ "$ARCH" == "arm64" ]]; then
    date -j -f "%Y-%m-%dT%T" "$(date -u +"%Y-%m-%dT%T")" '+%s'
  else
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
  fi
}

wait_until_apps_synced_healthy() {
  local apps=$1
  local synced=$2
  local healthy=$3
  local max_wait_time=$4

  echo "wait until these apps have reached sync state '${synced}' and health state '${healthy}'"
  echo "apps: ${apps}"
  echo "max wait time: ${max_wait_time}"

  start=$SECONDS
  end=$((SECONDS+${max_wait_time}))

  while [ $SECONDS -lt $end ]; do
    all_apps_synced="true"

    # check if sx-boostrap-app already failed and restart sync
    bootstrap_app="sx-bootstrap-app"
    operation_state_bootstrap_app=$(kubectl get application -n argocd ${bootstrap_app} -o jsonpath='{.status.operationState}')
    if [ "${operation_state_bootstrap_app}" != "" ] ; then
      operation_phase_bootstrap_app=$(kubectl get application -n argocd ${bootstrap_app} -o jsonpath='{.status.operationState.phase}')
      if [ "${operation_phase_bootstrap_app}" = "Failed" ] || [ "${operation_phase_bootstrap_app}" = "Error" ] ; then
        echo "sx-boostrap-app sync failed. Restarting sync ..."
        kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd app terminate-op "$bootstrap_app" --core
        kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd app sync "$bootstrap_app" --async --core
      fi
    fi

    # print app status in beautiful table
    printf 'app sync-status health-status sync-duration operation-phase\n' > status-apps.out

    for app in ${apps} ; do
      if kubectl get application -n argocd ${app} > /dev/null 2>&1 ; then
        sync_status=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.sync.status}')
        health_status=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.health.status}')

        # special case for sx-vault
        if [[ "${app}" == "sx-vault" && "${sync_status}" == "${synced}" && "${health_status}" == "${healthy}" ]]; then
          if [ ! -f ./.secrets/secrettemp/secrets-applied ]; then
            echo "sx-vault is synced and healthy — applying pushsecrets"
            echo 
            kubectl apply -f ./.secrets/secrettemp/pushsecrets.yaml
            touch ./.secrets/secrettemp/secrets-applied
            echo "--------------------"
          fi
        fi

        # special case for k8s-monitoring to re-sync one time after it deployed sucessfully,
        # because of a .Capabilities.APIVersions.Has condition in the templates for monitoring.coreos which gets deployed by k8s-monitoring itself
        if [[ "${app}" == "sx-k8s-monitoring" && "${sync_status}" == "${synced}" && "${health_status}" == "${healthy}" ]]; then
          if [  "${k8smonitoring_restarted}" != "true" ]; then
            kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd app sync "$app" --async --core
            k8smonitoring_restarted="true"
          fi
        fi
        
        if [[ "${sync_status}" != ${synced} ]] || [[ "${health_status}" != ${healthy} ]] ; then
          all_apps_synced="false"
        fi


        # check if app sync is stuck and needs to get restarted
        # if app has no resources, operationState is empty
        operation_state=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.operationState}')
        if [ "${operation_state}" != "" ] ; then
          # from our tests this time is always UTC!
          sync_started=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.operationState.startedAt}' |sed 's/Z$//')
          sync_finished=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.operationState.finishedAt}' |sed 's/Z$//')
          sync_started_seconds=$(convert_to_seconds "${sync_started}")

          # if sync finished, duration is 'finished - started', otherwise its 'now - started'
          if [ "${sync_finished}" != "" ] ; then
            sync_finished_seconds=$(convert_to_seconds "${sync_finished}")
            sync_duration=$((${sync_finished_seconds}-${sync_started_seconds}))
          else
            # since '.status.operationState.startedAt' is always UTC (from our tests)
            #  we need to get 'now' also in UTC
            now_seconds=$(utc_now_seconds)
            sync_finished_seconds="-"
            sync_duration=$((${now_seconds}-${sync_started_seconds}))
          fi
          # terminate sync if sync is running and takes longer than 300 seconds (workaround when sync gets stuck)
          operation_phase=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.operationState.phase}')
          if [ "${operation_phase}" = "Running" ] && [ ${sync_duration} -gt 300 ] || [ "${operation_phase}" = "Failed" ] || [ "${operation_phase}" = "Error" ] ; then
            # Terminate the operation for the application
            echo "sync of app ${app} gets terminated because it took longer than 300 seconds or failed"
            kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd app terminate-op "$app" --core
            echo "wait for 10 seconds"
            sleep 10
            echo "restart sync for app ${app}"
            kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd app sync "$app" --async --core
          fi
        else
            sync_started_seconds="-"
            sync_finished_seconds="-"
            sync_duration="-"
        fi

        # print app status in beautiful table
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' ${app} ${sync_status} ${health_status} ${sync_duration} ${operation_phase} >> status-apps.out

      else
        printf '%s - - - -\n' ${app} >> status-apps.out
        all_apps_synced="false"	
      fi
    done

    # print app status in beautiful table
    cat status-apps.out | column -t
    rm status-apps.out

    if [ ${all_apps_synced} = "true" ] ; then
      echo "${apps} apps are synced"
      break
    fi

    elapsed_time=$((SECONDS-${start}))
    echo "--------------------"
    echo "elapsed time: ${elapsed_time} seconds"
    echo "max wait time: ${max_wait_time} seconds"
    echo "wait another 10 seconds"
    echo "--------------------"
    sleep 10
  done

  if [ ${all_apps_synced} != "true" ] ; then
    echo "not all apps synced and healthy after limit reached :("
    analyze_all_unhealthy_apps "${apps}"
    exit 1
  else
    echo "all apps are synced."
  fi
}

analyze_all_unhealthy_apps() {
  local apps=$1
  for app in ${apps} ; do
    if kubectl get application -n argocd ${app} > /dev/null 2>&1 ; then
      sync_status=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.sync.status}')
      health_status=$(kubectl get application -n argocd ${app} -o jsonpath='{.status.health.status}')

      if [[ "${sync_status}" != ${synced} ]] || [[ "${health_status}" != ${healthy} ]] ; then
        analyze_app ${app}
      fi
    fi
  done
}

analyze_app() {
  local app=$1

  # get target namespace for app
  app_namespace=$( kubectl get applications -n argocd ${app} -o=jsonpath='{.spec.destination.namespace}' )

  echo "------------------"
  echo "starting analyzing unhealthy/unsynced app '${app}'"
  echo "------------------"

  # get application spec and status
  echo "------------------"
  echo "kubectl get application -n argocd ${app} -o yaml"
  kubectl get application -n argocd ${app} -o yaml
  echo "------------------"

  # get events in this namespace
  echo "------------------"
  echo "kubectl get events -n ${app_namespace} --sort-by='.lastTimestamp'"
  kubectl get events -n ${app_namespace} --sort-by='.lastTimestamp'
  echo "------------------"

  # get pods for app
  echo "------------------"
  echo "kubectl get pods -n ${app_namespace}"
  kubectl get pods -n ${app_namespace}
  echo "------------------"

  # describe pods for app
  echo "------------------"
  echo "kubectl describe pod -n ${app_namespace}"
  kubectl describe pod -n ${app_namespace}
  echo "------------------"

  # get logs
  echo "------------------"
  echo "kubectl get pods -o name -n ${app_namespace} | xargs -I {} kubectl logs -n ${app_namespace} {}"
  kubectl get pods -o name -n ${app_namespace} | xargs -I {} kubectl logs -n ${app_namespace} {} --all-containers=true
  echo "------------------"

  echo "------------------"
  echo "finished analyzing degraded app '${app}'"
  echo "------------------"
}

# dump all kubrix variables
env | grep KUBRIX
ARCH=$(uname -m)
OS=$(uname -s)

check_prereqs

if [[ "${KUBRIX_TARGET_TYPE}" =~ ^KIND.* || "${KUBRIX_CLUSTER_TYPE}" == "KIND" || "${CODESPACES}" == "true" ]] ; then
  # create mkcert certs in alle namespaces with ingress
  for namespace in backstage kargo grafana cnpg argocd komoplane kubecost falco minio velero velero-ui; do
    kubectl create namespace ${namespace}
    mkcert -cert-file ${namespace}-cert.pem -key-file ${namespace}-key.pem ${namespace}.127-0-0-1.nip.io
    # kargo needs a special secret name according to its helm chart
    if [ "${namespace}" = "kargo" ]; then
      kubectl create secret tls kargo-api-ingress-cert -n ${namespace} --cert=${namespace}-cert.pem --key=${namespace}-key.pem
    else
      kubectl create secret tls ${namespace}-server-tls -n ${namespace} --cert=${namespace}-cert.pem --key=${namespace}-key.pem
    fi
    # minioconsole needs additional secret
    if [ "${namespace}" = "minio" ]; then
      mkcert -cert-file ${namespace}-console-cert.pem -key-file ${namespace}-console-key.pem minio-console.127-0-0-1.nip.io
      kubectl create secret tls minio-console-tls -n ${namespace} --cert=${namespace}-console-cert.pem --key=${namespace}-console-key.pem
      rm ${namespace}-console-cert.pem ${namespace}-console-key.pem
    fi
    rm ${namespace}-cert.pem ${namespace}-key.pem
  done
  
  # resolv domainname to ingress adress to solve localhost result 
  kubectl get configmap coredns -n kube-system -o yaml |  awk '
/ready/ {
    print;
    print "        rewrite name keycloak.127-0-0-1.nip.io ingress-nginx-controller.ingress-nginx.svc.cluster.local";
    next
}
{ print }
' > coredns-configmap.yaml
  kubectl apply -f coredns-configmap.yaml
  kubectl rollout restart deployment coredns -n kube-system
  rm coredns-configmap.yaml

  # and install nginx ingress-controller
  echo "installing nginx ingress controller in KinD"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

  # create mkcert-issuer
  kubectl create namespace cert-manager
  kubectl create secret tls mkcert-ca-key-pair --key "$(mkcert -CAROOT)"/rootCA-key.pem --cert "$(mkcert -CAROOT)"/rootCA.pem -n cert-manager

  # vault oidc case
  echo "create a root ca and patch ingress-nginx-controller for vault oidc"
  kubectl create namespace vault
  kubectl create secret generic ca-cert --from-file=ca.crt="$(mkcert -CAROOT)"/rootCA.pem -n vault
  kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' -p='[
  {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--enable-ssl-passthrough"
  },
  ]'

  # wait until ingress-nginx-controller is ready
  echo "wait until ingress-nginx-controller is running ..."
  sleep 10
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s

  echo "installing metrics-server in KinD"
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm repo update
  helm upgrade --install --set args={--kubelet-insecure-tls} metrics-server metrics-server/metrics-server --namespace kube-system
fi

# create argocd with helm chart not with install.yaml
# because afterwards argocd is also managed by itself with the helm-chart

echo "installing bootstrap argocd ..."
helm repo add argo-cd https://argoproj.github.io/argo-helm
helm repo update
helm install sx-argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 7.8.24 \
  --namespace argocd \
  --create-namespace \
  --set configs.cm.application.resourceTrackingMethod=annotation \
  -f bootstrap-argocd-values.yaml \
  --wait


# we add the repo inside the application-controller because it could be that clusters do not have any ingress controller installed yet at this moment
echo "add kubriX repo in argocd pod"
kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd repo add ${KUBRIX_REPO} --username ${KUBRIX_REPO_USERNAME} --password ${KUBRIX_REPO_PASSWORD} --core

# create secret for scm applicationset in team app definition namespaces
# see https://github.com/suxess-it/kubriX/issues/214 for a sustainable solution
#for ns in adn-team1 adn-team2 adn-team-a; do
#  kubectl create namespace ${ns}
#  kubectl create secret generic appset-github-token --from-literal=token=${KUBRIX_GITHUB_APPSET_TOKEN} -n ${ns}
#done

# add secrets
echo "Generating default secrets..."
./.secrets/createsecret.sh
kubectl apply -f ./.secrets/secrettemp/secrets.yaml

KUBRIX_REPO_BRANCH_SED=$( echo ${KUBRIX_REPO_BRANCH} | sed 's/\//\\\//g' )
KUBRIX_REPO_SED=$( echo ${KUBRIX_REPO} | sed 's/\//\\\//g' )

# bootstrap-app
cat bootstrap-app-$(echo ${KUBRIX_TARGET_TYPE} | awk '{print tolower($0)}').yaml | sed "s/targetRevision:.*/targetRevision: ${KUBRIX_REPO_BRANCH_SED}/g" | sed "s/repoURL:.*/repoURL: ${KUBRIX_REPO_SED}/g" | kubectl apply -n argocd -f -

# create app list
target_chart_value_file="platform-apps/target-chart/values-$(echo ${KUBRIX_TARGET_TYPE} | awk '{print tolower($0)}').yaml"

argocd_apps=$(cat $target_chart_value_file | egrep -Ev "team-onboarding" | awk '/^  - name:/ { printf "%s", "sx-"$3" "}' )
# list apps which need some sort of special treatment in bootstrap
argocd_apps_without_individual=$(cat $target_chart_value_file | egrep -Ev "backstage|team-onboarding" | awk '/^  - name:/ { printf "%s", "sx-"$3" "}' )

# max wait for 20 minutes until all apps except backstage and kargo are synced and healthy
wait_until_apps_synced_healthy "${argocd_apps_without_individual}" "Synced" "Healthy" ${KUBRIX_BOOTSTRAP_MAX_WAIT_TIME:-1200}

# apply argocd-secret to set a secretKey
kubectl apply -f platform-apps/charts/argocd/manual-secret/argocd-secret.yaml

# if vault is part of this stack, upload token to vault
if [[ $( echo $argocd_apps | grep sx-vault ) ]] ; then
  export VAULT_HOSTNAME=$(kubectl get ingress -o jsonpath='{.items[*].spec.rules[*].host}' -n vault)
  export VAULT_TOKEN=$(kubectl get secret -n vault vault-init -o=jsonpath='{.data.root_token}'  | base64 -d)
  curl -k --header "X-Vault-Token:$VAULT_TOKEN" --request POST --data "{\"data\": {\"VAULT_ADDR\": \"https://${VAULT_HOSTNAME}\", \"VAULT_ADDR_INT\": \"http://sx-vault-active.vault.svc.cluster.local:8200\"}}" https://${VAULT_HOSTNAME}/v1/kubrix-kv/data/security/vault/base

  if [[ "${KUBRIX_TARGET_TYPE}" =~ ^KIND.* || "${KUBRIX_CLUSTER_TYPE}" == "KIND" || "${CODESPACES}" == "true" ]] ; then
  # due to issue #405 this step is needed for kind clusters
    export VAULT_CLIENTSECRET=$(kubectl get secret -n keycloak keycloak-client-credentials -o=jsonpath='{.data.vault}'  | base64 -d)
    export KEYCLOAK_HOSTNAME=$(kubectl get ingress -o jsonpath='{.items[*].spec.rules[*].host}' -n keycloak)
    export CERT=$(awk '{printf "%s\\n", $0}' "$(mkcert -CAROOT)"/rootCA.pem)
    curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request POST --data '{"type": "oidc"}' https://${VAULT_HOSTNAME}/v1/sys/auth/oidc
    MAX_ATTEMPTS=3
    ATTEMPT=1
    while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
      echo "Setting up OIDC auth method, try $ATTEMPT of $MAX_ATTEMPTS"
      RESPONSE=$(curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request POST --data '{
          "oidc_discovery_url": "https://'${KEYCLOAK_HOSTNAME}'/realms/kubrix",
          "oidc_client_id": "vault",
          "oidc_client_secret": "'$VAULT_CLIENTSECRET'",
          "default_role": "default",
          "oidc_discovery_ca_pem": "'"$CERT"'"
        }' https://${VAULT_HOSTNAME}/v1/auth/oidc/config)
      if [[ -z "$(echo "$RESPONSE" | jq -r '.errors | select(.!=null)')" ]]; then
        echo "configure OIDC auth method successful"
        break
      fi  
    sleep 5
    ((ATTEMPT++))
    done
  fi
  # due to issue #422 this step is needed for all clusters
    GROUP_ALIAS_LIST=$(curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request LIST https://${VAULT_HOSTNAME}/v1/identity/group-alias/id)
    if [ -z "$(echo "$GROUP_ALIAS_LIST" | jq -r '.data.keys | length')" ] || [ "$(echo "$GROUP_ALIAS_LIST" | jq -r '.data.keys | length')" -eq 0 ]; then
        echo "No group aliases found. Setting up group aliases..."
        # Get the list of identity groups
        GROUP_LIST=$(curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request LIST https://${VAULT_HOSTNAME}/v1/identity/group/name)
        # Get OIDC accessor
        ACC=$(curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request GET https://${VAULT_HOSTNAME}/v1/sys/auth | jq -r '.["oidc/"].accessor')
        echo "OIDC Accessor: $ACC"
        # Iterate over groups and create group aliases
        echo "$GROUP_LIST" | jq -r '.data.keys[]' | while read -r GROUP_NAME; do
            echo "Processing group: $GROUP_NAME"
            # Get Group ID
            GROUP_ID=$(curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request GET https://${VAULT_HOSTNAME}/v1/identity/group/name/$GROUP_NAME | jq -r '.data.id')
            if [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "null" ]; then
                # Create Group Alias
                RESPONSE=$(curl -k --header "X-Vault-Token: $VAULT_TOKEN" --request POST --data '{"name": "'$GROUP_NAME'", "mount_accessor": "'$ACC'", "canonical_id": "'$GROUP_ID'"}' https://${VAULT_HOSTNAME}/v1/identity/group-alias)
                echo "Group alias created for $GROUP_NAME: $RESPONSE"
            fi
        done
    fi
fi
  
# if backstage is part of this stack, create the manual secret for backstage
if [[ $( echo $argocd_apps | grep sx-backstage ) ]] ; then

  # check if backstage is already synced (it will still be degraded because of the missing secret we create in the next step)
  wait_until_apps_synced_healthy "sx-backstage" "Synced" "*" 900

  echo "adding special configuration for sx-backstage"

  # generate argocd token
  export ARGOCD_AUTH_TOKEN="$( kubectl exec sx-argocd-application-controller-0 -n argocd -- argocd account generate-token --account backstage --core )"

  # generate grafana token
  export GRAFANA_HOSTNAME=$(kubectl get ingress -o jsonpath='{.items[*].spec.rules[*].host}' -n grafana )

  # check if the secret exists and extract credentials if it does
  if kubectl get secret grafana-admin-secret -n grafana &>/dev/null; then
    export GRAFANA_USER=$(kubectl get secret -n grafana grafana-admin-secret -o=jsonpath='{.data.userKey }'  | base64 -d)
    export GRAFANA_PASSWORD=$(kubectl get secret -n grafana grafana-admin-secret -o=jsonpath='{.data.passwordKey }'  | base64 -d)
  else
    # use default credentials
    export GRAFANA_USER="admin"
    export GRAFANA_PASSWORD="prom-operator"
  fi
  if [ "${GRAFANA_HOSTNAME}" != "" ]; then
    ID=$( curl -k -X POST https://${GRAFANA_HOSTNAME}/api/serviceaccounts --user "${GRAFANA_USER}:${GRAFANA_PASSWORD}" -H "Content-Type: application/json" -d '{"name": "backstage","role": "Viewer","isDisabled": false}' | jq -r .id )
    export GRAFANA_TOKEN=$(curl -k -X POST https://${GRAFANA_HOSTNAME}/api/serviceaccounts/${ID}/tokens --user "${GRAFANA_USER}:${GRAFANA_PASSWORD}" -H "Content-Type: application/json" -d '{"name": "backstage"}' | jq -r .key)
  fi
  
  # get backstage-locator token for backstage secret
  export K8S_SA_TOKEN=$( kubectl get secret backstage-locator -n backstage  -o jsonpath='{.data.token}' | base64 -d )

  # create manual-secret secret with all tokens for backstage
  # in github codespace we need additional environment variables to overwrite app-config.yaml
  if [ ${CODESPACES} ]; then
    KEYCLOAK_CODESPACES=""
    GITHUB_CODESPACES="true"
    BACKSTAGE_CODESPACE_URL="https://${CODESPACE_NAME}-6691.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  fi

  # delete secret if it already exists
  if kubectl get secret -n backstage manual-secret > /dev/null 2>&1 ; then
    kubectl delete secret -n backstage manual-secret
  fi
  
  if [ ${KEYCLOAK_CODESPACES} ]; then
    kubectl create secret generic -n backstage manual-secret \
      --from-literal=GITHUB_CLIENTSECRET=${KUBRIX_BACKSTAGE_GITHUB_CLIENTSECRET} \
      --from-literal=GITHUB_CLIENTID=${KUBRIX_BACKSTAGE_GITHUB_CLIENTID} \
      --from-literal=GITHUB_ORG=${GITHUB_ORG} \
      --from-literal=GITHUB_TOKEN=${KUBRIX_BACKSTAGE_GITHUB_TOKEN} \
      --from-literal=K8S_SA_TOKEN=${K8S_SA_TOKEN} \
      --from-literal=ARGOCD_AUTH_TOKEN=${ARGOCD_AUTH_TOKEN} \
      --from-literal=GRAFANA_TOKEN=${GRAFANA_TOKEN} \
      --from-literal=APP_CONFIG_app_baseUrl=${BACKSTAGE_CODESPACE_URL} \
      --from-literal=APP_CONFIG_backend_baseUrl=${BACKSTAGE_CODESPACE_URL} \
      --from-literal=APP_CONFIG_backend_cors_origin=${BACKSTAGE_CODESPACE_URL} \
      --from-literal=APP_CONFIG_auth_providers_oidc_development_callbackUrl=${BACKSTAGE_CODESPACE_URL}/api/auth/oidc/handler/frame \
      --from-literal=APP_CONFIG_auth_providers_oidc_development_clientId=backstage-codespaces \
      --from-literal=APP_CONFIG_auth_providers_oidc_development_metadataUrl=http://keycloak-service.keycloak.svc.cluster.local:8080/realms/kubrix-codespaces \
      --from-literal=APP_CONFIG_auth_provider_github_development_callbackUrl=${BACKSTAGE_CODESPACE_URL}/api/auth/github/handler/frame \
      --from-literal=APP_CONFIG_catalog_providers_keycloakOrg_default_loginRealm=kubrix-codespaces \
      --from-literal=APP_CONFIG_catalog_providers_keycloakOrg_default_realm=kubrix-codespaces \
      --from-literal=APP_CONFIG_catalog_providers_keycloakOrg_default_clientId=kubrix-codespaces \
      --from-literal=APP_CONFIG_catalog_providers_keycloakOrg_default_clientSecret=demosecret

  elif [ ${GITHUB_CODESPACES} ]; then
    kubectl create secret generic -n backstage manual-secret \
    --from-literal=GITHUB_CLIENTSECRET=${KUBRIX_BACKSTAGE_GITHUB_CLIENTSECRET} \
    --from-literal=GITHUB_CLIENTID=${KUBRIX_BACKSTAGE_GITHUB_CLIENTID} \
    --from-literal=GITHUB_ORG=${GITHUB_ORG} \
    --from-literal=GITHUB_TOKEN=${KUBRIX_BACKSTAGE_GITHUB_TOKEN} \
    --from-literal=K8S_SA_TOKEN=${K8S_SA_TOKEN} \
    --from-literal=ARGOCD_AUTH_TOKEN=${ARGOCD_AUTH_TOKEN} \
    --from-literal=GRAFANA_TOKEN=${GRAFANA_TOKEN} \
    --from-literal=APP_CONFIG_app_baseUrl=${BACKSTAGE_CODESPACE_URL} \
    --from-literal=APP_CONFIG_backend_baseUrl=${BACKSTAGE_CODESPACE_URL} \
    --from-literal=APP_CONFIG_backend_cors_origin=${BACKSTAGE_CODESPACE_URL} \
    --from-literal=APP_CONFIG_auth_provider_github_development_callbackUrl=${BACKSTAGE_CODESPACE_URL}/api/auth/github/handler/frame

  else
    kubectl create secret generic -n backstage manual-secret \
    --from-literal=GITHUB_CLIENTSECRET=${KUBRIX_BACKSTAGE_GITHUB_CLIENTSECRET} \
    --from-literal=GITHUB_CLIENTID=${KUBRIX_BACKSTAGE_GITHUB_CLIENTID} \
    --from-literal=GITHUB_ORG=${GITHUB_ORG} \
    --from-literal=GITHUB_TOKEN=${KUBRIX_BACKSTAGE_GITHUB_TOKEN} \
    --from-literal=K8S_SA_TOKEN=${K8S_SA_TOKEN} \
    --from-literal=ARGOCD_AUTH_TOKEN=${ARGOCD_AUTH_TOKEN} \
    --from-literal=GRAFANA_TOKEN=${GRAFANA_TOKEN}
  fi

  # in codespaces we need additional crossplane resources for keycloak
  # because of the port-forwarding URLs
  # if [ ${KEYCLOAK_CODESPACES} ]; then
  #  cat .devcontainer/keycloak-codespaces.yaml | sed "s/BACKSTAGE_CODESPACES_REPLACE/${CODESPACE_NAME}-6691.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/g" | sed "s/KEYCLOAK_CODESPACES_REPLACE/${CODESPACE_NAME}-6692.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/g" | kubectl apply -n keycloak -f -
  # fi

  # finally wait for all apps including backstage to be synced and health
  wait_until_apps_synced_healthy "${argocd_apps}" "Synced" "Healthy" 300

fi
# remove pushsecrets
kubectl delete -f ./.secrets/secrettemp/pushsecrets.yaml
