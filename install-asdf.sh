#!/usr/bin/env bash
set -euo pipefail

version=0.20.2
target=/usr/local/bin/asdf

# SHA-256 dos arquivos publicados em github.com/asdf-vm/asdf/releases/tag/v0.20.2.
architecture=$(uname -m)
case $architecture in
    x86_64)
        archive_arch=amd64
        checksum=6d45e6fab12f50a259b5643adf06a2e77af30a87300b4402440eda09af467a6d
        ;;
    aarch64|arm64)
        archive_arch=arm64
        checksum=356e135a608bdfba34038c1f18c4b82434d7b6d546e30dbf372c61baaa2f442c
        ;;
    *)
        printf 'A versão %s do asdf não está configurada para a arquitetura %s.\n' "$version" "$architecture" >&2
        exit 1
        ;;
esac

if [[ -x $target ]]; then
    installed_version=$("$target" version 2>/dev/null) || installed_version=''
    if [[ $installed_version == "$version" || $installed_version == "$version "* ]]; then
        printf 'asdf %s já está instalado no contêiner.\n' "$version"
        exit 0
    fi
fi

printf 'Instalando o asdf %s (%s).\n' "$version" "$archive_arch"
mkdir -p -- "${target%/*}"
temporary_dir=$(mktemp -d "${target%/*}/.asdf.XXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT
archive=asdf-v$version-linux-$archive_arch.tar.gz
curl --fail --location --silent --show-error --retry 2 \
    "https://github.com/asdf-vm/asdf/releases/download/v$version/$archive" --output "$temporary_dir/$archive"
printf '%s  %s\n' "$checksum" "$temporary_dir/$archive" | sha256sum --check --status || {
    printf 'O arquivo do asdf não corresponde ao SHA-256 da versão %s.\n' "$version" >&2
    exit 1
}
tar -xzf "$temporary_dir/$archive" -C "$temporary_dir"
chmod 0755 -- "$temporary_dir/asdf"
mv -fT -- "$temporary_dir/asdf" "$target"
