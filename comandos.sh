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
LANCADORES=(fiaplab.sh ip)

for NOME in "${LANCADORES[@]}"; do

    if [ ! -x "$BIN_DIR/$NOME" ]; then
        echo "❌ Comando não encontrado: $BIN_DIR/$NOME"
        exit 1
    fi

    cat > "$HOME/$NOME" <<LAUNCH
#!/bin/bash
# Lancador gerado por comandos.sh -- executa a partir do repositorio.
# NAO edite: edite $BIN_DIR/$NOME.
exec "$BIN_DIR/$NOME" "\$@"
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
