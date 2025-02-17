#!/bin/bash
#
# Copyright (c) 2020-2021 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#   Red Hat, Inc. - initial API and implementation
#
# convert che-operator upstream to downstream using sed & yq transforms, and deleting files

set -e

# defaults
CSV_VERSION=2.y.0 # csv 2.y.0
CRW_VERSION=${CSV_VERSION%.*} # tag 2.y
SSO_TAG=7.4
UBI_TAG=8.4
POSTGRES_TAG=1

usage () {
	echo "Usage:   ${0##*/} -v [CRW CSV_VERSION] [-s /path/to/sources] [-t /path/to/generated]"
	echo "Example: ${0##*/} -v 2.y.0 -s ${HOME}/projects/che-operator -t /tmp/crw-operator"
	echo "Options:
	--sso-tag ${SSO_TAG}
	--ubi-tag ${UBI_TAG}
	--postgres-tag ${POSTGRES_TAG}
	"
	exit
}

if [[ $# -lt 6 ]]; then usage; fi

while [[ "$#" -gt 0 ]]; do
  case $1 in
	# for CSV_VERSION = 2.2.0, get CRW_VERSION = 2.2
	'-v') CSV_VERSION="$2"; CRW_VERSION="${CSV_VERSION%.*}"; shift 1;;
	# paths to use for input and ouput
	'-s') SOURCEDIR="$2"; SOURCEDIR="${SOURCEDIR%/}"; shift 1;;
	'-t') TARGETDIR="$2"; TARGETDIR="${TARGETDIR%/}"; shift 1;;
	'--help'|'-h') usage;;
	# optional tag overrides
	'--crw-tag') CRW_VERSION="$2"; shift 1;;
	'--sso-tag') SSO_TAG="$2"; shift 1;;
	'--ubi-tag') UBI_TAG="$2"; shift 1;;
	'--postgres-tag') POSTGRES_TAG="$2"; shift 1;;
  esac
  shift 1
done

if [[ "${CSV_VERSION}" == "2.y.0" ]]; then usage; fi

# see both sync-che-o*.sh scripts - need these since we're syncing to different midstream/dowstream repos
CRW_RRIO="registry.redhat.io/codeready-workspaces"
CRW_OPERATOR="crw-2-rhel8-operator"
CRW_BROKER_METADATA_IMAGE="${CRW_RRIO}/pluginbroker-metadata-rhel8:${CRW_VERSION}"
CRW_BROKER_ARTIFACTS_IMAGE="${CRW_RRIO}/pluginbroker-artifacts-rhel8:${CRW_VERSION}"
CRW_CONFIGBUMP_IMAGE="${CRW_RRIO}/configbump-rhel8:${CRW_VERSION}"
CRW_DASHBOARD_IMAGE="${CRW_RRIO}/dashboard-rhel8:${CRW_VERSION}" 
CRW_DEVFILEREGISTRY_IMAGE="${CRW_RRIO}/devfileregistry-rhel8:${CRW_VERSION}"
CRW_DWO_IMAGE="${CRW_RRIO}/devworkspace-controller-rhel8:${CRW_VERSION}" 
CRW_DWCO_IMAGE="${CRW_RRIO}/devworkspace-rhel8:${CRW_VERSION}" 
CRW_JWTPROXY_IMAGE="${CRW_RRIO}/jwtproxy-rhel8:${CRW_VERSION}"
CRW_PLUGINREGISTRY_IMAGE="${CRW_RRIO}/pluginregistry-rhel8:${CRW_VERSION}"
CRW_SERVER_IMAGE="${CRW_RRIO}/server-rhel8:${CRW_VERSION}"
CRW_TRAEFIK_IMAGE="${CRW_RRIO}/traefik-rhel8:${CRW_VERSION}"

UBI_IMAGE="registry.redhat.io/ubi8/ubi-minimal:${UBI_TAG}"
POSTGRES_IMAGE="registry.redhat.io/rhel8/postgresql-96:${POSTGRES_TAG}"
SSO_IMAGE="registry.redhat.io/rh-sso-7/sso74-openshift-rhel8:${SSO_TAG}" # and registry.redhat.io/rh-sso-7/sso74-openj9-openshift-rhel8 too

