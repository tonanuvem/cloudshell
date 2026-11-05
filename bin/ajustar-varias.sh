#!/bin/bash

# ============================================================
# ajustar-varias.sh - reaplica a configuracao Ansible nos lotes
#
# Terceiro script do trio de lotes, nos mesmos moldes dos outros
# dois:
#
#     criar-varias.sh     cria N VMs (lote com state proprio)
#     destruir-varias.sh  destroi um lote (ou todos)
#     ajustar-varias.sh   reaplica os YAML num lote (ou em todos)
#
# Por que existe: o criar.sh roda o ajustar.sh (ou os playbooks)
# UMA vez, no fim do apply. Depois disso nao havia como reaplicar
# num lote -- o ansible.sh recebe so o projeto, sem sufixo, e
# acabaria rodando sempre contra o state do lote padrao. Depois de
# suspender/religar, os IPs publicos trocam e cada lote precisa de
# um inventario novo; editar um playbook tambem pede reaplicacao.
#
# Para cada lote escolhido:
#
#   1. tf_init no state DAQUELE lote (<projeto>/<sufixo>/...)
#   2. apply -refresh-only, para pegar os IPs atuais das VMs
#   3. espera o sshd das VMs aceitar conexao
#   4. roda o ajustar.sh do projeto -- ou, na falta dele, os
#      playbooks YAML da pasta do projeto
#
# No fim, o state volta para o lote padrao: o .terraform da pasta
# do projeto e compartilhado, e deixa-lo apontando para o ultimo
# lote faria ligar/suspender/conectar operarem no lote errado.
#
# Uso:  ajustar-varias.sh [projeto]      (default: ubuntu-vm)
# ============================================================

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJETO="${1:-ubuntu-vm}"
TF_DIR="$CONFIG_DIR/$PROJETO"

echo ""
echo "========================================"
echo " AJUSTAR LOTES ($PROJETO)"
echo "========================================"
echo ""

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

# Precisa de Terraform (state/IPs) e Ansible (playbooks).
prepare_tools || exit 1

aws_require || exit 1

if ! get_account_id; then
    echo "❌ Não foi possível identificar a conta AWS."
    exit 1
fi

# ------------------------------------------------------------
# O QUE VAI SER APLICADO
#
# Decidido UMA vez, antes do loop: com varios playbooks, perguntar
# a cada lote transformaria "TODOS" numa sequencia de prompts.
#
# PLANO=ajustar   -> ajustar.sh do projeto (caminho canonico)
# PLANO=playbooks -> PLAYBOOKS[] rodados em ordem
# ------------------------------------------------------------

AJUSTAR="$TF_DIR/ajustar.sh"
PLANO=""
PLAYBOOKS=()

if [ -f "$AJUSTAR" ]; then

    PLANO="ajustar"
    echo "Configuração: ajustar.sh do projeto"

else

    while IFS= read -r FILE; do
        PLAYBOOKS+=("$FILE")
    done < <(
        find "$TF_DIR" \
            -maxdepth 1 \
            -type f \
            \( -name "*.yml" -o -name "*.yaml" \) \
            -print |
        sort
    )

    if [ "${#PLAYBOOKS[@]}" -eq 0 ]; then
        echo "❌ O projeto '$PROJETO' não possui ajustar.sh nem playbooks."
        echo ""
        echo "   $TF_DIR"
        echo ""
        exit 1
    fi

    PLANO="playbooks"

    if [ "${#PLAYBOOKS[@]}" -gt 1 ]; then

        echo "Playbooks disponíveis:"
        echo ""

        for i in "${!PLAYBOOKS[@]}"; do
            echo "  $((i + 1))) $(basename "${PLAYBOOKS[$i]}")"
        done

        echo ""
        echo "  T) TODOS (na ordem acima)"
        echo ""

        read -rp "Qual aplicar? " ESC_PB

        if [[ ! "$ESC_PB" =~ ^[Tt]$ ]]; then

            if ! [[ "$ESC_PB" =~ ^[0-9]+$ ]] ||
               [ "$ESC_PB" -lt 1 ] ||
               [ "$ESC_PB" -gt "${#PLAYBOOKS[@]}" ]; then
                echo "❌ Opção inválida."
                exit 1
            fi

            PLAYBOOKS=("${PLAYBOOKS[$((ESC_PB - 1))]}")
        fi
    fi

    echo ""
    echo "Configuração: ${#PLAYBOOKS[@]} playbook(s)"
    for PB in "${PLAYBOOKS[@]}"; do
        echo "   - $(basename "$PB")"
    done

    # Os playbooks sao rodados daqui (o ajustar.sh traz a sua chave),
    # entao a chave do lab tem de existir.
    KEY="$ENV_DIR/labsuser.pem"

    if [ ! -f "$KEY" ]; then
        echo ""
        echo "❌ Chave SSH não encontrada: $KEY"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Lista os lotes a partir dos states no S3
