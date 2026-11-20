#!/usr/bin/env bash

valid_container_name() {
    local LC_ALL=C
    [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,127}$ ]]
}

read_container_options() {
    local answer default_name
    container_name=''
    home_mode=''
    profile=''
    autostart=''

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
            --profile)
                [[ ${2:-} == common || ${2:-} == development ]] || fail 'Use --profile common ou --profile development.'
                profile=$2
                shift 2
                ;;
            --autostart)
                [[ ${2:-} == yes || ${2:-} == no ]] || fail 'Use --autostart yes ou --autostart no.'
                autostart=$2
                shift 2
                ;;
            *) fail "Opção desconhecida: $1. Use --help para consultar o uso." ;;
        esac
    done

    if [[ -z $profile && -t 0 ]]; then
        while :; do
            read -r -p 'Tipo de ambiente [1] Comum, [2] Desenvolvimento (1): ' answer || fail 'Seleção interrompida.'
            case $answer in
                ''|1) profile=common; break ;;
                2) profile=development; break ;;
                *) printf 'Digite 1 para comum ou 2 para desenvolvimento.\n' >&2 ;;
            esac
        done
    fi
    profile=${profile:-common}
    default_name=Ubuntu
    if [[ $profile == development ]]; then
        default_name=UbuntuDev
    fi

    if [[ -z $container_name && -t 0 ]]; then
        while :; do
            read -r -p "Nome do contêiner [$default_name]: " answer || fail 'Seleção interrompida.'
            container_name=${answer:-$default_name}
            valid_container_name "$container_name" && break
            printf 'Use de 2 a 128 caracteres. Comece com letra ou número e use apenas letras, números, ponto, hífen ou sublinhado.\n' >&2
        done
    fi
    container_name=${container_name:-$default_name}
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

    if [[ -z $autostart && -t 0 ]]; then
        while :; do
            read -r -p 'Iniciar o contêiner automaticamente no login? [S/n]: ' answer || fail 'Seleção interrompida.'
            case ${answer,,} in
                ''|s|sim) autostart=yes; break ;;
                n|não|nao) autostart=no; break ;;
                *) printf 'Digite s para iniciar no login ou n para iniciar manualmente.\n' >&2 ;;
            esac
        done
    fi
    autostart=${autostart:-yes}
}

write_user_dirs_config() (
    local config_dir=$1
    local legacy_settings=$2
    shift 2
    local config_file=$config_dir/user-dirs.dirs
    local temporary_config

    [[ ! -L $config_dir && ! -L $config_file ]] || return 0
    if [[ -e $config_file ]]; then
        # Atualize apenas arquivos que correspondem ao conteúdo gerado antes da correção.
        [[ -f $config_file ]] && cmp -s -- "$config_file" <(printf '%s\n' "$legacy_settings") || return 0
        cmp -s -- "$config_file" <(printf '%s\n' "$@") && return 0
    fi
    (umask 077; mkdir -p -- "$config_dir")
    temporary_config=$(mktemp "$config_dir/.user-dirs.XXXXXX")
    trap 'rm -f -- "$temporary_config"' EXIT
    printf '%s\n' "$@" > "$temporary_config"
    if [[ -f $config_file && ! -L $config_file ]] &&
        cmp -s -- "$config_file" <(printf '%s\n' "$legacy_settings"); then
        chmod --reference="$config_file" -- "$temporary_config"
        mv -fT -- "$temporary_config" "$config_file"
    else
        ln -T -- "$temporary_config" "$config_file" || [[ -e $config_file || -L $config_file ]]
    fi
)

xdg_user_dir_setting() {
    local key=$1 name=$2
    name=${name//\\/\\\\}
    name=${name//\"/\\\"}
    name=${name//\$/\\\$}
    name=${name//\`/\\\`}
    printf 'XDG_%s_DIR="$HOME/%s"' "$key" "$name"
}

ensure_separate_home_directory() {
    local private_home=$1
    [[ ! -L $private_home ]] || fail "O destino do HOME separado é um link simbólico: $private_home"
    (umask 077; mkdir -p -- "$private_home")
    [[ ! $private_home -ef $HOME ]] || fail 'O HOME separado aponta para o próprio HOME do hospedeiro.'
}

prepare_separate_home() {
    local private_home=$1
    local host_home private_path xdg_config entry key directory source_path name destination target
    local line raw_path base existing_target count
    local assignment='^[[:space:]]*XDG_([A-Z]+)_DIR="(.*)"[[:space:]]*(#.*)?$'
    local -a entries=(DESKTOP:Desktop DOCUMENTS:Documents DOWNLOAD:Downloads MUSIC:Music
                      PICTURES:Pictures VIDEOS:Videos TEMPLATES:Templates PUBLICSHARE:Public PROJECTS:Projects)
    local -a xdg_settings=() legacy_settings=()
    local -A host_dirs=() mapped_targets=()

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
        [[ $name != *$'\n'* && $name != *$'\r'* ]] || continue
        destination=$private_home/$name
        if [[ $source_path == "$host_home/"* ]]; then
            target=${HOME%/}/${source_path#"$host_home/"}
        else
            # O Distrobox monta a raiz do hospedeiro neste caminho.
            target=/run/host$source_path
        fi

        existing_target=''
        if [[ -L $destination ]]; then
            existing_target=$(readlink -- "$destination")
        fi
        if [[ -d $destination || $existing_target == "$target" || ( ! -e $destination && ! -L $destination ) ]]; then
            legacy_settings+=("$(xdg_user_dir_setting "$key" "$name")")
        fi

        if [[ ${mapped_targets[$name]:-$target} != "$target" ||
              ( -L $destination && $existing_target != "$target" ) ||
              ( -e $destination && ! -L $destination && ! -d $destination ) ]]; then
            # Use o nome padrão do tipo XDG e procure um caminho livre ou já vinculado ao alvo.
            base=${entry#*:}
            name=$base
            destination=$private_home/$name
            count=2
            while [[ -e $destination || -L $destination ]]; do
                if [[ -L $destination && $(readlink -- "$destination") == "$target" ]]; then
                    break
                fi
                name=$base-$count
                destination=$private_home/$name
                ((++count))
            done
        fi

        if [[ ! -e $destination && ! -L $destination ]]; then
            ln -sT -- "$target" "$destination"
        fi
        mapped_targets[$name]=$target
        xdg_settings+=("$(xdg_user_dir_setting "$key" "$name")")
    done

    if ((${#xdg_settings[@]})); then
        write_user_dirs_config "$private_home/.config" "$(printf '%s\n' "${legacy_settings[@]}")" "${xdg_settings[@]}"
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
