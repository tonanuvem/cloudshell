#!/bin/bash

# ============================================================
# destruir-varias.sh - destroi lotes do ubuntu-vm
#
# Cada lote criado pelo criar-varias.sh com sufixo tem state proprio
# (ubuntu-vm/<sufixo>/terraform.tfstate) com sua VPC e instancias.
# Este script lista os lotes existentes (a partir dos states no S3),
# deixa escolher um ou todos, e faz "terraform destroy" por lote,
# apagando tambem o state (sem valor apos destruir).
# ============================================================

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJETO="ubuntu-vm"

echo ""
echo "========================================"
echo " DESTRUIR LOTES ($PROJETO)"
echo "========================================"
echo ""

aws_require || exit 1

if ! get_account_id; then
    echo "❌ Não foi possível identificar a conta AWS."
    exit 1
fi

# ------------------------------------------------------------
# Lista os lotes a partir dos states no S3
# ------------------------------------------------------------

mapfile -t KEYS < <(aws s3api list-objects-v2 \
    --bucket "$BUCKET_NAME" --prefix "$PROJETO/" \
    --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -v '^$')

LOTES=()
for KEY in "${KEYS[@]}"; do
    case "$KEY" in
        "$PROJETO"/terraform.tfstate)
            LOTES+=("") ;;                                  # lote padrao
        "$PROJETO"/*/terraform.tfstate)
            S="${KEY#"$PROJETO"/}"
            LOTES+=("${S%/terraform.tfstate}") ;;
        *) continue ;;                                      # .tflock etc
    esac
done

if [ "${#LOTES[@]}" -eq 0 ]; then
    echo "Nenhum lote encontrado (nenhum state em $PROJETO/ no S3)."
    exit 0
fi

echo "Lotes existentes:"
for i in "${!LOTES[@]}"; do
    S="${LOTES[$i]}"
    echo "  $((i + 1))) ${S:-(padrão)}"
done
echo ""
echo "  T) TODOS      C) Cancelar"
echo ""

# ------------------------------------------------------------
# Destroi um lote e apaga o state
# ------------------------------------------------------------

destruir_lote() {

    local SUF="$1"

    "$BIN_DIR/destruir.sh" "$PROJETO" "$SUF"
    local RC=$?

    if [ "$RC" -eq 0 ]; then
        local KEY
        KEY="$(tf_state_key "$PROJETO" "$SUF")"
        aws s3 rm "s3://$BUCKET_NAME/$KEY" 2>/dev/null
        aws s3 rm "s3://$BUCKET_NAME/${KEY}.tflock" 2>/dev/null
        echo "🗑️  state removido: $KEY"
    fi

    return "$RC"
}

read -rp "Qual lote destruir? " ESC

case "$ESC" in

    [Cc])
        echo "Cancelado."
        exit 0
        ;;

    [Tt])
        echo ""
        read -rp "Confirma destruir TODOS os ${#LOTES[@]} lote(s)? (s/N): " CONF
        [[ "$CONF" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

        RC=0
        for S in "${LOTES[@]}"; do
            echo ""
            echo ">> Lote: ${S:-(padrão)}"
            destruir_lote "$S" || RC=1
        done
        exit "$RC"
        ;;

    *)
        if [[ "$ESC" =~ ^[0-9]+$ ]] && [ "$ESC" -ge 1 ] && [ "$ESC" -le "${#LOTES[@]}" ]; then
            S="${LOTES[$((ESC - 1))]}"
            echo ""
            read -rp "Confirma destruir o lote '${S:-(padrão)}'? (s/N): " CONF
            [[ "$CONF" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }
            destruir_lote "$S"
            exit $?
        fi
        echo "❌ Opção inválida."
        exit 1
        ;;
esac