# global / generic changes
pushd "${SOURCEDIR}" >/dev/null
COPY_FOLDERS="cmd deploy mocks olm pkg templates vendor version"
echo "Rsync ${COPY_FOLDERS} to ${TARGETDIR}"
# shellcheck disable=SC2086
rsync -azrlt ${COPY_FOLDERS} ${TARGETDIR}/

# delete unneeded files
echo "Delete olm/eclipse-che-preview-kubernetes and olm/eclipse-che-preview-openshift"
rm -fr "${TARGETDIR}/olm/eclipse-che-preview-kubernetes ${TARGETDIR}/olm/eclipse-che-preview-openshift"
echo "Delete deploy/*/eclipse-che-preview-kubernetes and deploy/olm-catalog/stable"
rm -fr "${TARGETDIR}/deploy/olm-catalog/eclipse-che-preview-kubernetes"
rm -fr "${TARGETDIR}/deploy/olm-catalog/nightly/eclipse-che-preview-kubernetes"
# remove files with embedded RELATED_IMAGE_* values for Che stable releases
rm -fr "${TARGETDIR}/deploy/olm-catalog/stable" 

# sed changes
while IFS= read -r -d '' d; do
	if [[ -d "${SOURCEDIR}/${d%/*}" ]]; then mkdir -p "${TARGETDIR}"/"${d%/*}"; fi
	if [[ -f "${TARGETDIR}/${d}" ]]; then 
		sed -i "${TARGETDIR}/${d}" -r \
			-e "s|identityProviderPassword: ''|identityProviderPassword: 'admin'|g" \
			-e "s|quay.io/eclipse/che-operator:.+|${CRW_RRIO}/${CRW_OPERATOR}:latest|" \
			-e "s|Eclipse Che|CodeReady Workspaces|g" \
			-e 's|(DefaultCheFlavor.*=) "che"|\1 "codeready"|' \
			-e 's|(DefaultPvcStrategy.*=) "common"|\1 "per-workspace"|' \
			-e 's|che/operator|codeready/operator|' \
			-e 's|che-operator|codeready-operator|' \
			-e 's|name: eclipse-che|name: codeready-workspaces|' \
			-e "s|cheImageTag: 'nightly'|cheImageTag: ''|" \
			-e 's|/bin/codeready-operator|/bin/che-operator|' \
			-e 's#(githubusercontent|github).com/eclipse/codeready-operator#\1.com/eclipse/che-operator#g' \
			-e 's#(githubusercontent|github).com/eclipse-che/codeready-operator#\1.com/eclipse-che/che-operator#g' \
			-e 's|devworkspace-codeready-operator|devworkspace-che-operator|'
		if [[ $(diff -u "${SOURCEDIR}/${d}" "${TARGETDIR}/${d}") ]]; then
			echo "Converted (sed) ${d}"
		fi
	fi
done <   <(find deploy pkg/deploy -type f -not -name "defaults_test.go" -print0)

