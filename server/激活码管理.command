#!/bin/bash
# Finder 双击入口；菜单与 Windows 共用 admin.ps1。
set -euo pipefail
umask 077
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LANG="${LANG:-zh_CN.UTF-8}"

finish() {
    result=$?
    if [[ "$result" -ne 0 && -t 0 ]]; then
        echo
        echo "运行失败（退出码 $result），请查看上方错误。"
        read -r -p '按回车关闭窗口…' || true
    fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Finder 启动不加载 shell 配置；补齐 APK 签名校验需要的 Java 环境。
if [[ -z "${JAVA_HOME:-}" ]]; then
    for java_dir in /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home; do
        if [[ -x "$java_dir/bin/java" ]]; then export JAVA_HOME="$java_dir"; break; fi
    done
    if [[ -z "${JAVA_HOME:-}" ]]; then
        java_dir="$(/usr/libexec/java_home 2>/dev/null || true)"
        if [[ -n "$java_dir" ]]; then export JAVA_HOME="$java_dir"; fi
    fi
fi
pwsh_path="$(/bin/bash "$script_dir/mac-admin-tools.sh" pwsh)"
"$pwsh_path" -NoLogo -NoProfile -File "$script_dir/admin.ps1" "$@"
