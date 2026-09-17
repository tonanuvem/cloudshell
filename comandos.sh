#!/bin/bash

# ============================================================
# FIAP LAB - INSTALADOR DO LANCADOR
#
# Os comandos do FIAP LAB rodam a partir de bin/, sem copias no
# $HOME: cada script localiza a lib e os irmaos pelo proprio
# diretorio (BIN_DIR).
#
# Este script instala apenas o lancador ~/fiaplab.sh, para o
# aluno continuar digitando "~/fiaplab.sh". O lancador aponta
# para bin/fiaplab.sh deste repositorio.
#
# Historico: antes este script GERAVA cada comando via heredoc;
# depois passou a COPIAR bin/* para o $HOME; agora so instala o
# lancador. bin/ e a unica fonte de verdade.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

# Lancadores instalados no $HOME (apontam para bin/, com o caminho
# do repo embutido). Regerados a cada init, entao acompanham o local
# do repositorio se ele mudar.
for NOME in fiaplab.sh ip; do
    if [ ! -x "$BIN_DIR/$NOME" ]; then
        echo "❌ Comando não encontrado: $BIN_DIR/$NOME"
        exit 1
    fi
done

# ------------------------------------------------------------
# Lancadores no $HOME: ~/fiaplab.sh e ~/ip.
#
# Cada um verifica se o repo existe, atualiza-o (git pull, best-effort)
# e so entao executa o comando em bin/. O pull fica no lancador (fora
# do repo, no $HOME) para reescrever bin/ com seguranca antes do exec
# -- sem o risco de um script se auto-modificar enquanto roda.
#
# best-effort: com timeout, silencioso e --ff-only. Sem rede, com
# GitHub fora do ar ou com edicoes locais no clone, o pull falha sem
# quebrar e o comando roda com a versao atual.
#
# Desative o update com FIAPLAB_NO_UPDATE=1.
# ------------------------------------------------------------

for NOME in fiaplab.sh ip; do

    cat > "$HOME/$NOME" <<LAUNCH
#!/bin/bash
# Lancador gerado por comandos.sh -- NAO edite; edite $BIN_DIR/$NOME.
REPO="$SCRIPT_DIR"
BIN="$BIN_DIR/$NOME"
if [ ! -x "\$BIN" ]; then
    echo ""
    echo "❌ FIAP LAB não encontrado em: \$REPO"
    echo ""
    echo "A pasta do projeto foi movida ou removida. Para restaurar:"
    echo ""
    echo "   git clone https://github.com/tonanuvem/cloudshell \"\$REPO\""
    echo "   bash \"\$REPO/init.sh\""
    echo ""
    exit 1
fi
if [ -z "\$FIAPLAB_NO_UPDATE" ] && [ -d "\$REPO/.git" ]; then
    # timeout protege contra rede lenta; se nao existir, roda direto.
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 git -C "\$REPO" pull --ff-only --quiet 2>/dev/null
    else
        git -C "\$REPO" pull --ff-only --quiet 2>/dev/null
    fi
fi
exec "\$BIN" "\$@"
LAUNCH

    chmod +x "$HOME/$NOME"

done

echo ""
echo "========================================"
echo " LANÇADORES INSTALADOS"
echo "========================================"
echo ""
echo "Menu:  ~/fiaplab.sh"
echo "IPs:   ~/ip"
echo ""