# shellcheck disable=SC2086
while IFS= read -r -d '' d; do
	sed -r \
		-e 's|(cheVersionTest.*=) ".+"|\1 "'${CRW_VERSION}'"|' \
		\
		-e 's|(cheServerImageTest.*=) ".+"|\1 "'${CRW_SERVER_IMAGE}'"|' \
		-e 's|(pluginRegistryImageTest.*=) ".+"|\1 "'${CRW_PLUGINREGISTRY_IMAGE}'"|' \
		-e 's|(devfileRegistryImageTest.*=) ".+"|\1 "'${CRW_DEVFILEREGISTRY_IMAGE}'"|' \
		\
		-e 's|(brokerMetadataTest.*=) ".+"|\1 "'${CRW_BROKER_METADATA_IMAGE}'"|' \
		-e 's|(brokerArtifactsTest.*=) ".+"|\1 "'${CRW_BROKER_ARTIFACTS_IMAGE}'"|' \
		-e 's|(jwtProxyTest.*=) ".+"|\1 "'${CRW_JWTPROXY_IMAGE}'"|' \
		\
		-e 's|(pvcJobsImageTest.*=) ".+"|\1 "'${UBI_IMAGE}'"|' \
		-e 's|(postgresImageTest.*=) ".+"|\1 "'${POSTGRES_IMAGE}'"|' \
		-e 's|(keycloakImageTest.*=) ".+"|\1 "'${SSO_IMAGE}'"|' \
		\
		`# hardcoded test values` \
		-e 's|"docker.io/eclipse/che-operator:latest": * "che-operator:latest"|"'${CRW_RRIO}/${CRW_OPERATOR}':latest":  "'${CRW_OPERATOR}':latest"|' \
		-e 's|"quay.io/eclipse/che-operator:[0-9.]+": *"che-operator:[0-9.]+"|"'${CRW_RRIO}'/server-operator-rhel8:2.0": "server-operator-rhel8:2.0"|' \
		-e 's|"che-operator:[0-9.]+": *"che-operator:[0-9.]+"|"'${CRW_RRIO}/${CRW_OPERATOR}:${CRW_VERSION}'":  "'${CRW_OPERATOR}:${CRW_VERSION}'"|' \
	"$d" > "${TARGETDIR}/${d}"
	if [[ $(diff -u "$d" "${TARGETDIR}/${d}") ]]; then
		echo "Converted (sed) ${d}"
	fi
done <   <(find pkg/deploy -type f -name "defaults_test.go" -print0)

# header to reattach to yaml files after yq transform removes it
COPYRIGHT="#
#  Copyright (c) 2018-$(date +%Y) Red Hat, Inc.
#    This program and the accompanying materials are made
#    available under the terms of the Eclipse Public License 2.0
#    which is available at https://www.eclipse.org/legal/epl-2.0/
#
#  SPDX-License-Identifier: EPL-2.0
#
#  Contributors:
#    Red Hat, Inc. - initial API and implementation
"

replaceField()
{
  theFile="$1"
  updateName="$2"
  updateVal="$3"
  header="$4"
  echo "[INFO] ${0##*/} rF :: * ${updateName}: ${updateVal}"
  # shellcheck disable=SC2016 disable=SC2002 disable=SC2086
  if [[ $updateVal == "DELETEME" ]]; then
	changed=$(yq -Y --arg updateName "${updateName}" --arg updateVal "${updateVal}" 'del(${updateName})' "${theFile}")
  else
	changed=$(yq -Y --arg updateName "${updateName}" --arg updateVal "${updateVal}" ${updateName}' = $updateVal' "${theFile}")
  fi
  echo "${header}${changed}" > "${theFile}"
}

# similar method to replaceEnvVar() but for a different path within the yaml
replaceEnvVarOperatorYaml()
{
	fileToChange="$1"
	header="$2"
	field="$3"
	# don't do anything if the existing value is the same as the replacement one
	# shellcheck disable=SC2016 disable=SC2002 disable=SC2086
	if [[ "$(cat "${fileToChange}" | yq -r --arg updateName "${updateName}" ${field}'[] | select(.name == $updateName).value')" != "${updateVal}" ]]; then
		echo "[INFO] ${0##*/} rEVOY :: ${fileToChange##*/} :: ${updateName}: ${updateVal}"
		if [[ $updateVal == "DELETEME" ]]; then
			changed=$(cat "${fileToChange}" | yq -Y --arg updateName "${updateName}" 'del('${field}'[]|select(.name == $updateName))')
			echo "${header}${changed}" > "${fileToChange}.2"
		else
			# attempt to replace updateName field with updateVal value
			changed=$(cat "${fileToChange}" | yq -Y --arg updateName "${updateName}" --arg updateVal "${updateVal}" \
${field}' = ['${field}'[] | if (.name == $updateName) then (.value = $updateVal) else . end]')
			echo "${header}${changed}" > "${fileToChange}.2"
			#  echo "replaced?"
			#  diff -u "${fileToChange}" "${fileToChange}.2" || true
			if [[ ! $(diff -u "${fileToChange}" "${fileToChange}.2") ]]; then
			echo "insert $updateName = $updateVal"
			 changed=$(cat "${fileToChange}" | yq -Y --arg updateName "${updateName}" --arg updateVal "${updateVal}" \
				${field}' += [{"name": $updateName, "value": $updateVal}]')
			echo "${header}${changed}" > "${fileToChange}.2"
			fi
		fi
		mv "${fileToChange}.2" "${fileToChange}"
	fi
}

