#!/bin/bash

# ------------------------------------------------------------
# GERAR ~/.aws/credentials A PARTIR DO CLOUDSHELL
# ------------------------------------------------------------
echo "============================================================"
echo "    GERANDO ARQUIVO DE CREDENCIAIS DA AWS"
echo "============================================================"
echo ""

if [ -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI" ] && [ -n "$AWS_CONTAINER_AUTHORIZATION_TOKEN" ]; then
    CREDS=$(curl -s -H "Authorization: $AWS_CONTAINER_AUTHORIZATION_TOKEN" "$AWS_CONTAINER_CREDENTIALS_FULL_URI")
    
    KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId // empty')
    SECRET_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey // empty')
    SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Token // empty')

    if [ -n "$KEY_ID" ]; then
        mkdir -p ~/.aws
        chmod 700 ~/.aws

        # umask 077: sem isso o arquivo de credenciais nascia 644.
        (
            umask 077

            cat > ~/.aws/credentials <<EOF
[default]
aws_access_key_id = ${KEY_ID}
aws_secret_access_key = ${SECRET_KEY}
aws_session_token = ${SESSION_TOKEN}
EOF

            cat > ~/.aws/config <<EOF
[default]
region = us-east-1
output = json
EOF
        )

        echo "✅ Arquivo ~/.aws/credentials gerado com sucesso!"
    else
        echo "⚠️ Não foi possível extrair os campos do JSON de credenciais."
    fi
else
    echo "⚠️ Variáveis de ambiente do CloudShell não encontradas."
fi

#docker run --rm -ti --name webconfig --entrypoint /bin/sh -v ~/environment/:/home/ubuntu/environment/ -d tonanuvem/config:ubuntu /bin/bash 
#docker exec -ti webconfig /bin/bash
