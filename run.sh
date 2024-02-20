#!/usr/bin/env bash
set -e
set -o xtrace

RESOURCE_GROUP="kingoliver-agc-test"
CLUSTER_NAME="kingoliver-agc-test"
LOCATION="eastus"
VM_SIZE="Standard_D8ds_v5"

echo "Creating resource group $RESOURCE_GROUP in $LOCATION"
az group create --name $RESOURCE_GROUP --location $LOCATION

echo "Creating AKS cluster $CLUSTER_NAME in $RESOURCE_GROUP"
az aks create \
    --resource-group $RESOURCE_GROUP \
    --name $CLUSTER_NAME \
    --node-vm-size $VM_SIZE \
    --network-plugin azure \
    --enable-addons monitoring \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --generate-ssh-key


mcResourceGroup=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query "nodeResourceGroup" -o tsv)
clusterSubnetId=$(az vmss list --resource-group $mcResourceGroup --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' -o tsv)
read -d '' vnetName vnetResourceGroup vnetId <<< $(az network vnet show --ids $clusterSubnetId --query '[name, resourceGroup, id]' -o tsv) || true # not sure why this returns non zero exit code but it works

subnetAddressPrefix='10.225.0.0/16'
ALB_SUBNET_NAME='alb-subnet'
echo "Creating subnet $ALB_SUBNET_NAME in $vnetName"
az network vnet subnet create \
    --resource-group $vnetResourceGroup \
    --vnet-name $vnetName \
    --name $ALB_SUBNET_NAME \
    --delegations 'Microsoft.ServiceNetworking/trafficControllers' \
    --address-prefixes $subnetAddressPrefix


echo "Creating identity $IDENTITY_RESOURCE_NAME in resource group $RESOURCE_GROUP"
IDENTITY_RESOURCE_NAME=azure-alb-identity
az identity create --resource-group $RESOURCE_GROUP --name $IDENTITY_RESOURCE_NAME
principalId="$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -otsv)"

echo "Apply Contributor and AppGW For Containers Configuration Manager Role on the identity"
resourceGroupId=$(az group show --name $RESOURCE_GROUP --query id -otsv)
albSubnetId="$vnetId/subnets/$ALB_SUBNET_NAME"
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $albSubnetId --role "4d97b98b-1d4f-4787-a291-c67834d212e7"
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $resourceGroupId --role "fbc52c3f28ad4303a8928a056630b8f1"

echo "Setup federation with AKS OIDC issuer"
AKS_OIDC_ISSUER="$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
az identity federated-credential create --name $IDENTITY_RESOURCE_NAME \
    --identity-name $IDENTITY_RESOURCE_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer "$AKS_OIDC_ISSUER" \
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

echo "Getting AKS kubeconfig"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME

echo "Installing the ALB Ingress Controller"
helm upgrade \
    --install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
    --version 0.4.023971 \
    --set albController.podIdentity.clientID=$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query clientId -o tsv)

NAMESPACE="alb-load-test"
echo "Creating namespace $NAMESPACE"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF

echo "Waiting for CRDs to be created"
kubectl wait --for=condition=Available --timeout=30s deployment alb-controller-bootstrap -n azure-alb-system

echo "Creating ApplicationLoadBalancer"
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb
  namespace: $NAMESPACE
spec:
  associations:
  - $albSubnetId
EOF
