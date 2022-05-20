# Prerequesites
# * Kubernetes Cluster
# * Helm
# * Vault CLI
# * Kubectl Utility

## Install Vault
helm install vault hashicorp/vault -f vault-values.yaml

## Install Postgres
helm install postgres bitnami/postgresql -f postgres-values.yaml

## Portforward Vault
kubectl port-forward svc/vault 8200:8200

# Vault ENVs
export VAULT_ADDR="http://127.0.0.1:8200"

#
vault login

# Enable the PostgreSQL secrets backend#
vault secrets enable database

# Create a new role for database engine:
vault write database/roles/db-app \
    db_name=wizard \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="ALTER ROLE \"{{name}}\" NOLOGIN;"\
    default_ttl="1h" \
    max_ttl="24h"

# Create a new database connection:
vault write database/config/wizard \
    plugin_name=postgresql-database-plugin \
    allowed_roles="*" \
    connection_url="postgresql://{{username}}:{{password}}@postgres-postgresql:5432/?sslmode=disable" \
    username="postgres" \
    password="password"

#Since Vault can manage credential creation for both humans and applications, you no longer need the original password. 
#Vaults root rotation can automatically change this password to one only Vault can use.

# Rotate the root password:

vault write --force /database/rotate-root/wizard

# Login inside the PostgreSql

kubectl exec -it \
  $(kubectl get pods --selector "app.kubernetes.io/name=postgresql" -o jsonpath="{.items[0].metadata.name}") \
  -c postgresql -- \
  bash -c 'PGPASSWORD=password psql -U postgres'

# Finally you can test the generation of credentials for your application by using the vault read database/creds/<role> command.

vault read database/creds/db-app

# Configure Kubernetes Authentication

vault auth enable kubernetes

#  Authenticate Vault with the Kubernetes API

kubectl exec $(kubectl get pods --selector "app.kubernetes.io/instance=vault,component=server" -o jsonpath="{.items[0].metadata.name}") -c vault -- \
  sh -c ' \
    vault write auth/kubernetes/config \
       token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
       kubernetes_host=https://${KUBERNETES_PORT_443_TCP_ADDR}:443 \
       kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'

# Create a Vault Policy to read the Database Secrets

vault policy write web ./web-policy.hcl

# Assigning Vault policy to Kubernetes Service Account
# Create a role to map Vault Policy to a Service Account
vault write auth/kubernetes/role/web \
    bound_service_account_names=web \
    bound_service_account_namespaces=default \
    policies=web \
    ttl=1h

# Create the Service Account "web"
kubectl apply -f web-sa.yml

# Injecting secrets into Kubernetes Deployments

kubectl apply -f web-deployment.yml

# Command to read secrets from the Pod:

kubectl exec -it \
  $(kubectl get pods --selector "app=web" -o jsonpath="{.items[0].metadata.name}") \
  -c web -- cat /vault/secrets/db-creds
