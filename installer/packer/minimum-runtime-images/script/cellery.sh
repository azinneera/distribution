#!/usr/bin/env bash
# ------------------------------------------------------------------------
#
# Copyright 2019 WSO2, Inc. (http://wso2.com)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License
#
# ------------------------------------------------------------------------

download_path=${DOWNLOAD_PATH:-tmp-cellery}
distribution_url=${GIT_DISTRIBUTION_URL:-https://github.com/wso2-cellery/distribution/archive}
release_version=${RELEASE_VERSION:-master}

#Download k8s artifacts
mkdir ${download_path}
wget ${distribution_url}/${release_version}.zip -O ${download_path}/${release_version}.zip -a cellery-setup.log
unzip ${download_path}/${release_version}.zip -d ${download_path}

#Create folders required by the mysql PVC
if [ -d /mnt/mysql ]; then
    mv /mnt/mysql "/mnt/mysql.$(date +%s)"
fi
mkdir -p /mnt/mysql
#Change the folder ownership to mysql server user.
chown 999:999 /mnt/mysql

declare -A config_params
config_params["MYSQL_DATABASE_HOST"]="wso2apim-with-analytics-rdbms-service"
config_params["DATABASE_USERNAME"]="cellery"
db_passwd=$(cat /dev/urandom | env LC_CTYPE=C tr -dc a-zA-Z0-9 | head -c 16; echo)
config_params["DATABASE_PASSWORD"]=$db_passwd

for param in "${!config_params[@]}"
do
    sed -i "s/$param/${config_params[$param]}/g" ${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/conf/datasources/master-datasources.xml
done

for param in "${!config_params[@]}"
do
    sed -i "s/$param/${config_params[$param]}/g" ${download_path}/distribution-${release_version}/installer/k8s-artefacts/mysql/dbscripts/init.sql
done


#Deploy Cellery k8s artifacts
#Create Cellery ns
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/system/ns-init.yaml

HOST_NAME=$(hostname | tr '[:upper:]' '[:lower:]')
#label the node if k8s provider is kubeadm
kubectl label nodes $HOST_NAME disk=local

#Create mysql deployment
kubectl create configmap mysql-dbscripts --from-file=${download_path}/distribution-${release_version}/installer/k8s-artefacts/mysql/dbscripts/ -n cellery-system
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/mysql/mysql-persistent-volumes-local.yaml -n cellery-system
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/mysql/mysql-persistent-volume-claim.yaml -n cellery-system
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/mysql/mysql-deployment.yaml -n cellery-system
#Wait till the mysql deployment availability
kubectl wait deployment/wso2apim-with-analytics-mysql-deployment --for condition=available --timeout=6000s -n cellery-system
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/mysql/mysql-service.yaml -n cellery-system

#Create Istio deployment
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/system/istio-crds.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/system/istio-demo-cellery.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/system/istio-gateway.yaml
kubectl wait deployment/istio-pilot --for condition=available --timeout=6000s -n istio-system
#Enabling Istio injection
kubectl label namespace default istio-injection=enabled
sleep 60
#Create Cellery CRDs.
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/01-cluster-role.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/02-service-account.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/03-cluster-role-binding.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/04-crd-cell.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/05-crd-gateway.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/06-crd-token-service.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/07-crd-service.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/08-config.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/controller/09-controller.yaml
sleep 120

#Create the IDP config maps
kubectl create configmap identity-server-conf --from-file=${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/conf -n cellery-system
kubectl create configmap identity-server-conf-datasources --from-file=${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/conf/datasources/ -n cellery-system
kubectl create configmap identity-server-conf-identity --from-file=${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/conf/identity -n cellery-system
kubectl create configmap identity-server-tomcat --from-file=${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/conf/tomcat -n cellery-system
#kubectl create configmap identity-server-security --from-file=${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/conf/security -n cellery-system

#Create IDP deployment and the service
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/global-idp/global-idp.yaml -n cellery-system

#Create ingress-nginx deployment
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/system/mandatory.yaml
kubectl apply -f ${download_path}/distribution-${release_version}/installer/k8s-artefacts/system/service-nodeport.yaml

