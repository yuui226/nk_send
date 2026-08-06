#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE='/opt/ztransfer-cert-renew'
ACME="$BASE/acme/acme.sh"
ACME_HOME="$BASE/acme"
CONFIG_HOME="$BASE/acme-config"
CERT_HOME="$BASE/acme-certs"
DOMAIN='apk.ztransfer.top'
CANDIDATE="$BASE/candidate"
DEPLOY="$BASE/deploy-oss.sh"

mkdir -p "$CONFIG_HOME" "$CERT_HOME" "$CANDIDATE"
chmod 700 "$BASE" "$CONFIG_HOME" "$CERT_HOME" "$CANDIDATE"

exec 9>"$BASE/renew.lock"
flock -n 9 || {
  echo '已有证书续期任务正在运行，跳过'
  exit 0
}

/opt/node/bin/node "$BASE/sync-ossutil-config.js" >/dev/null

common=(
  --home "$ACME_HOME"
  --config-home "$CONFIG_HOME"
  --cert-home "$CERT_HOME"
  --server letsencrypt
)

if [ ! -s "$CERT_HOME/$DOMAIN/$DOMAIN.conf" ]; then
  echo '首次申请证书...'
  "$ACME" "${common[@]}" --issue \
    --dns dns_ali_cli \
    --dnssleep 60 \
    --keylength 2048 \
    -d "$DOMAIN"

  touch "$CANDIDATE/fullchain.pem" "$CANDIDATE/private.key"
  chmod 600 "$CANDIDATE/fullchain.pem" "$CANDIDATE/private.key"
  "$ACME" "${common[@]}" --install-cert -d "$DOMAIN" \
    --key-file "$CANDIDATE/private.key" \
    --fullchain-file "$CANDIDATE/fullchain.pem" \
    --reloadcmd "$DEPLOY"
else
  echo '检查证书续期窗口...'
  cron_status=0
  "$ACME" "${common[@]}" --cron || cron_status=$?

  # 若 CA 已签发并写入 candidate，但 OSS 部署曾失败，后续定时检查必须重试部署，
  # 不能因为尚未进入下一个续期窗口而将候选证书闲置。
  if [ -s "$CANDIDATE/fullchain.pem" ] && [ -s "$CANDIDATE/private.key" ]; then
    candidate_fp="$(openssl x509 -in "$CANDIDATE/fullchain.pem" -noout -fingerprint -sha256 \
      | cut -d= -f2 | tr -d ':\r\n' | tr '[:lower:]' '[:upper:]')"
    deployed_fp=''
    if [ -s "$BASE/deployed/fullchain.pem" ]; then
      deployed_fp="$(openssl x509 -in "$BASE/deployed/fullchain.pem" -noout -fingerprint -sha256 \
        | cut -d= -f2 | tr -d ':\r\n' | tr '[:lower:]' '[:upper:]')"
    fi
    if [ "$candidate_fp" != "$deployed_fp" ]; then
      echo '发现尚未成功部署的候选证书，重新部署到 OSS...'
      "$DEPLOY"
      cron_status=0
    fi
  fi

  exit "$cron_status"
fi
