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

verify_container_profile() {
    local configured_profile
    configured_profile=$("$engine" container inspect --format '{{with index .Config.Labels "io.distrobox.ubuntu.profile"}}{{.}}{{end}}' "$container_id") ||
        fail "Falha ao consultar o tipo de ambiente de $container_name."
    # Contêineres criados antes da escolha de perfil pertencem ao perfil comum.
    configured_profile=${configured_profile:-common}
    [[ $configured_profile == "$profile" ]] ||
        fail "O contêiner $container_name usa o perfil '$configured_profile'. Para usar '$profile', escolha outro nome."
}

verify_shared_home() {
    local create_plan

    # O Assemble 1.7 pode só imprimir o comando; o create valida o hostname e resolve o HOME.
    create_plan=$(DBX_CONTAINER_MANAGER=$engine DBX_CONTAINER_CUSTOM_HOME='' DBX_CONTAINER_HOME_PREFIX='' \
        distrobox create --dry-run --name "$container_name" 9>&-) ||
        fail "O Distrobox rejeitou a criação de $container_name. Confira o diagnóstico acima."
    if [[ $create_plan == *DISTROBOX_HOST_HOME=* ]]; then
        fail 'O Distrobox está configurado para usar um HOME personalizado. Para usar --home shared, desative container_user_custom_home e container_home_prefix na configuração do Distrobox ou use --home separate.'
    fi
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
    # Com linger ativo, o serviço acompanha novos logins mesmo após o logout.
    # shellcheck disable=SC2016
    local start_on_login='
previous_sessions=
while true; do
    status=$(loginctl show-user "$UID" --property=State --property=Sessions) || exit 1
    state=
    sessions=
    while IFS== read -r property value; do
        case "$property" in
            State) state=$value ;;
            Sessions) sessions=$value ;;
        esac
    done <<< "$status"
    case "$state" in
        active|online)
            IFS=" " read -r -a session_ids <<< "$sessions"
            for session in "${session_ids[@]}"; do
                if [[ " $previous_sessions " != *" $session "* ]]; then
                    "$@" || exit 1
                    break
                fi
            done
            previous_sessions=$sessions
            ;;
        *) previous_sessions= ;;
    esac
    sleep 3 || exit 1
done'

    printf '[Unit]\nDescription=Iniciar o Distrobox %s no login\n' "$container_name"
    printf 'ConditionVirtualization=!container\n'
    printf 'StartLimitIntervalSec=5min\nStartLimitBurst=5\n'
    if [[ $engine == docker ]]; then
        printf 'After=docker.service\n'
    fi

    printf '\n[Service]\nType=exec\n'
    printf 'Restart=on-failure\nRestartSec=5s\n'
    if [[ $engine == docker ]]; then
        for setting in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG; do
            [[ -v $setting ]] || continue
            quoted=$(systemd_quote "$setting=${!setting}") || return 1
            printf 'Environment=%s\n' "$quoted"
        done
    fi
    quoted=$(systemd_quote "$engine_path") || return 1
    printf 'ExecStart=:/bin/bash -c %s iniciar-no-login %s start %s\n' "$(systemd_quote "$start_on_login")" "$quoted" "$container_id"
    printf '\n[Install]\nWantedBy=default.target\n'
}

