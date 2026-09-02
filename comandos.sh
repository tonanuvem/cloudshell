
# ------------------------------------------------------------
# SCRIPTS AUXILIARES
# ------------------------------------------------------------

echo ""
echo "📝 Criando scripts iniciar.sh e destruir.sh..."


cat > $HOME/ligar.sh <<'EOF'
#!/bin/bash

cd "$PASTA_CONFIG/environment/config/vm-fiap" || exit 1

# Obtém o Instance ID diretamente do Terraform State
INSTANCE_ID=$(terraform show -json 2>/dev/null | \
  jq -r '.values.root_module.resources[] |
  select(.address=="aws_instance.web") |
  .values.id')

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    echo "❌ Não foi possível obter o Instance ID pelo Terraform State."
    exit 1
fi

echo "🚀 Ligando EC2: $INSTANCE_ID"

aws ec2 start-instances \
    --instance-ids "$INSTANCE_ID"

echo ""
echo "Aguardando a máquina iniciar..."

aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID"

echo ""
echo "✅ Máquina ligada!"

aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress,PrivateIpAddress]' \
    --output table

# ------------------------------------------------------------
# IP PÚBLICO ATUAL
# ------------------------------------------------------------

VM=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "============================================================"
echo "🌐 ACESSO À APLICAÇÃO"
echo "============================================================"
echo ""
echo "✅ Acessar : http://$VM:8099"
echo "   Senha   : fiap"
echo ""
echo "============================================================"
echo ""
EOF


cat > ~/suspender.sh <<'EOF'
#!/bin/bash

cd ~/environment/config/vm-fiap || exit 1

# Obtém o Instance ID diretamente do Terraform State
INSTANCE_ID=$(terraform show -json 2>/dev/null | \
  jq -r '.values.root_module.resources[] |
  select(.address=="aws_instance.web") |
  .values.id')

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    echo "❌ Não foi possível obter o Instance ID pelo Terraform State."
    exit 1
fi

echo "🛑 Parando EC2: $INSTANCE_ID"

aws ec2 stop-instances \
    --instance-ids "$INSTANCE_ID"

echo ""
echo "Aguardando a máquina parar..."

aws ec2 wait instance-stopped \
    --instance-ids "$INSTANCE_ID"

echo ""
echo "✅ Máquina suspensa!"

aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[InstanceId,State.Name]' \
    --output table

echo ""
EOF

chmod +x "$HOME/iniciar.sh"
chmod +x "$HOME/destruir.sh"
chmod +x "$HOME/conectar.sh"
chmod +x "$HOME/ip"
chmod +x "$HOME/ligar.sh"
chmod +x "$HOME/suspender.sh"
