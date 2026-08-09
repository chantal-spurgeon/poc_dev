**Snowflake Terraform Deployment**

**Make sure Terraform is installed:**

   `brew tap hashicorp/tap`

   `brew install hashicorp/tap/terraform`
 
   `git clone https://github.com/tfutils/tfenv.git ~/.tfenv`
 
   `echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bash_profile`
 
   `echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.profile`
  
   `ln -s ~/.tfenv/bin/* /usr/local/bin`
  
   `. ~/.bash_profile`
 
   `tfenv list-remote`
 
   `tfenv install 1.5.0`
 
   `tfenv use 1.5.0`
 
   `tfenv list`

 
****************

**RSA Keys for Snowflake (create key as named, and store in ~/.ssh/):**

Encrypted - will prompt for passphrase

`openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 des3 -inform PEM -out snowflake_key.p8`

Unencrypted

`openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt`

`openssl rsa -in snowflake_key.p8 -pubout -out snowflake_key.pub`

In Snowflake as ACCOUNTADMIN:

`ALTER USER your_snowflake_username SET RSA_PUBLIC_KEY='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...';`


****************

**Update your .bash_profile:**

`# Snowflake Authentication Details`

`export TF_VAR_snowflake_user="JOHN_DOE"`

`export TF_VAR_snowflake_authenticator="SNOWFLAKE_JWT"`


`# Automatically reads your secure local .p8 private key file`

`export TF_VAR_snowflake_private_key=$(cat ~/.ssh/snowflake_key.p8)`


`# The decryption passphrase for your private key file`

`export TF_VAR_snowflake_private_key_passphrase="YourSecureKeyPassphraseHere"`



****************

**Plan and run**

`terraform init`


To run plan (from within the snowflake account directory):

`terraform plan 
-var-file="databases.tfvars" 
-var-file="warehouses.tfvars" 
-var-file="security.tfvars" 
-var-file="integrations.tfvars" 
-var-file="rbac.tfvars" 
-var-file="users.tfvars"`

To apply (from within the snowflake account directory):

`terraform apply 
-var-file="databases.tfvars" 
-var-file="warehouses.tfvars" 
-var-file="security.tfvars" 
-var-file="integrations.tfvars" 
-var-file="rbac.tfvars" 
-var-file="users.tfvars"`
