# cloudshell

Ambiente FIAP LAB para o AWS CloudShell: prepara Terraform + Ansible e
cria a VM (code-server) a partir do repositório
[tonanuvem/config](https://github.com/tonanuvem/config).

## Uso

```bash
bash init.sh      # prepara o ambiente e cria a ubuntu-vm
~/fiaplab.sh      # menu: ligar, suspender, conectar, ansible, destruir...
```

## Estrutura

| Arquivo            | Papel |
|--------------------|-------|
| `init.sh`          | Bootstrap: clona o config, instala os comandos, prepara credenciais/Terraform/Ansible e cria a VM. |
| `comandos.sh`      | Instalador: copia `bin/*` para o `$HOME`. |
| `bin/`             | Comandos reais (antes gerados por heredoc). **Edite aqui.** |
| `bin/fiaplab.lib.sh` | Biblioteca comum: credenciais, account id, `/tmp`, Terraform, Ansible. Instalada como `~/.fiaplab.lib.sh`. |
| `credenciais.sh`   | Gera `~/.aws/credentials` avulso (uso manual). |
| `remove.sh`        | Destrói a infraestrutura e limpa o ambiente. |

Para alterar um comando (`fiaplab.sh`, `criar.sh`, etc.), edite o
arquivo em `bin/` e rode `bash comandos.sh` para reinstalar.
