#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

install_packages() {
    local packages=("$@")

    command -v sudo >/dev/null || fail 'A instalação dos pacotes do sistema requer sudo.'
    if command -v apt-get >/dev/null; then
        if [[ ${packages[*]} == *podman* ]]; then
            packages+=(uidmap slirp4netns fuse-overlayfs)
        fi
        sudo apt-get update && sudo apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null; then
        sudo dnf install -y "${packages[@]}"
    elif command -v pacman >/dev/null; then
        sudo pacman -S --needed --noconfirm "${packages[@]}"
    elif command -v zypper >/dev/null; then
        sudo zypper --non-interactive install "${packages[@]}"
    else
        fail 'A instalação automática de pacotes requer APT, DNF, Pacman ou Zypper.'
    fi
}

find_container_id() {
    "$1" ps --all --no-trunc --filter 'label=manager=distrobox' --format '{{.ID}} {{.Names}}' |
        awk -v name="$container_name" '"x" $2 == "x" name { print $1 }'
}

verify_container_home() {
    local home_template='{{range .Config.Env}}{{if ge (len .) 5}}{{if eq (slice . 0 5) "HOME="}}{{println (slice . 5)}}{{end}}{{end}}{{end}}'
    local configured_home

    [[ $container_id =~ ^[[:xdigit:]]{64}$ ]] || fail "O Distrobox $container_name não foi encontrado no $engine."
    configured_home=$("$engine" container inspect --format "$home_template" "$container_id" | awk 'length($0) { home = $0 } END { print home }') ||
        fail "Falha ao consultar o HOME do contêiner $container_name."
    [[ -n $configured_home ]] || fail "O $engine não informou o HOME do contêiner $container_name."
    [[ ${configured_home%/} == "$expected_home" ]] ||
        fail "O contêiner $container_name usa o HOME '$configured_home'. Para usar '$expected_home', escolha outro nome."
}

select_engine() {
    local candidate candidate_id existing_engine=''
    engine=''
    container_id=''

    for candidate in podman docker; do
        command -v "$candidate" >/dev/null || continue
        candidate_id=$(find_container_id "$candidate" 2>/dev/null) || continue
        engine=${engine:-$candidate}
        if [[ -n $candidate_id && $candidate_id != "$container_id" ]]; then
            [[ -z $existing_engine ]] || fail "Há um Distrobox $container_name no Podman e outro no Docker."
            existing_engine=$candidate
            container_id=$candidate_id
        fi
    done

    engine=${existing_engine:-$engine}
}

systemd_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    printf '"%s"' "$value"
}

write_service() {
    local engine_path=$1
    local setting quoted
    # Com linger ativo, o serviço aguarda o login. Expanda as variáveis só no serviço.
    # shellcheck disable=SC2016
    local wait_for_login='
while true; do
    state=$(loginctl show-user "$UID" --property=State --value) || exit 1
    case "$state" in
        active|online) exec "$@" ;;
    esac
    sleep 3
done'

    printf '[Unit]\nDescription=Iniciar o Distrobox %s no login\n' "$container_name"
    printf 'ConditionVirtualization=!container\n'
    printf 'StartLimitIntervalSec=5min\nStartLimitBurst=5\n'
    if [[ $engine == docker ]]; then
        printf 'After=docker.service\n'
    fi

    printf '\n[Service]\nType=exec\nRemainAfterExit=yes\n'
    printf 'Restart=on-failure\nRestartSec=5s\n'
    if [[ $engine == docker ]]; then
        for setting in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG; do
            [[ -v $setting ]] || continue
            quoted=$(systemd_quote "$setting=${!setting}") || return 1
            printf 'Environment=%s\n' "$quoted"
        done
    fi
    quoted=$(systemd_quote "$engine_path") || return 1
    printf 'ExecStart=:/bin/bash -c %s aguardar-login %s start %s\n' "$(systemd_quote "$wait_for_login")" "$quoted" "$container_id"
    printf '\n[Install]\nWantedBy=default.target\n'
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Uso: %s [--name NOME] [--home shared|separate]\n' "$0"
    printf 'Instala o Distrobox Ubuntu e habilita a inicialização no login.\n'
    printf 'No terminal, o instalador pergunta pelas opções que você não informou.\n'
    printf 'Padrões: nome Ubuntu e HOME compartilhado (shared).\n'
    exit 0
