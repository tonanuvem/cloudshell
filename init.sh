#!/bin/bash

# ============================================================
# FIAP LAB - INITIALIZATION
#
# Ordem importante: os scripts auxiliares (e a biblioteca comum
# .fiaplab.lib.sh) sao gerados logo no inicio, porque todo o
# resto deste script passa a usar as funcoes da lib em vez de
# repetir a logica de credenciais / terraform / ansible.
#
# Nao usa "set -e": o RC e tratado explicitamente.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AWS_REGION="${AWS_REGION:-us-east-1}"

PASTA_ENV="$HOME/environment"
PASTA_CONFIG="$PASTA_ENV/config"

PROJETO_PADRAO="ubuntu-vm"

echo ""
echo "========================================"
echo "        FIAP LAB - INITIALIZATION"
echo "========================================"
echo ""

# ============================================================
# 1. CONFIG / TERRAFORM PROJECTS
# ============================================================

echo ">> Atualizando repositório de configuração..."

if [ ! -d "$PASTA_CONFIG/.git" ]; then
    rm -rf "$PASTA_CONFIG"
    git clone https://github.com/tonanuvem/config "$PASTA_CONFIG" || {
        echo ""
        echo "❌ Não foi possível clonar o repositório de configuração."
        echo ""
        exit 1
    }
else
    # Decide pelo exit code, nao pela saida: o "git pull" escreve o
    # resumo do fetch (From ... / a..b main -> origin/main) no stderr
    # mesmo quando tem sucesso, entao capturar stderr dava falso alarme.
    PULL_OUT=$(cd "$PASTA_CONFIG" && git pull --ff-only 2>&1)
    PULL_RC=$?

    if [ "$PULL_RC" -ne 0 ]; then
        echo ""
        echo "   ⚠️ Não foi possível atualizar o repositório de configuração."
        echo ""
        echo "   Motivo:"
        echo "$PULL_OUT" | sed 's/^/   /'
        echo ""
        echo "   Seguindo com a cópia local. Se você editou arquivos em"
        echo "   $PASTA_CONFIG, mova-os para fora da pasta e rode de novo."
        echo ""
    fi
fi

# ============================================================
# 2. INSTALAR COMANDOS E BIBLIOTECA
#
# Copia bin/* para o $HOME. Antes os comandos eram gerados via
# heredoc; agora sao arquivos reais em bin/ e este passo apenas
# os instala.
# ============================================================

echo ">> Instalando comandos do FIAP LAB..."

bash "$SCRIPT_DIR/comandos.sh" >/dev/null

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Erro ao instalar os comandos do FIAP LAB."
    echo ""
    exit "$RC"
fi

# A partir daqui, tudo vem da lib.
source "$HOME/.fiaplab.lib.sh"

# ============================================================
# 3. SSH KEY
# ============================================================

echo ">> Configurando chave SSH..."

if [ -s "$PASTA_ENV/labsuser.pem" ]; then
    chmod 400 "$PASTA_ENV/labsuser.pem"

elif [ -f "$HOME/labsuser.pem" ]; then
    cp -f "$HOME/labsuser.pem" "$PASTA_ENV/labsuser.pem"
    chmod 400 "$PASTA_ENV/labsuser.pem"

else
    echo ""
    echo "❌ Chave labsuser.pem não encontrada."
    echo ""
    echo "Baixe a chave no AWS Academy (AWS Details > Download PEM)"
    echo "e envie para o CloudShell em: $HOME/labsuser.pem"
    echo ""
    exit 1
fi

# ============================================================
# 4. AWS CREDENTIALS
#
# aws_login prefere o provedor nativo do CloudShell, que se
# renova sozinho, e usa o arquivo estatico apenas como fallback
# e como insumo do scp para dentro da VM.
# ============================================================

echo ">> Configurando credenciais AWS..."

aws_require || exit 1

# ============================================================
# 5. FERRAMENTAS E AMBIENTE TEMPORARIO
# ============================================================

echo ">> Preparando ambiente temporário (Terraform, Ansible)..."

