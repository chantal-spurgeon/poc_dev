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
export TF_VAR_snowflake_private_key=$(cat ~/.snowflake/rsa_key.p8)

# The decryption passphrase for your private key file
export TF_VAR_snowflake_private_key_passphrase="YourSecureKeyPassphraseHere"


terraform plan \
-var-file="<snowflakeaccount>/databases.tfvars" \
-var-file="<snowflakeaccount>/warehouses.tfvars" \
-var-file="<snowflakeaccount>/security.tfvars" \
-var-file="<snowflakeaccount>/integrations.tfvars" \
-var-file="<snowflakeaccount>/rbac.tfvars" \
-var-file="<snowflakeaccount>/users.tfvars"
