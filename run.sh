#!/bin/bash

echo "\n\n Ajustando as pastas do CloudShell e a permissão do arquivo labsuser.pem"

## Retrieve AWS credentials from AWS CloudShell : aws-cloud-shell-get-aws-credentials.sh
# https://gist.github.com/dclark/b014ac10540ca2d6911c643b8956fc50

if [ $(ls ~ | grep labsuser.pem | wc -l) = "1" ]
then
  printf "\t\tARQUIVO labsuser.pem OK!\n\n"
  mkdir ~/environment/ && mkdir ~/environment/.aws/
  cp  ~/labsuser.pem ~/environment/labsuser.pem
  chmod 400 ~/environment/labsuser.pem
else
  echo "\t\tArquivo labsuser.pem não encontrado, você deve fazer o upload do arquivo para o CloudShell\n\n"
  exit
fi

# shellcheck disable=SC2001
HOST=$(echo "$AWS_CONTAINER_CREDENTIALS_FULL_URI" | sed 's|/latest.*||')
TOKEN=$(curl -s -X PUT "$HOST"/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
OUTPUT=$(curl -s "$HOST/latest/meta-data/container/security-credentials" -H "X-aws-ec2-metadata-token: $TOKEN")
echo "[default]" > credentials
echo "AWS_ACCESS_KEY_ID=$(echo "$OUTPUT" | jq -r '.AccessKeyId')" >> credentials
echo "AWS_SECRET_ACCESS_KEY=$(echo "$OUTPUT" | jq -r '.SecretAccessKey')" >> credentials
echo "AWS_SESSION_TOKEN=$(echo "$OUTPUT" | jq -r '.Token')" >> credentials
echo "region=us-east-1" >> credentials

copy credentials ~/environment/.aws/credentials

docker run --rm -ti --name webconfig --entrypoint /bin/sh -v -v ~/environment/:/home/ubuntu/environment/ -d tonanuvem/config:ubuntu /bin/bash 
docker exec -ti webconfig /bin/bash
