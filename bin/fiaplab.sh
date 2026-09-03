#!/bin/bash

# ============================================================
# FIAP LAB - MENU PRINCIPAL
#
# REGRA DE PROJETOS:
#
# S3
#   -> fonte dos projetos que possuem Terraform State
#
# CONFIG LOCAL
#   -> fonte dos projetos Terraform disponíveis para criação
#
# TELA INICIAL:
#   -> somente projetos do S3
#
# SE S3 ESTIVER VAZIO:
#   -> nenhum projeto é selecionado
#   -> usuário entra no menu
#   -> opção 1 mostra projetos locais
#
# OPÇÃO 8:
#   -> somente projetos existentes no S3
#
# NÃO usa:
#   set -e
#   source comandos.sh
# ============================================================

# A lib traz: credenciais, account id, /tmp, terraform e ansible.
# Antes, estas ~200 linhas viviam duplicadas aqui e nos demais
# scripts, ja com divergencias entre as copias.
source "$HOME/.fiaplab.lib.sh"

CURRENT_PROJECT=""

S3_PROJECTS=()
LOCAL_PROJECTS=()

# ok | expirado | sem_bucket | sem_conta | erro
S3_STATUS="ok"


# ============================================================
# LISTAR PROJETOS COM STATE NO S3
#
# Só considera prefixos que possuam:
#
#   <projeto>/terraform.tfstate
#
# Não transforma None/null em projeto.
# ============================================================

get_s3_projects() {

    S3_PROJECTS=()
    S3_STATUS="ok"

    if [ -z "$BUCKET_NAME" ]; then
        S3_STATUS="sem_conta"
        return 1
    fi

    local S3_JSON S3_ERR

    # O erro era silenciado com 2>/dev/null e o array vazio fazia o
    # menu dizer "nenhum projeto no S3" -- inclusive quando o motivo
    # era token vencido, mandando o aluno recriar infra que existe.
    S3_ERR=$(aws s3api list-objects-v2 \
        --bucket "$BUCKET_NAME" \
        --output json 2>&1 >"$TMP_APP_DIR/s3.json")

    if [ "$?" -ne 0 ]; then

        case "$S3_ERR" in
            *ExpiredToken*|*InvalidClientTokenId*|*RequestExpired*)
                S3_STATUS="expirado" ;;
            *NoSuchBucket*|*NotFound*|*404*)
                S3_STATUS="sem_bucket" ;;
            *)
                S3_STATUS="erro" ;;
        esac

        return 1
    fi

    S3_JSON=$(cat "$TMP_APP_DIR/s3.json" 2>/dev/null)

    if [ -z "$S3_JSON" ]; then
        return 0
    fi

    while IFS= read -r KEY; do

        [ -z "$KEY" ] && continue
        [ "$KEY" = "None" ] && continue
        [ "$KEY" = "null" ] && continue

        case "$KEY" in
            */terraform.tfstate)
                PROJECT="${KEY%/terraform.tfstate}"

                [ -z "$PROJECT" ] && continue
                [ "$PROJECT" = "None" ] && continue
                [ "$PROJECT" = "null" ] && continue

                S3_PROJECTS+=("$PROJECT")
                ;;
        esac

    done < <(
        echo "$S3_JSON" |
        jq -r '
            .Contents[]?.Key? // empty
        '
    )

    # Remove duplicados.
    if [ "${#S3_PROJECTS[@]}" -gt 0 ]; then

        mapfile -t S3_PROJECTS < <(
            printf '%s\n' "${S3_PROJECTS[@]}" |
            grep -v '^$' |
            sort -u
        )

    fi
}


# ============================================================
# LISTAR PROJETOS TERRAFORM LOCAIS
# ============================================================

