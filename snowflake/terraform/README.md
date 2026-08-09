Snowflake Terraform Deployment

RSA Keys for Snowflake:

Encrypted - will prompt for passphrase
openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 des3 -inform PEM -out rsa_key.p8

Unencrypted
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt

openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

ALTER USER your_snowflake_username SET RSA_PUBLIC_KEY='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...';

# Snowflake Authentication Details
export TF_VAR_snowflake_user="JOHN_DOE"
export TF_VAR_snowflake_authenticator="SNOWFLAKE_JWT"

# Automatically reads your secure local .p8 private key file
export TF_VAR_snowflake_private_key=$(cat ~/.ssh/snowflake_key.p8)

# The decryption passphrase for your private key file
export TF_VAR_snowflake_private_key_passphrase="YourSecureKeyPassphraseHere"


terraform plan \
-var-file="databases.tfvars" \
-var-file="warehouses.tfvars" \
-var-file="security.tfvars" \
-var-file="integrations.tfvars" \
-var-file="rbac.tfvars" \
-var-file="users.tfvars"

terraform apply \
-var-file="databases.tfvars" \
-var-file="warehouses.tfvars" \
-var-file="security.tfvars" \
-var-file="integrations.tfvars" \
-var-file="rbac.tfvars" \
-var-file="users.tfvars"
