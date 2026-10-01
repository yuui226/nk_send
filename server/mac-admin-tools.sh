#!/bin/bash
# Private, pinned runtimes; stdout contains only the executable path.
# Sources: https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6
# https://help.aliyun.com/zh/oss/developer-reference/ossutil-2-0-historical-iteration-version
set -euo pipefail
umask 077
[[ "$(/usr/bin/uname -s)" == Darwin ]] || { echo '此工具仅支持 macOS。' >&2; exit 1; }
arch="$(/usr/bin/uname -m)"
cache="$HOME/Library/Caches/ZTransfer/admin-tools"
case "${1:-}" in
    pwsh)
        existing="$(command -v pwsh || true)"
        if [[ -n "$existing" ]] && "$existing" -NoLogo -NoProfile -Command 'if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }' >/dev/null 2>&1; then
            printf '%s\n' "$existing"; exit 0
        fi
        case "$arch" in
            arm64) target_arch=arm64; sha=6df833d094ebac1c1a74340d7b3437f4aaf5e03ce640484a1c4359f3ce8b3db1 ;;
            x86_64) target_arch=x64; sha=e325ed9f666894eb39a5ea52800b602da2fb4242bbe9747ceddb39cdc66de805 ;;
            *) echo "不支持的 Mac 架构: $arch" >&2; exit 1 ;;
        esac
        tool_dir="$cache/powershell-7.6.6-$target_arch"
        relative_executable=pwsh
        url="https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-osx-$target_arch.tar.gz"
        archive_type=tar
        ;;
    ossutil)
        case "$arch" in
            arm64) target_arch=arm64; sha=058fd048f321f8c80def8b748030531646eefe3a82837bf16b581ba7d9c84ac7 ;;
            x86_64) target_arch=amd64; sha=8437fdd3ef1a3eb12310f61fcf1c00a5bff5cdab47b4fea815527472e7cf896c ;;
            *) echo "不支持的 Mac 架构: $arch" >&2; exit 1 ;;
        esac
        tool_dir="$cache/ossutil-2.3.0-$target_arch"
        relative_executable="ossutil-2.3.0-mac-$target_arch/ossutil"
        url="https://gosspublic.alicdn.com/ossutil/v2/2.3.0/ossutil-2.3.0-mac-$target_arch.zip"
        archive_type=zip
        ;;
    *) echo '用法: mac-admin-tools.sh pwsh|ossutil' >&2; exit 2 ;;
esac
if [[ -x "$tool_dir/$relative_executable" ]]; then
    printf '%s\n' "$tool_dir/$relative_executable"; exit 0
fi
mkdir -p "$cache"
staging="$(mktemp -d "$cache/.download.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "首次准备 $1（只需下载一次，完成后自动继续）…" >&2
/usr/bin/curl -fL --progress-bar --retry 2 --connect-timeout 20 --max-time 900 -o "$staging/archive" "$url"
actual_sha="$(/usr/bin/shasum -a 256 "$staging/archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha" == "$sha" ]] || { echo '下载文件校验失败，未安装。请重新运行。' >&2; exit 1; }
mkdir "$staging/unpacked"
if [[ "$archive_type" == tar ]]; then
    /usr/bin/tar -xzf "$staging/archive" -C "$staging/unpacked"
else
    /usr/bin/ditto -x -k "$staging/archive" "$staging/unpacked"
fi
chmod u+x "$staging/unpacked/$relative_executable"
# Do not replace an installation another terminal completed during this download.
if [[ ! -x "$tool_dir/$relative_executable" ]]; then
    if [[ -e "$tool_dir" ]]; then
        echo "工具目录不完整，请移走后重试: $tool_dir" >&2; exit 1
    fi
    mv "$staging/unpacked" "$tool_dir"
fi
printf '%s\n' "$tool_dir/$relative_executable"
