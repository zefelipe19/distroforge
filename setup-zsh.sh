#!/usr/bin/env bash
set -euo pipefail

account=$1
container_name=$2
profile=${3:-common}
user_id=$(id -u "$account")
user_home=$(getent passwd "$account" | cut -d: -f6)
[[ $user_id -ne 0 && $user_home == /* && $container_name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]

# Instala o framework e a configuração com as permissões do usuário do contêiner.
runuser -u "$account" -- /bin/bash -s -- "$user_home" "$container_name" "$profile" <<'USER_SETUP'
set -euo pipefail
umask 077
export HOME=$1
dot_dir=$HOME/.config/distrobox/zsh/$2
omz_dir=$dot_dir/oh-my-zsh
mkdir -p -- "$dot_dir/cache"
if [[ $3 == development ]]; then
    mkdir -p -- "$dot_dir/asdf"
fi

if [[ ! -s $omz_dir/oh-my-zsh.sh ]]; then
    if [[ -e $omz_dir || -L $omz_dir ]]; then
        printf 'Instalação incompleta do Oh My Zsh em %s\n' "$omz_dir" >&2
        exit 1
    fi
    temporary_repo=$(mktemp -d "$dot_dir/.oh-my-zsh.XXXXXX")
    trap 'rm -rf -- "$temporary_repo"' EXIT
    GIT_TERMINAL_PROMPT=0 git clone --depth=1 -- https://github.com/ohmyzsh/ohmyzsh.git "$temporary_repo"
    [[ -s $temporary_repo/oh-my-zsh.sh ]]
    mv -T -- "$temporary_repo" "$omz_dir"
    trap - EXIT
fi

# Impede a migração do marcador legado de atualização a partir do HOME compartilhado.
if [[ ! -e $dot_dir/cache/.zsh-update && ! -L $dot_dir/cache/.zsh-update ]]; then
    touch -- "$dot_dir/cache/.zsh-update"
fi

if [[ ! -e $dot_dir/.zshrc && ! -L $dot_dir/.zshrc ]]; then
    temporary_zshrc=$(mktemp "$dot_dir/.zshrc.XXXXXX")
    trap 'rm -f -- "$temporary_zshrc"' EXIT
    cat > "$temporary_zshrc" <<'ZSHRC'
export ZSH="$ZDOTDIR/oh-my-zsh"
ZSH_CUSTOM="$ZSH/custom"
ZSH_CACHE_DIR="$ZDOTDIR/cache"
ZSH_COMPDUMP="$ZSH_CACHE_DIR/.zcompdump"
HISTFILE="$ZDOTDIR/.zsh_history"
ZSH_THEME=robbyrussell
plugins=(git sudo colored-man-pages)
zstyle ':omz:update' mode disabled
source "$ZSH/oh-my-zsh.sh"

PROMPT="%F{cyan}[${ZDOTDIR:t}]%f $PROMPT"
bindkey -e
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZSHRC
    ln -T -- "$temporary_zshrc" "$dot_dir/.zshrc" || [[ -e $dot_dir/.zshrc || -L $dot_dir/.zshrc ]]
fi
USER_SETUP

# O Zsh lê este arquivo do contêiner antes de consultar os arquivos do usuário.
{
    cat <<ZSHENV
if [[ -o rcs && \$EUID -eq $user_id ]]; then
    export SHELL=/usr/bin/zsh
    export ZDOTDIR="\$HOME/.config/distrobox/zsh/$container_name"
ZSHENV
    if [[ $profile == development ]]; then
        cat <<'ASDF_CONFIG'
    export ASDF_DATA_DIR="$ZDOTDIR/asdf"
    typeset -U path
    path=("$ASDF_DATA_DIR/shims" /usr/local/bin "${path[@]}")
    if [[ -o interactive ]]; then
        export EDITOR="${EDITOR:-vim}"
        export VISUAL="${VISUAL:-$EDITOR}"
        export PAGER="${PAGER:-less}"
    fi
ASDF_CONFIG
    fi
    printf 'fi\n'
} > /etc/zsh/distrobox.zshenv
source_line='source /etc/zsh/distrobox.zshenv'
if ! grep -Fxq -- "$source_line" /etc/zsh/zshenv; then
    printf '\n%s\n' "$source_line" >> /etc/zsh/zshenv
fi