# ------------------------------------------------------------

# mapfile (e nao $(...)) porque o lote padrao vem como linha vazia.
mapfile -t LOTES < <(tf_list_batches "$PROJETO")

if [ "${#LOTES[@]}" -eq 0 ]; then
    echo ""
    echo "Nenhum lote encontrado (nenhum state em $PROJETO/ no S3)."
    exit 0
fi

echo ""
echo "Lotes existentes:"
for i in "${!LOTES[@]}"; do
    S="${LOTES[$i]}"
    echo "  $((i + 1))) ${S:-(padrão)}"
done
echo ""
echo "  T) TODOS      C) Cancelar"
echo ""

# ------------------------------------------------------------
# restaurar_padrao : devolve o .terraform ao lote padrao
#
# tf_init usa -reconfigure e troca o state key DA PASTA do
# projeto. Sem isto, as opcoes do menu (ligar/suspender/conectar/
# ip), que usam tf_ensure_init e saem na hora quando ja existe
# um .terraform, passariam a enxergar o ultimo lote ajustado.
# ------------------------------------------------------------

restaurar_padrao() {
    tf_init "$PROJETO" "" >/dev/null 2>&1
}

# ------------------------------------------------------------
# ajustar_lote : reaplica a configuracao num lote
# ------------------------------------------------------------