get_local_projects() {

    LOCAL_PROJECTS=()

    if [ ! -d "$CONFIG_DIR" ]; then
        return 0
    fi

    for DIR in "$CONFIG_DIR"/*; do

        [ -d "$DIR" ] || continue

        if find "$DIR" \
            -maxdepth 1 \
            -type f \
            -name "*.tf" |
            grep -q .; then

            PROJECT=$(basename "$DIR")

            [ -z "$PROJECT" ] && continue
            [ "$PROJECT" = "None" ] && continue
            [ "$PROJECT" = "null" ] && continue

            LOCAL_PROJECTS+=("$PROJECT")
        fi

    done

    if [ "${#LOCAL_PROJECTS[@]}" -gt 0 ]; then

        mapfile -t LOCAL_PROJECTS < <(
            printf '%s\n' "${LOCAL_PROJECTS[@]}" |
            grep -v '^$' |
            sort -u
        )

    fi
}


# ============================================================
# TESTAR SE PROJETO POSSUI STATE
# ============================================================

project_has_state() {

    local PROJECT="$1"

    [ -z "$PROJECT" ] && return 1
    [ "$PROJECT" = "None" ] && return 1
    [ "$PROJECT" = "null" ] && return 1

    for P in "${S3_PROJECTS[@]}"; do

        if [ "$P" = "$PROJECT" ]; then
            return 0
        fi

    done

    return 1
}


# ============================================================
# TESTAR SE PROJETO LOCAL EXISTE
# ============================================================

project_exists_local() {

    local PROJECT="$1"

    [ -z "$PROJECT" ] && return 1
    [ "$PROJECT" = "None" ] && return 1
    [ "$PROJECT" = "null" ] && return 1

    if [ ! -d "$CONFIG_DIR/$PROJECT" ]; then
        return 1
    fi

    find "$CONFIG_DIR/$PROJECT" \
        -maxdepth 1 \
        -type f \
        -name "*.tf" |
        grep -q .
}


# ============================================================
# SELECIONAR PROJETO EXISTENTE NO S3
#
# Usado:
#   - inicialização quando existe state
#   - opção 8
#
# SOMENTE projetos do S3.
# ============================================================

select_s3_project() {

    get_s3_projects

    if [ "${#S3_PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "⚠️ Nenhum projeto possui state no S3."
        echo ""

        return 1
    fi

    # --------------------------------------------------------
    # Um único projeto
    # --------------------------------------------------------

    if [ "${#S3_PROJECTS[@]}" -eq 1 ]; then

        PROJECT="${S3_PROJECTS[0]}"

        if ! project_exists_local "$PROJECT"; then

            echo ""
            echo "⚠️ O projeto '$PROJECT' existe no S3,"
            echo "mas não possui código Terraform local:"
            echo ""
            echo "   $CONFIG_DIR/$PROJECT"
            echo ""

            echo "O projeto não pode ser selecionado."
            echo ""

            return 1
        fi

        CURRENT_PROJECT="$PROJECT"

        echo ""
        echo "Projeto selecionado automaticamente:"
        echo "  $CURRENT_PROJECT"
        echo ""

        return 0
    fi

    # --------------------------------------------------------
    # Vários projetos
    # --------------------------------------------------------

    echo ""
    echo "========================================"
    echo " PROJETOS EXISTENTES NO S3"
    echo "========================================"
    echo ""

    VALID_PROJECTS=()

    for P in "${S3_PROJECTS[@]}"; do

        if project_exists_local "$P"; then

            VALID_PROJECTS+=("$P")

            echo "$(( ${#VALID_PROJECTS[@]} )) ) $P"

        else

            echo "     $P [SEM CÓDIGO LOCAL]"
        fi

    done

    if [ "${#VALID_PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "❌ Nenhum projeto do S3 possui código Terraform local."
        echo ""
        echo "Verifique:"
        echo "   $CONFIG_DIR"
        echo ""

        return 1
    fi

    echo ""

    while true; do

        read -rp "Escolha o projeto: " NUMERO

        if [[ "$NUMERO" =~ ^[0-9]+$ ]]; then

            INDEX=$((NUMERO - 1))

            if [ "$INDEX" -ge 0 ] && \
               [ "$INDEX" -lt "${#VALID_PROJECTS[@]}" ]; then

                CURRENT_PROJECT="${VALID_PROJECTS[$INDEX]}"

                echo ""
                echo "Projeto selecionado: $CURRENT_PROJECT"
                echo ""

                return 0
            fi
        fi

        echo "❌ Opção inválida."
    done
}


# ============================================================
# SELECIONAR PROJETO PARA CRIAÇÃO
#
# Aqui podem aparecer:
#
#   projeto existente no S3
#   projeto novo local
#
# Portanto, é diferente da tela inicial.
# ============================================================

select_create_project() {

    get_s3_projects
    get_local_projects

    if [ "${#LOCAL_PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "❌ Nenhum projeto Terraform local encontrado."
        echo ""
        echo "Verifique:"
        echo "   $CONFIG_DIR"
        echo ""

        return 1
    fi

    CREATE_PROJECTS=()

    for P in "${LOCAL_PROJECTS[@]}"; do
        CREATE_PROJECTS+=("$P")
    done

    # --------------------------------------------------------
    # Apenas um projeto local
    # --------------------------------------------------------

    if [ "${#CREATE_PROJECTS[@]}" -eq 1 ]; then

        CURRENT_PROJECT="${CREATE_PROJECTS[0]}"

        echo ""
        echo "Projeto encontrado:"
        echo "  $CURRENT_PROJECT"
        echo ""

        return 0
    fi

    # --------------------------------------------------------
    # Menu de criação
    # --------------------------------------------------------

    echo ""
    echo "========================================"
    echo " CRIAR INFRAESTRUTURA"
    echo "========================================"
    echo ""

    for i in "${!CREATE_PROJECTS[@]}"; do

        P="${CREATE_PROJECTS[$i]}"

        if project_has_state "$P"; then
            echo "$((i + 1))) $P [S3 STATE]"
        else
            echo "$((i + 1))) $P [NOVO]"
        fi

    done

    echo ""

    while true; do

        read -rp "Escolha o projeto: " NUMERO

        if [[ "$NUMERO" =~ ^[0-9]+$ ]]; then

            INDEX=$((NUMERO - 1))

            if [ "$INDEX" -ge 0 ] && \
               [ "$INDEX" -lt "${#CREATE_PROJECTS[@]}" ]; then

                CURRENT_PROJECT="${CREATE_PROJECTS[$INDEX]}"

                echo ""
                echo "Projeto selecionado: $CURRENT_PROJECT"
                echo ""

                return 0
            fi
        fi

        echo "❌ Opção inválida."
    done
}


# ============================================================
# STATUS RESUMIDO
# ============================================================

show_menu_status() {

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo "Conta AWS     : ${ACCOUNT_ID:-desconhecida}"

    if [ -n "$CURRENT_PROJECT" ]; then
        echo "Projeto atual : $CURRENT_PROJECT"
        echo "State         : s3://$BUCKET_NAME/$CURRENT_PROJECT"
    else
        echo "Projeto atual : nenhum"
        echo "State         : nenhum projeto selecionado"
    fi

    case "$S3_STATUS" in
        expirado)
            echo "----------------------------------------"
            echo "Credencial    : VENCIDA"
            echo ""
            echo "Clique em 'Start Lab' no AWS Academy e"
            echo "reabra o CloudShell. A infraestrutura na"
            echo "AWS continua intacta."
            ;;
        erro)
            echo "----------------------------------------"
            echo "Credencial    : erro ao consultar o S3"
            ;;
    esac

    echo "========================================"
    echo ""
}


# ============================================================
# PAUSA
# ============================================================

pause_menu() {

    echo ""
    read -rp "Pressione ENTER para continuar..."
}


# ============================================================
# EXECUTAR OPERAÇÃO
# ============================================================

run_operation() {

    local SCRIPT="$1"

    if [ -z "$CURRENT_PROJECT" ]; then

        echo ""
        echo "❌ Nenhum projeto selecionado."
        echo ""

        return 1
    fi

    # Renova a credencial na hora da operacao, nao no boot.
    aws_require || return 1

    echo ""

    "$HOME/$SCRIPT" "$CURRENT_PROJECT"

    RC=$?

    echo ""

    if [ "$RC" -eq 0 ]; then

        echo "========================================"
        echo " Operação concluída."
        echo "========================================"

    else

        echo "========================================"
        echo " ⚠️ Operação terminou com erro."
        echo "========================================"

    fi

    return "$RC"
}


# ============================================================
# INICIALIZAÇÃO
# ============================================================

prepare_tools || {
    echo ""
    echo "❌ Não foi possível preparar as ferramentas do lab."
    echo ""
    pause_menu
    exit 1
}

aws_require

# O account id vem do cache em ~/.fiaplab quando a chamada online
# falha, entao o menu abre mesmo com credencial vencida: o aluno ve
# o estado do lab e a instrucao do que fazer, em vez de ser expulso.
if ! get_account_id; then

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo ""
    echo "Ainda não foi possível identificar a conta AWS."
    echo ""
    echo "Verifique se o laboratório está iniciado no AWS Academy"
    echo "(botão 'Start Lab', círculo verde) e abra o CloudShell"
    echo "novamente."
    echo ""

    pause_menu
    exit 1
fi

# ------------------------------------------------------------
# PRIMEIRO CARREGAMENTO
#
# Se houver state no S3:
#   seleciona somente entre eles.
#
# Se S3 estiver vazio:
#   não seleciona projeto.
#   opção 1 fará a seleção local.
# ------------------------------------------------------------

get_s3_projects

LAST_PROJECT=$(cfg_get LAST_PROJECT)

if [ "${#S3_PROJECTS[@]}" -gt 0 ]; then

    # Retoma o ultimo projeto usado, se ele ainda existir.
    if [ -n "$LAST_PROJECT" ] && \
       project_has_state "$LAST_PROJECT" && \
       project_exists_local "$LAST_PROJECT"; then

        CURRENT_PROJECT="$LAST_PROJECT"

        echo ""
        echo "Projeto retomado: $CURRENT_PROJECT"
        echo ""

    elif ! select_s3_project; then

        echo ""
        echo "⚠️ Existem states no S3, mas nenhum projeto"
        echo "pode ser usado com o código local atual."
        echo ""
        echo "Use a opção 1) Criar infraestrutura."
        echo ""

        CURRENT_PROJECT=""
    fi

elif [ "$S3_STATUS" != "ok" ]; then

    echo ""
    echo "⚠️ Não foi possível listar os projetos no S3."
    echo ""

    CURRENT_PROJECT=""

else

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo ""
    echo "⚠️ Nenhum projeto possui infraestrutura"
    echo "registrada no S3."
    echo ""
    echo "Para criar uma nova infraestrutura,"
    echo "selecione a opção:"
    echo ""
    echo "  1) Criar infraestrutura"
    echo ""

    CURRENT_PROJECT=""
fi


# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do

    # --------------------------------------------------------
    # Recupera /tmp caso o CloudShell tenha limpado.
    # --------------------------------------------------------

    prepare_tools

    # --------------------------------------------------------
    # Atualiza lista do S3.
    # --------------------------------------------------------

    get_s3_projects

    if [ -n "$CURRENT_PROJECT" ]; then
        cfg_set LAST_PROJECT "$CURRENT_PROJECT"
    fi

    show_menu_status

    echo "1) Criar infraestrutura"
    echo "2) Ligar VM(s)"
    echo "3) Suspender VM(s)"
    echo "4) Conectar via SSH"
    echo "5) Executar Ansible"
    echo "6) Mostrar IP"
    echo "7) Destruir infraestrutura"
    echo "8) Trocar projeto"
    echo "0) Sair"
    echo ""

    read -rp "Escolha uma opção: " OPCAO

    case "$OPCAO" in

        # ----------------------------------------------------
        # CRIAR
        # ----------------------------------------------------

        1)

            if select_create_project; then

                run_operation "criar.sh"

                # Depois do primeiro apply, o projeto deverá
                # aparecer no S3.
                get_s3_projects

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # LIGAR
        # ----------------------------------------------------

        2)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""
                echo "Use primeiro:"
                echo "  1) Criar infraestrutura"
                echo ""

            else

                run_operation "ligar.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # SUSPENDER
        # ----------------------------------------------------

        3)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "suspender.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # SSH
        # ----------------------------------------------------

        4)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                echo ""
                read -rp "Número da VM: " NUMERO

                if ! [[ "$NUMERO" =~ ^[0-9]+$ ]] || \
                   [ "$NUMERO" -lt 1 ]; then

                    echo "❌ Número inválido."

                else

                    "$HOME/conectar.sh" \
                        "$CURRENT_PROJECT" \
                        "$NUMERO"

                fi

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # ANSIBLE
        # ----------------------------------------------------

        5)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "ansible.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # IP
        # ----------------------------------------------------

        6)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "ip"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # DESTROY
        # ----------------------------------------------------

        7)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "destruir.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # TROCAR PROJETO
        #
        # SOMENTE S3.
        # ----------------------------------------------------

        8)

            if [ "${#S3_PROJECTS[@]}" -eq 0 ]; then

                echo ""
                echo "⚠️ Não existem projetos no S3."
                echo ""
                echo "Para criar o primeiro projeto:"
                echo "  1) Criar infraestrutura"
                echo ""

            else

                if select_s3_project; then
                    echo ""
                    echo "✅ Projeto alterado para:"
                    echo "   $CURRENT_PROJECT"
                fi

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # SAIR
        # ----------------------------------------------------

        0)

            echo ""
            echo "Saindo..."
            exit 0
            ;;


        # ----------------------------------------------------
        # INVÁLIDO
        # ----------------------------------------------------

        *)

            echo ""
            echo "❌ Opção inválida."
            pause_menu
            ;;

    esac

done