fi
[[ $EUID -ne 0 ]] || fail 'Execute este script na sua sessão de usuário. O instalador chama sudo para instalar pacotes.'

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=container-options.sh
source "$project_dir/container-options.sh"
read_container_options "$@"

manifest=$project_dir/ubuntu.ini
grep -Fxq '[Ubuntu]' "$manifest" || fail "A seção [Ubuntu] precisa existir em $manifest."

if [[ $container_name == Ubuntu ]]; then
    service_name=distrobox-ubuntu.service
else
    service_name=distrobox-ubuntu-$container_name.service
fi

custom_home=''
expected_home=${HOME%/}
if [[ $home_mode == separate ]]; then
    home_base=${XDG_DATA_HOME:-$HOME/.local/share}
    custom_home=${home_base%/}/distrobox/homes/$container_name
    # Versões mais antigas do Distrobox interpolam esse caminho em comandos do shell.
    unsupported_home_chars='[\\":$`[:cntrl:]]'
    [[ $custom_home == /* && ! $custom_home =~ $unsupported_home_chars ]] ||
        fail "O Distrobox precisa de um caminho absoluto e sem caracteres especiais para o HOME separado: $custom_home"
    expected_home=$custom_home
fi

systemctl --user show-environment >/dev/null || fail 'É necessária uma sessão ativa com systemd de usuário.'
[[ -d ${XDG_RUNTIME_DIR:-} ]] || fail 'A sessão precisa definir XDG_RUNTIME_DIR.'
exec 9>"$XDG_RUNTIME_DIR/distrobox-ubuntu-install.lock"
flock -n 9 || fail 'Já existe uma instalação em andamento para este usuário.'
temporary_manifest=''
temporary_unit=''
trap 'rm -f -- "$temporary_manifest" "$temporary_unit"' EXIT

select_engine
packages=()
if [[ -z $engine ]] && ! command -v podman >/dev/null; then
    packages+=(podman)
fi
if ! command -v distrobox >/dev/null; then
    packages+=(distrobox)
fi
if ((${#packages[@]})); then
    printf 'Instalando pacotes do sistema: %s\n' "${packages[*]}"
    install_packages "${packages[@]}" 9>&- || fail 'A instalação dos pacotes falhou. Veja a saída do gerenciador de pacotes.'
    hash -r
    if [[ -z $engine ]]; then
        select_engine
    fi
fi
if [[ -z $engine ]]; then
    if command -v podman >/dev/null; then
        podman info >&2 || true
    fi
    fail 'Podman ou Docker precisa estar acessível ao usuário atual. O Podman local precisa de suporte a execução sem root.'
fi
command -v distrobox >/dev/null || fail 'O executável distrobox precisa estar no PATH.'

if [[ $engine == podman ]] && command -v getsubids >/dev/null; then
    username=$(id -un)
    if ! { getsubids "$username" || getsubids "$EUID"; } >/dev/null 2>&1 ||
        ! { getsubids -g "$username" || getsubids -g "$EUID"; } >/dev/null 2>&1; then
        fail "O usuário $username precisa de faixas de UID e GID subordinados para o Podman. Verifique /etc/subuid e /etc/subgid."
    fi
fi

if [[ -n $container_id ]]; then
    verify_container_home
else
    container_names=$("$engine" ps --all --format '{{.Names}}') || fail "Falha ao consultar o $engine."
    if grep -Fxq "$container_name" <<< "$container_names"; then
        fail "O nome $container_name já pertence a outro contêiner no $engine."
    fi
fi

if [[ $home_mode == separate ]]; then
    ensure_separate_home_directory "$custom_home"
    printf 'HOME separado em %s\n' "$custom_home"
fi

if [[ -z $container_id ]]; then
    temporary_manifest=$(mktemp "$XDG_RUNTIME_DIR/distrobox-ubuntu.XXXXXX")
    awk -v name="$container_name" '
        $0 == "[Ubuntu]" { print "[" name "]"; selected = 1; next }
        /^\[/ { selected = 0 }
        selected && /^[[:space:]]*home[[:space:]]*=/ { next }
        { print }
    ' "$manifest" > "$temporary_manifest"

    printf 'Criando o Distrobox %s com %s.\n' "$container_name" "$engine"
    DBX_CONTAINER_MANAGER=$engine DBX_CONTAINER_CUSTOM_HOME=$custom_home DBX_CONTAINER_HOME_PREFIX='' \
        distrobox assemble create --name "$container_name" --file "$temporary_manifest" 9>&-
    container_id=$(find_container_id "$engine") || fail "Falha ao verificar o contêiner no $engine."
    verify_container_home
fi

engine_path=$(realpath -s -- "$(type -P "$engine")")
printf 'Inicializando o Distrobox %s. A primeira execução pode demorar.\n' "$container_name"
DBX_CONTAINER_MANAGER=$engine distrobox enter --no-tty --no-workdir --name "$container_name" -- /usr/bin/true 9>&- ||
    fail "Falha ao inicializar o contêiner. Consulte os logs com: $engine logs $container_name"
if [[ $home_mode == separate ]]; then
    ensure_separate_home_access "$engine" "$container_id" "$custom_home" 9>&- ||
        fail "Não foi possível preparar o acesso ao HOME separado de $container_name: $custom_home"
    prepare_separate_home "$custom_home"
fi

terminal_profile=$("$engine" container inspect --format '{{index .Config.Labels "io.distrobox.ubuntu.terminal"}}' "$container_id") ||
    fail "Falha ao consultar o perfil de terminal de $container_name."
if [[ $terminal_profile == oh-my-zsh ]]; then
    account=$(id -un)
    login_shell=$("$engine" exec --user "$account" "$container_id" /usr/bin/getent passwd "$account" | cut -d: -f7) ||
        fail "Falha ao consultar o shell de login de $container_name."
    [[ ${login_shell##*/} == zsh ]] ||
        fail "O contêiner $container_name usa o shell '$login_shell'. O manifesto solicita /usr/bin/zsh."
    printf 'Preparando o Oh My Zsh em %s.\n' "$container_name"
    "$engine" exec --interactive --user 0 "$container_id" /bin/bash -s -- "$account" "$container_name" \
        < "$project_dir/setup-zsh.sh" 9>&- || fail "Não foi possível configurar o Oh My Zsh em $container_name."
fi

default_service_dir=$HOME/.config/systemd/user
service_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
if [[ $service_dir != "$default_service_dir" ]]; then
    unit_paths=$(systemctl --user show --property=UnitPath --value)
    if [[ " $unit_paths " != *" $service_dir "* && " $unit_paths " == *" $default_service_dir "* ]]; then
        service_dir=$default_service_dir
    fi
fi
mkdir -p -- "$service_dir"
temporary_unit=$(mktemp "$service_dir/.${service_name}.XXXXXX")
write_service "$engine_path" > "$temporary_unit"
mv -fT -- "$temporary_unit" "$service_dir/$service_name"

systemctl --user daemon-reload
systemctl --user enable --now "$service_dir/$service_name" ||
    fail "Falha ao iniciar o serviço. Consulte: journalctl --user -u $service_name"

printf 'Inicialização no login ativa. Para entrar, execute: DBX_CONTAINER_MANAGER=%s distrobox enter %s\n' "$engine" "$container_name"