# yq changes - transform env vars from Che to CRW values

##### update the first container yaml

# see both sync-che-o*.sh scripts - need these since we're syncing to different midstream/dowstream repos
# yq changes - transform env vars from Che to CRW values
declare -A operator_replacements=(
	["CHE_VERSION"]="${CSV_VERSION}" # set this to x.y.z version, matching the CSV
	["CHE_FLAVOR"]="codeready"
	["CONSOLE_LINK_NAME"]="che" # use che, not workspaces - CRW-1078

	["RELATED_IMAGE_che_server"]="${CRW_SERVER_IMAGE}"
	["RELATED_IMAGE_dashboard"]="${CRW_DASHBOARD_IMAGE}"
	["RELATED_IMAGE_devfile_registry"]="${CRW_DEVFILEREGISTRY_IMAGE}"
	["RELATED_IMAGE_devworkspace_che_operator"]="${CRW_DWCO_IMAGE}"
	["RELATED_IMAGE_devworkspace_controller"]="${CRW_DWO_IMAGE}"
	["RELATED_IMAGE_plugin_registry"]="${CRW_PLUGINREGISTRY_IMAGE}"

	["RELATED_IMAGE_che_workspace_plugin_broker_metadata"]="${CRW_BROKER_METADATA_IMAGE}"
	["RELATED_IMAGE_che_workspace_plugin_broker_artifacts"]="${CRW_BROKER_ARTIFACTS_IMAGE}"
	["RELATED_IMAGE_che_server_secure_exposer_jwt_proxy_image"]="${CRW_JWTPROXY_IMAGE}"

	["RELATED_IMAGE_single_host_gateway"]="${CRW_TRAEFIK_IMAGE}"
	["RELATED_IMAGE_single_host_gateway_config_sidecar"]="${CRW_CONFIGBUMP_IMAGE}"

	["RELATED_IMAGE_pvc_jobs"]="${UBI_IMAGE}"
	["RELATED_IMAGE_postgres"]="${POSTGRES_IMAGE}"
	["RELATED_IMAGE_keycloak"]="${SSO_IMAGE}"

	# remove env vars using DELETEME keyword
	["RELATED_IMAGE_che_tls_secrets_creation_job"]="DELETEME"
	["RELATED_IMAGE_internal_rest_backup_server"]="DELETEME"
	["RELATED_IMAGE_gateway_authentication_sidecar"]="DELETEME"
	["RELATED_IMAGE_gateway_authorization_sidecar"]="DELETEME"
	["RELATED_IMAGE_gateway_header_sidecar"]="DELETEME"
)
while IFS= read -r -d '' d; do
	for updateName in "${!operator_replacements[@]}"; do
		updateVal="${operator_replacements[$updateName]}"
		replaceEnvVarOperatorYaml "${d}" "${COPYRIGHT}" '.spec.template.spec.containers[0].env'
	done
done <   <(find "${TARGETDIR}/deploy" -type f -name "operator*.yaml" -print0)

# see both sync-che-o*.sh scripts - need these since we're syncing to different midstream/dowstream repos
# insert keycloak image references for s390x and ppc64le
declare -A operator_insertions=(
	["RELATED_IMAGE_keycloak_s390x"]="${SSO_IMAGE/-openshift-/-openj9-openshift-}"
	["RELATED_IMAGE_keycloak_ppc64le"]="${SSO_IMAGE/-openshift-/-openj9-openshift-}"
)
for updateName in "${!operator_insertions[@]}"; do
	updateVal="${operator_insertions[$updateName]}"
	# apply same transforms in operator.yaml
	replaceEnvVarOperatorYaml "${TARGETDIR}/deploy/operator.yaml" "${COPYRIGHT}" '.spec.template.spec.containers[0].env'