prepare_tools || {
    echo ""
    echo "❌ Não foi possível preparar as ferramentas do lab."
    echo ""
    exit 1
}

# ============================================================
# 6. AWS ACCOUNT
# ============================================================

if ! get_account_id; then
    echo ""
    echo "❌ Não foi possível identificar a conta AWS."
    echo ""
    exit 1
fi

echo ""
echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $AWS_REGION"
echo "S3 Bucket   : $BUCKET_NAME"
echo ""

# ============================================================
# 7. S3 BUCKET
# ============================================================

echo ">> Verificando bucket S3..."

if aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then

    echo "   Bucket já existe."

else

    echo "   Criando bucket..."

    if [ "$AWS_REGION" = "us-east-1" ]; then

        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION"

    else

        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration \
            LocationConstraint="$AWS_REGION"

    fi

    RC=$?

    if [ "$RC" -ne 0 ]; then
        echo ""
        echo "❌ Não foi possível criar o bucket de state:"
        echo "   $BUCKET_NAME"
        echo ""
        exit "$RC"
    fi
fi

# ============================================================
# 8. DYNAMODB LOCK - DESCONTINUADO
# ============================================================

# Histórico:
# O Terraform utilizava anteriormente o DynamoDB para realizar
# o locking do state.
#
# A configuração foi substituída por:
#
#     use_lockfile = true
#
# no backend S3.
#
# Portanto, esta seção foi mantida apenas como histórico e
# não deve mais criar, verificar ou utilizar a tabela DynamoDB.
#
# DYNAMO_TABLE="terraform-locks"
#
# echo ">> Verificando tabela DynamoDB..."
#
# if aws dynamodb describe-table \
#     --table-name "$DYNAMO_TABLE" \
#     --region "$AWS_REGION" \
#     >/dev/null 2>&1; then
#
#     echo "   Tabela já existe."
#
# else
#
#     echo "   Criando tabela..."
#
#     aws dynamodb create-table \
#         --table-name "$DYNAMO_TABLE" \
#         --attribute-definitions \
#             AttributeName=LockID,AttributeType=S \
#         --key-schema \
#             AttributeName=LockID,KeyType=HASH \
#         --billing-mode PAY_PER_REQUEST \
#         --region "$AWS_REGION"
#
#     echo "   Aguardando tabela ficar disponível..."
#
#     aws dynamodb wait table-exists \
#         --table-name "$DYNAMO_TABLE" \
#         --region "$AWS_REGION"
# fi

# ============================================================
# 9. INVENTORY
# ============================================================

# Inventario LOCAL do CloudShell, usado pelos scripts legados
# (preparar.sh, codeserver.sh). O menu do fiaplab.sh nao usa este
# arquivo: os playbooks dos projetos rodam contra as VMs, com o
# inventario gerado em $INVENTORY_DIR.
cat > "$CONFIG_DIR/hosts" <<HOSTS
[nodes]
cloudshell ansible_connection=local
HOSTS

# ============================================================
# 10. CRIAR A VM
# ============================================================

echo ""
echo "========================================"
echo "    CRIANDO FIAP LAB : MAQUINA VIRTUAL"
echo "========================================"

bash "$HOME/criar.sh" "$PROJETO_PADRAO"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Erro ao criar/configurar a infraestrutura $PROJETO_PADRAO."
    echo ""
    echo "Você pode tentar novamente com:"
    echo ""
    echo "   ~/fiaplab.sh   ->  1) Criar infraestrutura"
    echo ""
    exit "$RC"
fi

cfg_set LAST_PROJECT "$PROJETO_PADRAO"

# ============================================================
# 11. STATUS
# ============================================================

echo ""
echo "========================================"
echo "        AMBIENTE CONFIGURADO"
echo "========================================"
echo ""

df -h "$HOME"
echo ""
df -h /tmp
echo ""

bash "$HOME/ip" "$PROJETO_PADRAO"

echo ""
echo "========================================"
echo " Execute:"
echo ""
echo "   ~/fiaplab.sh"
echo ""
echo "========================================"
echo ""
