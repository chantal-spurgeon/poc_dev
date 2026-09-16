# Configuring Key Pair Authentication for dbt and Snowflake

Key pair authentication provides an enhanced security layer over traditional password authentication by using an encrypted asymmetric key pair to authenticate the dbt service with Snowflake. This guide covers generating the keys, configuring the Snowflake user, and updating your dbt profile.

---

## Step 1: Generate the Asymmetric Keys

You can generate the private and public keys using your local terminal. It is highly recommended to encrypt your private key with a strong passphrase.

```bash
# 1. Generate an encrypted private key (you will be prompted to enter a passphrase)
openssl genrsa -aes256 -out dbt_private_key.p8 2048

# 2. Extract the public key from the private key
openssl rsa -pubout -in dbt_private_key.p8 -out dbt_public_key.pub
```

> ⚠️ **Important:** Keep your `dbt_private_key.p8` file completely secure. Do not commit it to version control systems like GitHub.

---

## Step 2: Assign the Public Key to the Snowflake User

You need to extract the contents of the public key and attach it to your dedicated dbt user profile in Snowflake.

1. Open your `dbt_public_key.pub` file and copy the text **between** the `-----BEGIN PUBLIC KEY-----` and `-----END PUBLIC KEY-----` headers. Ensure there are no spaces or extra line breaks.
2. Log into your Snowflake console as an administrator and execute the following query:

```sql
-- Alter the dbt user to append the public key string
ALTER USER dbt_user SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAv...';
```

Verify that the user profile was successfully updated:
```sql
DESCRIBE USER dbt_user;
-- Look for the RSA_PUBLIC_KEY property in the output to confirm it matches.
```

---

## Step 3: Update your dbt `profiles.yml` File

Modify your `~/.dbt/profiles.yml` file to transition from `password` authentication to `keypair` authentication. 

```yaml
my_snowflake_project:
  outputs:
    dev:
      type: snowflake
      account: abc12345.us-east-1
      user: dbt_user
      role: dbt_role
      warehouse: dbt_warehouse
      database: analytics
      schema: dbt_dev_schema
      threads: 4
      
      # Asymmetric Key Authentication Settings
      authenticator: snowflake
      private_key_path: /path/to/your/dbt_private_key.p8
      private_key_passphrase: "YourStrongKeyPassphrase"  # Leave blank if your private key is unencrypted
  target: dev
```

### Best Practice for Production Environments
For production environments or dbt Core running in CI/CD pipelines, hardcoding passphrases or keys inside `profiles.yml` is a security risk. Use environment variables instead:

```yaml
      private_key_path: "{{ env_var('DBT_ENV_SECRET_PRIVATE_KEY_PATH') }}"
      private_key_passphrase: "{{ env_var('DBT_ENV_SECRET_PRIVATE_KEY_PASSPHRASE') }}"
```

---

## Step 4: Verify the Key Pair Connection

Navigate to your dbt project folder in the terminal and execute the debug utility to ensure the cryptographic handshake works seamlessly:

```bash
dbt debug
```

Look for the green **`Connection test: OK`** validation message at the end of the script output. Your dbt CLI environment is now secured using asymmetric key authentication!
