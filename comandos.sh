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
# ~/fiaplab.sh : atualiza o repo antes de abrir o menu
#
# O auto-update fica no lancador (nao no proprio menu) porque o
# lancador vive no $HOME, fora do repo: assim o "git pull" pode
# reescrever bin/ com seguranca e so entao o exec roda o menu ja
# atualizado -- sem o risco de um script bash se auto-modificar
# enquanto executa.
#
# best-effort: com timeout, silencioso e --ff-only. Sem rede, com
# GitHub fora do ar ou com edicoes locais no clone, o pull falha
# sem quebrar e o menu abre com a versao atual.
#
# Desative com FIAPLAB_NO_UPDATE=1.
# ------------------------------------------------------------

cat > "$HOME/fiaplab.sh" <<LAUNCH
#!/bin/bash
# Lancador gerado por comandos.sh -- NAO edite; edite $BIN_DIR/fiaplab.sh.
REPO="$SCRIPT_DIR"
if [ -z "\$FIAPLAB_NO_UPDATE" ] && [ -d "\$REPO/.git" ]; then
    # timeout protege contra rede lenta; se nao existir, roda direto.
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 git -C "\$REPO" pull --ff-only --quiet 2>/dev/null
    else
        git -C "\$REPO" pull --ff-only --quiet 2>/dev/null
    fi
fi
exec "$BIN_DIR/fiaplab.sh" "\$@"
LAUNCH
chmod +x "$HOME/fiaplab.sh"

# ------------------------------------------------------------
# ~/ip : lancador simples (sem update, para nao adicionar rede a
# um comando rapido -- o menu ja atualiza o repo).
# ------------------------------------------------------------

cat > "$HOME/ip" <<LAUNCH
#!/bin/bash
# Lancador gerado por comandos.sh -- NAO edite; edite $BIN_DIR/ip.
exec "$BIN_DIR/ip" "\$@"
LAUNCH
chmod +x "$HOME/ip"

echo ""
echo "========================================"
echo " LANÇADORES INSTALADOS"
echo "========================================"
echo ""
echo "Menu:  ~/fiaplab.sh"
echo "IPs:   ~/ip"
echo ""
