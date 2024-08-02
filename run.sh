#!/bin/bash

echo "\n\n Ajustando as pastas do CloudShell e a permissão do arquivo labsuser.pem"

## Retrieve AWS credentials from AWS CloudShell : aws-cloud-shell-get-aws-credentials.sh
# https://gist.github.com/dclark/b014ac10540ca2d6911c643b8956fc50

# shellcheck disable=SC2001
HOST=$(echo "$AWS_CONTAINER_CREDENTIALS_FULL_URI" | sed 's|/latest.*||')
TOKEN=$(curl -s -X PUT "$HOST"/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
OUTPUT=$(curl -s "$HOST/latest/meta-data/container/security-credentials" -H "X-aws-ec2-metadata-token: $TOKEN")
echo "[default]" > ~/credentials
echo "AWS_ACCESS_KEY_ID=$(echo "$OUTPUT" | jq -r '.AccessKeyId')" >> ~/credentials
echo "AWS_SECRET_ACCESS_KEY=$(echo "$OUTPUT" | jq -r '.SecretAccessKey')" >> ~/credentials
echo "AWS_SESSION_TOKEN=$(echo "$OUTPUT" | jq -r '.Token')" >> ~/credentials
echo "region=us-east-1" >> ~/credentials

#docker run --rm -ti --name webconfig -d tonanuvem/config:ubuntu /bin/bash 
#docker exec -ti webconfig /bin/bash
