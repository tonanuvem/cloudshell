#!/bin/bash

echo "\n\n Ajustando as Credenciais do CloudShell e a permissão do arquivo labsuser.pem"

## Retrieve AWS credentials from AWS CloudShell : aws-cloud-shell-get-aws-credentials.sh
# https://gist.github.com/dclark/b014ac10540ca2d6911c643b8956fc50

# O CloudShell expõe as credenciais ativas via endpoint do container
CREDS=$(curl -s "$AWS_CONTAINER_CREDENTIALS_FULL_URI")

KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
SECRET_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
TOKEN=$(echo "$CREDS" | jq -r '.Token')

# Cria o arquivo de credenciais formatado corretamente para a AWS CLI
mkdir -p ~/.aws

cat > ~/.aws/credentials <<EOF
[default]
aws_access_key_id = ${KEY_ID}
aws_secret_access_key = ${SECRET_KEY}
aws_session_token = ${TOKEN}
EOF

cat > ~/.aws/config <<EOF
[default]
region = us-east-1
output = json
EOF

echo "✅ Arquivo ~/.aws/credentials gerado com sucesso!"

docker run --rm -ti --name webconfig --entrypoint /bin/sh -v ~/environment/:/home/ubuntu/environment/ -d tonanuvem/config:ubuntu /bin/bash 
docker exec -ti webconfig /bin/bash
