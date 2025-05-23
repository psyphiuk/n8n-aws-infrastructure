# n8n-AWS-Infrastructure 

This creates the infrastructure for a single client to host n8n on AWS.

# Store the DB password and encryption key

## Replace CLIENT with your client’s identifier.
export CLIENT=myclient

## 1. Postgres password
aws ssm put-parameter \
  --name "/n8n/${CLIENT}/POSTGRES_PASSWORD" \
  --value "YOUR_DB_PASSWORD" \
  --type SecureString

## 2. n8n encryption key
aws ssm put-parameter \
  --name "/n8n/${CLIENT}/ENCRYPTION_KEY" \
  --value "$(openssl rand -hex 32)" \
  --type SecureString
