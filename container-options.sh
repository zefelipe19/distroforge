#!/usr/bin/env bash

valid_container_name() {
    local LC_ALL=C
    [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,127}$ ]]
}

read_container_options() {
    local answer
    container_name=''
    home_mode=''

    while (($#)); do
        case $1 in
            --name)
                [[ -n ${2:-} ]] || fail 'Informe o nome após --name.'
                container_name=$2
                shift 2
                ;;
            --home)
                [[ ${2:-} == shared || ${2:-} == separate ]] || fail 'Use --home shared ou --home separate.'
                home_mode=$2
                shift 2
                ;;
            *) fail "Opção desconhecida: $1. Use --help para consultar o uso." ;;
        esac
    done

    if [[ -z $container_name && -t 0 ]]; then
        while :; do
            read -r -p 'Nome do contêiner [Ubuntu]: ' answer || fail 'Seleção interrompida.'
            container_name=${answer:-Ubuntu}
            valid_container_name "$container_name" && break
            printf 'Use de 2 a 128 caracteres. Comece com letra ou número e use apenas letras, números, ponto, hífen ou sublinhado.\n' >&2
        done
    fi
    container_name=${container_name:-Ubuntu}
    valid_container_name "$container_name" || fail 'Nome inválido. Use de 2 a 128 caracteres, começando com letra ou número e usando apenas letras, números, ponto, hífen ou sublinhado.'

    if [[ -z $home_mode && -t 0 ]]; then
        while :; do
            read -r -p 'Usar um HOME separado? [s/N]: ' answer || fail 'Seleção interrompida.'
            case ${answer,,} in
                s|sim) home_mode=separate; break ;;
                ''|n|não|nao) home_mode=shared; break ;;
                *) printf 'Digite s para separado ou n para compartilhado.\n' >&2 ;;
            esac
        done
    fi
    home_mode=${home_mode:-shared}
}

write_user_dirs_config() (
    local config_dir=$1
    shift
    local config_file=$config_dir/user-dirs.dirs
    local temporary_config

    [[ ! -L $config_dir && ! -e $config_file && ! -L $config_file ]] || return 0
    (umask 077; mkdir -p -- "$config_dir")
    temporary_config=$(mktemp "$config_dir/.user-dirs.XXXXXX")
    trap 'rm -f -- "$temporary_config"' EXIT
    printf '%s\n' "$@" > "$temporary_config"
    ln -T -- "$temporary_config" "$config_file" || [[ -e $config_file || -L $config_file ]]
)

ensure_separate_home_directory() {
    local private_home=$1
    [[ ! -L $private_home ]] || fail "O destino do HOME separado é um link simbólico: $private_home"
    (umask 077; mkdir -p -- "$private_home")
    [[ ! $private_home -ef $HOME ]] || fail 'O HOME separado aponta para o próprio HOME do hospedeiro.'
}

prepare_separate_home() {
    local private_home=$1
    local host_home private_path xdg_config entry key directory source_path name destination target
    local line raw_path base
    local assignment='^[[:space:]]*XDG_([A-Z]+)_DIR="(.*)"[[:space:]]*(#.*)?$'
    local -a entries=(DESKTOP:Desktop DOCUMENTS:Documents DOWNLOAD:Downloads MUSIC:Music
                      PICTURES:Pictures VIDEOS:Videos TEMPLATES:Templates PUBLICSHARE:Public PROJECTS:Projects)
    local -a xdg_settings=()
    local -A host_dirs=()

    private_path=$(realpath -e -- "$private_home")
    host_home=$(realpath -e -- "$HOME")
    xdg_config=${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs

    if [[ -r $xdg_config ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line =~ $assignment ]] || continue
            key=${BASH_REMATCH[1]}
            raw_path=${BASH_REMATCH[2]}
            case $raw_path in
                \$HOME|\$HOME/*) base=$HOME; raw_path=${raw_path:5} ;;
                /*) base='' ;;
                *) continue ;;
            esac
            host_dirs[$key]=$base$(printf '%s' "$raw_path" | sed 's/\\\(["\\$`]\)/\1/g')
        done < "$xdg_config"
    fi

    for entry in "${entries[@]}"; do
        key=${entry%%:*}
        directory=${host_dirs[$key]:-$HOME/${entry#*:}}
        [[ $directory == /* && -d $directory ]] || continue
        source_path=$(realpath -e -- "$directory") || continue
        if [[ $source_path == / || $source_path == "$host_home" ||
              $source_path == "$private_path" || $private_path == "$source_path/"* ||
              $source_path == "$private_path/"* ]]; then
            continue
        fi

        name=${directory%/}
        name=${name##*/}
        case $name in .|..|.config|.cache|.local) continue ;; esac
        destination=$private_home/$name
        if [[ $source_path == "$host_home/"* ]]; then
            target=${HOME%/}/${source_path#"$host_home/"}
        else
            # O Distrobox monta a raiz do hospedeiro neste caminho.
            target=/run/host$source_path
        fi

        if [[ ! -e $destination && ! -L $destination ]]; then
            ln -sT -- "$target" "$destination"
        elif [[ ! -L $destination || $(readlink -- "$destination") != "$target" ]]; then
            printf 'Mantendo o item existente em %s\n' "$destination" >&2
            [[ -d $destination ]] || continue
        fi

        [[ $name != *$'\n'* && $name != *$'\r'* ]] || continue
        name=${name//\\/\\\\}
        name=${name//\"/\\\"}
        name=${name//\$/\\\$}
        name=${name//\`/\\\`}
        xdg_settings+=("XDG_${key}_DIR=\"\$HOME/$name\"")
    done

    if ((${#xdg_settings[@]})); then
        write_user_dirs_config "$private_home/.config" "${xdg_settings[@]}"
    fi
}

ensure_separate_home_access() {
    local engine=$1 container=$2 home=$3 account
    local -a user_dirs=(.config .config/fish .cache .local .local/share .local/share/fish .local/state)
    # As variáveis de ambos os comandos são expandidas dentro do contêiner.
    # shellcheck disable=SC2016
    local check_access='
home=$1
shift
[ -d "$home" ] && [ -w "$home" ] && [ -x "$home" ] || exit 1
for relative do
    path=$home/$relative
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ ! -d "$path" ] || [ ! -w "$path" ] || [ ! -x "$path" ]; then
        printf "Sem acesso de gravação em %s\n" "$path" >&2
        exit 1
    fi
done'
    # shellcheck disable=SC2016
    local repair_access='
home=$(realpath -e -- "$1")
uid=$(id -u "$2")
gid=$(id -g "$2")
shift 2
[ "$uid" -gt 0 ]
for relative do
    path=$home/$relative
    [ -d "$path" ] || continue
    (
        cd -P -- "$path"
        [ "$(pwd -P)" = "${path%/.}" ] || exit 0
        chown --from=0:0 -- "$uid:$gid" .
    )
done'

    account=$(id -un)
    if "$engine" exec --user "$account" "$container" /bin/sh -eu -c "$check_access" verificar-home "$home" "${user_dirs[@]}" 2>/dev/null; then
        return 0
    fi

    printf 'Corrigindo a propriedade dos diretórios do HOME separado.\n'
    "$engine" exec --user 0 "$container" /bin/sh -eu -c "$repair_access" corrigir-home "$home" "$account" . "${user_dirs[@]}" || return 1
    "$engine" exec --user "$account" "$container" /bin/sh -eu -c "$check_access" verificar-home "$home" "${user_dirs[@]}"
}