done

# CRW-1579 set correct crw-2-rhel8-operator image and tag in operator.yaml
oldImage=$(yq -r '.spec.template.spec.containers[0].image' "${TARGETDIR}/deploy/operator.yaml")
if [[ $oldImage ]]; then 
	replaceField "${TARGETDIR}/deploy/operator.yaml" ".spec.template.spec.containers[0].image" "${oldImage%%:*}:${CRW_VERSION}" "${COPYRIGHT}"
fi

##### update the second container yaml

declare -A operator_replacements2=(
	["RELATED_IMAGE_gateway"]="${CRW_TRAEFIK_IMAGE}"
	["RELATED_IMAGE_gateway_configurer"]="${CRW_CONFIGBUMP_IMAGE}"
)
while IFS= read -r -d '' d; do
	for updateName in "${!operator_replacements2[@]}"; do
		updateVal="${operator_replacements2[$updateName]}"
		replaceEnvVarOperatorYaml "${d}" "${COPYRIGHT}" '.spec.template.spec.containers[1].env'
	done
done <   <(find "${TARGETDIR}/deploy" -type f -name "operator*.yaml" -print0)

# update second container image from quay.io/che-incubator/devworkspace-che-operator:ci to CRW_DWCO_IMAGE
replaceField "${TARGETDIR}/deploy/operator.yaml" '.spec.template.spec.containers[1].image' "${CRW_DWCO_IMAGE}" "${COPYRIGHT}"

# see both sync-che-o*.sh scripts - need these since we're syncing to different midstream/dowstream repos
# yq changes - transform env vars from Che to CRW values
while IFS= read -r -d '' d; do
	changed="$(cat "${d}" | \
yq  -y '.spec.server.devfileRegistryImage=""|.spec.server.pluginRegistryImage=""' | \
yq  -y '.spec.server.cheFlavor="codeready"' | \
yq  -y '.spec.server.workspaceNamespaceDefault="<username>-codeready"' | \
yq  -y '.spec.storage.pvcStrategy="per-workspace"' | \
yq  -y '.spec.auth.identityProviderAdminUserName="admin"|.spec.auth.identityProviderImage=""' | \
yq  -y 'del(.spec.k8s)')" && \
	echo "${COPYRIGHT}${changed}" > "${d}"
	if [[ $(diff -u "$d" "${d}") ]]; then
		echo "Converted (yq #3) ${d}"
	fi
done <   <(find "${TARGETDIR}/deploy/crds" -type f -name "org_v1_che_cr.yaml" -print0)

# # delete unneeded files
# echo "Delete olm/eclipse-che-preview-kubernetes and olm/eclipse-che-preview-openshift"
# rm -fr "${TARGETDIR}/olm/eclipse-che-preview-kubernetes ${TARGETDIR}/olm/eclipse-che-preview-openshift"
# echo "Delete deploy/*/eclipse-che-preview-kubernetes and deploy/olm-catalog/stable"
# rm -fr "${TARGETDIR}/deploy/olm-catalog/eclipse-che-preview-kubernetes"
# rm -fr "${TARGETDIR}/deploy/olm-catalog/nightly/eclipse-che-preview-kubernetes"
# # remove files with embedded RELATED_IMAGE_* values for Che stable releases
# rm -fr "${TARGETDIR}/deploy/olm-catalog/stable" 

# if sort the file, we'll lose all the comments
yq -yY '.spec.template.spec.containers[0].env |= sort_by(.name)' "${TARGETDIR}/deploy/operator.yaml" > "${TARGETDIR}/deploy/operator.yaml2"
yq -yY '.spec.template.spec.containers[1].env |= sort_by(.name)' "${TARGETDIR}/deploy/operator.yaml2" > "${TARGETDIR}/deploy/operator.yaml"
echo "${COPYRIGHT}$(cat "${TARGETDIR}/deploy/operator.yaml")" > "${TARGETDIR}/deploy/operator.yaml2"
mv "${TARGETDIR}/deploy/operator.yaml2" "${TARGETDIR}/deploy/operator.yaml" 

popd >/dev/null || exit