disable_autostart() {
    local config_home unit link
    for config_home in "${XDG_CONFIG_HOME:-$HOME/.config}" "$HOME/.config"; do
        unit=$config_home/systemd/user/$service_name
        [[ -f $unit ]] || continue
        grep -Fxq "Description=Iniciar o Distrobox $container_name no login" "$unit" || continue
        if systemctl --user show-environment >/dev/null 2>&1; then
            systemctl --user disable --now "$service_name"
        else
            # Sem uma sessão ativa, retire o vínculo criado por WantedBy=default.target.
            link=${unit%/*}/default.target.wants/$service_name
            if [[ -L $link && $link -ef $unit ]]; then
                rm -- "$link"
            fi
        fi
        return
    done
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Uso: %s [--profile common|development] [--name NOME] [--home shared|separate] [--autostart yes|no]\n' "$0"
    printf 'Instala um Distrobox Ubuntu para uso comum ou desenvolvimento.\n'
    printf 'No terminal, o instalador pergunta pelas opções que você não informou.\n'
    printf 'Padrões: perfil common, nome Ubuntu (UbuntuDev para development), HOME shared e autostart yes.\n'
    exit 0
fi
[[ $EUID -ne 0 ]] || fail 'Execute este script na sua sessão de usuário. O instalador chama sudo para instalar pacotes.'

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=container-options.sh
source "$project_dir/container-options.sh"
read_container_options "$@"

manifest=$project_dir/ubuntu.ini
grep -Fxq '[Ubuntu]' "$manifest" || fail "A seção [Ubuntu] precisa existir em $manifest."
development_manifest=$project_dir/ubuntu-development.ini
if [[ $profile == development ]]; then
    [[ -r $development_manifest ]] || fail "Não foi possível ler $development_manifest."
fi

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

if [[ $autostart == yes ]]; then
    systemctl --user show-environment >/dev/null || fail 'A inicialização no login requer systemd de usuário. Use --autostart no para iniciar manualmente.'
fi
runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$EUID}
if [[ ! -d $runtime_dir || ! -w $runtime_dir ]]; then
    runtime_dir=${XDG_STATE_HOME:-$HOME/.local/state}/distroforge
    (umask 077; mkdir -p -- "$runtime_dir")
fi
exec 9>"$runtime_dir/distrobox-ubuntu-install.lock"
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
    verify_container_profile
else
    container_names=$("$engine" ps --all --format '{{.Names}}') || fail "Falha ao consultar o $engine."
    if grep -Fxq "$container_name" <<< "$container_names"; then
        fail "O nome $container_name já pertence a outro contêiner no $engine."
    fi
    host_name=$(uname -n)
    # O Distrobox antigo usa nome-do-contêiner.nome-do-host, com limite de 64 caracteres.
    if [[ -z ${DBX_CONTAINER_HOSTNAME:-} ]] && ((${#container_name} + ${#host_name} + 1 > 64)); then
        export DBX_CONTAINER_HOSTNAME=$host_name
    fi
    if [[ $home_mode == shared ]]; then
        verify_shared_home
    fi
fi

if [[ $home_mode == separate ]]; then
    ensure_separate_home_directory "$custom_home"
    printf 'HOME separado em %s\n' "$custom_home"
fi

if [[ -z $container_id ]]; then
    temporary_manifest=$(mktemp "$runtime_dir/distrobox-ubuntu.XXXXXX")
    awk -v name="$container_name" -v profile="$profile" -v development_manifest="$development_manifest" '
        BEGIN { label = "--label=io.distrobox.ubuntu.profile=" profile }
        function finish_section() {
            if (selected && !labeled) print "additional_flags=\"" label "\""
        }
        $0 == "[Ubuntu]" {
            print "[" name "]"
            if (profile == "development") {
                while ((status = (getline line < development_manifest)) > 0) print line
                if (status < 0) exit 1
                close(development_manifest)
            }
            selected = 1
            next
        }
        /^\[/ { finish_section(); selected = 0 }
        selected && /^[[:space:]]*home[[:space:]]*=/ { next }
        selected && !labeled && /^[[:space:]]*additional_flags[[:space:]]*=/ {
            # Envie o rótulo na mesma opção para compatibilidade com o Assemble 1.7.
            flags = $0
            sub(/^[^=]*=[[:space:]]*/, "", flags)
            if (flags ~ /^["\047]/) flags = substr(flags, 1, 1) label " " substr(flags, 2)
            else flags = label " " flags
            print "additional_flags=" flags
            labeled = 1
            next
        }
        { print }
        END { finish_section() }
    ' "$manifest" > "$temporary_manifest"

    printf 'Criando o Distrobox %s (perfil %s) com %s.\n' "$container_name" "$profile" "$engine"
    DBX_CONTAINER_MANAGER=$engine DBX_CONTAINER_CUSTOM_HOME=$custom_home DBX_CONTAINER_HOME_PREFIX='' \
        distrobox assemble create --name "$container_name" --file "$temporary_manifest" 9>&-
    container_id=$(find_container_id "$engine") || fail "Falha ao verificar o contêiner no $engine."
    verify_container_home
    verify_container_profile
fi

printf 'Inicializando o Distrobox %s. A primeira execução pode demorar.\n' "$container_name"
DBX_CONTAINER_MANAGER=$engine distrobox enter --no-tty --no-workdir --name "$container_name" -- /usr/bin/true 9>&- ||
    fail "Falha ao inicializar o contêiner. Consulte os logs com: $engine logs $container_name"
if [[ $home_mode == separate ]]; then
    ensure_separate_home_access "$engine" "$container_id" "$custom_home" 9>&- ||
        fail "Não foi possível preparar o acesso ao HOME separado de $container_name: $custom_home"
    prepare_separate_home "$custom_home"
fi

host_tools=()
for tool in podman docker; do
    if command -v "$tool" >/dev/null; then
        host_tools+=("$tool")
    fi
done
if ((${#host_tools[@]})); then
    "$engine" exec --user 0 "$container_id" /bin/sh -eu -c '
        helper=/usr/bin/distrobox-host-exec
        test -x "$helper"
        mkdir -p /usr/local/bin
        for tool do
            shortcut=/usr/local/bin/$tool
            if ! command -v "$tool" >/dev/null && [ ! -e "$shortcut" ] && [ ! -L "$shortcut" ]; then
                ln -s -- "$helper" "$shortcut"
            fi
        done
    ' ferramentas-do-host "${host_tools[@]}" 9>&- || fail 'Não foi possível preparar os atalhos para o Podman ou Docker do hospedeiro.'
fi

if [[ $profile == development ]]; then
    "$engine" exec --interactive --user 0 "$container_id" /bin/bash -s \
        < "$project_dir/install-asdf.sh" 9>&- || fail "Não foi possível instalar o asdf em $container_name."
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
    "$engine" exec --interactive --user 0 "$container_id" /bin/bash -s -- "$account" "$container_name" "$profile" \
        < "$project_dir/setup-zsh.sh" 9>&- || fail "Não foi possível configurar o Oh My Zsh em $container_name."
fi

if [[ $autostart == yes ]]; then
    engine_path=$(realpath -s -- "$(type -P "$engine")")
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
    systemctl --user enable "$service_dir/$service_name" ||
        fail "Falha ao habilitar o serviço $service_name."
    systemctl --user restart "$service_name" ||
        fail "Falha ao iniciar o serviço. Consulte: journalctl --user -u $service_name"
    printf 'Inicialização no login ativa.\n'
else
    disable_autostart || fail "Falha ao desabilitar o serviço $service_name."
    printf 'Inicialização no login desativada.\n'
fi

printf 'Para entrar, execute: DBX_CONTAINER_MANAGER=%s distrobox enter %s\n' "$engine" "$container_name"