ajustar_lote() {

    local SUF="$1"
    local RC N IP
    local -a VM_IPS

    echo ""
    echo "----------------------------------------"
    echo " Lote: ${SUF:-(padrão)}"
    echo " State: s3://$BUCKET_NAME/$(tf_state_key "$PROJETO" "$SUF")"
    echo "----------------------------------------"
    echo ""

    # Mesmas variaveis do criar.sh, para o lote ser lido como foi
    # criado (tag/nome das VMs). Sem sufixo, volta ao default do
    # projeto -- um unset explicito, senao o valor vazaria do lote
    # anterior quando rodamos TODOS.
    if [ -n "$SUF" ]; then
        export TF_VAR_ec2_name="$SUF"
    else
        unset TF_VAR_ec2_name
    fi

    echo ">> Terraform init (state do lote)..."

    if ! tf_init "$PROJETO" "$SUF" >/dev/null 2>&1; then
        echo ""
        echo "❌ Terraform init falhou neste lote; repetindo sem silenciar:"
        echo ""
        tf_init "$PROJETO" "$SUF" || return 1
    fi

    # Quantidade a partir do proprio state: o refresh-only nao muda
    # infraestrutura, mas o Terraform ainda exige as variaveis, e o
    # valor correto evita um plano com diferencas.
    N=$(tf_instance_ids "$PROJETO" | grep -v '^[[:space:]]*$' | wc -l)

    if [ "$N" -lt 1 ]; then
        echo "⚠️ Nenhuma instância no state deste lote; pulando."
        return 0
    fi

    export TF_VAR_quantidade="$N"

    echo ">> Atualizando IPs de $N VM(s) (refresh-only)..."

    # Igual ao ansible.sh: so sincroniza o state. Falha aqui nao e
    # fatal -- os outputs anteriores ainda podem servir.
    tf_run_unlock "$TF_DIR" apply -refresh-only -auto-approve -input=false \
        >/dev/null 2>&1 ||
        echo "   ⚠️ refresh-only falhou; seguindo com os IPs do state."

    # ------------------------------------------------------------
    # Espera o SSH (VM religada leva ~30s para aceitar conexao)
    # ------------------------------------------------------------

    mapfile -t VM_IPS < <(tf_public_ips "$PROJETO" | grep -v '^[[:space:]]*$')

    if [ "${#VM_IPS[@]}" -eq 0 ]; then
        echo ""
        echo "❌ Nenhum IP público neste lote (VMs suspensas?)."
        echo "   Ligue as VMs antes de ajustar."
        return 1
    fi

    echo ">> Aguardando as VMs aceitarem SSH..."
    for IP in "${VM_IPS[@]}"; do
        wait_for_ssh "$IP" ||
            echo "   ⚠️ $IP não respondeu SSH a tempo; seguindo mesmo assim."
    done
    echo ""

    # ------------------------------------------------------------
    # Inventario POR LOTE
    #
    # Um arquivo por lote (<projeto>-<sufixo>.hosts): com nome
    # unico, lotes ajustados em sequencia nao sobrescrevem o
    # inventario um do outro.
    # ------------------------------------------------------------

    local INV="$INVENTORY_DIR/${PROJETO}${SUF:+-$SUF}.hosts"

    mkdir -p "$INVENTORY_DIR"

    if [ "$PLANO" = "ajustar" ]; then

        # O ajustar.sh monta o proprio inventario neste caminho.
        export FIAPLAB_INVENTORY="$INV"

        echo ">> Executando ajustar.sh do projeto..."
        echo ""

        # CWD na pasta do projeto: alguns ajustar.sh leem "terraform
        # output" sem -chdir e so funcionam a partir do diretorio deles.
        ( cd "$TF_DIR" && bash "$AJUSTAR" )
        RC=$?

    else

        if ! tf_write_inventory "$PROJETO" "$INV"; then
            echo "❌ Não foi possível montar o inventário deste lote."
            return 1
        fi

        echo "Inventário ($(basename "$INV")):"
        cat "$INVENTORY_FILE"
        echo ""

        # Nao para no primeiro erro: mostra a falha, segue para os
        # proximos playbooks e cobra o resumo no fim. Uma etapa que
        # falha por causa de rede (download de pacote, handshake TLS)
        # nao deve impedir as etapas seguintes, que costumam ser
        # independentes -- e reaplicar o lote inteiro so por causa
        # dela custa minutos. Com FIAPLAB_PARAR_NO_ERRO=1 volta o
        # comportamento antigo (aborta na primeira falha).
        RC=0

        local PB NOME TOTAL=${#PLAYBOOKS[@]} N=0
        local -a FALHOU=()

        for PB in "${PLAYBOOKS[@]}"; do

            NOME="$(basename "$PB")"
            N=$((N + 1))

            echo "------------------------------------------------------------"
            echo " Playbook $N/$TOTAL : $NOME"
            echo "------------------------------------------------------------"
            echo ""

            if ansible-playbook \
                -i "$INVENTORY_FILE" \
                -u ubuntu \
                --key-file "$KEY" \
                "$PB"; then

                echo ""
                echo "✅ $NOME aplicado."

            else

                RC=1
                FALHOU+=("$NOME")

                echo ""
                echo "❌ $NOME falhou (veja o erro acima)."

                if [ -n "$FIAPLAB_PARAR_NO_ERRO" ]; then
                    echo "   FIAPLAB_PARAR_NO_ERRO=1: interrompendo este lote."
                    break
                fi

                echo "   Seguindo para o próximo playbook."
            fi

            echo ""
        done

        if [ "${#FALHOU[@]}" -gt 0 ]; then
            echo "Playbooks com erro neste lote (${#FALHOU[@]}/$TOTAL):"
            for NOME in "${FALHOU[@]}"; do
                echo "   - $NOME"
            done
        fi
    fi

    echo ""

    if [ "$RC" -eq 0 ]; then
        echo "✅ Lote '${SUF:-(padrão)}' ajustado."
    else
        echo "⚠️ Lote '${SUF:-(padrão)}' ajustado PARCIALMENTE (houve erro)."
    fi

    return "$RC"
}

# ------------------------------------------------------------
# Escolha do lote
# ------------------------------------------------------------

read -rp "Qual lote ajustar? " ESC

case "$ESC" in

    [Cc])
        echo "Cancelado."
        exit 0
        ;;

    [Tt])
        echo ""
        read -rp "Confirma ajustar TODOS os ${#LOTES[@]} lote(s)? (s/N): " CONF
        [[ "$CONF" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

        RC=0
        for S in "${LOTES[@]}"; do
            ajustar_lote "$S" || RC=1
        done

        restaurar_padrao

        echo ""
        if [ "$RC" -eq 0 ]; then
            echo "========================================"
            echo " ✅ Todos os lotes ajustados."
            echo "========================================"
        else
            echo "========================================"
            echo " ⚠️ Algum lote terminou com erro."
            echo "========================================"
        fi

        exit "$RC"
        ;;

    *)
        if [[ "$ESC" =~ ^[0-9]+$ ]] && [ "$ESC" -ge 1 ] && [ "$ESC" -le "${#LOTES[@]}" ]; then

            S="${LOTES[$((ESC - 1))]}"

            echo ""
            read -rp "Confirma ajustar o lote '${S:-(padrão)}'? (s/N): " CONF
            [[ "$CONF" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

            ajustar_lote "$S"
            RC=$?

            restaurar_padrao

            exit "$RC"
        fi

        echo "❌ Opção inválida."
        exit 1
        ;;
esac
