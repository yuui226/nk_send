#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE='/opt/ztransfer-cert-renew'
OSSUTIL="$BASE/bin/ossutil"
OSS_CONFIG="$BASE/ossutil.conf"
SYNC_CONFIG="$BASE/sync-ossutil-config.js"
CANDIDATE_DIR="$BASE/candidate"
DEPLOYED_DIR="$BASE/deployed"
WORK_DIR="$BASE/work"
BUCKET='ztransfer-hk'
DOMAIN='apk.ztransfer.top'
TEST_URL='https://apk.ztransfer.top/'

mkdir -p "$CANDIDATE_DIR" "$DEPLOYED_DIR" "$WORK_DIR"
chmod 700 "$BASE" "$CANDIDATE_DIR" "$DEPLOYED_DIR" "$WORK_DIR"

candidate_cert="$CANDIDATE_DIR/fullchain.pem"
candidate_key="$CANDIDATE_DIR/private.key"

fail() {
  echo "证书部署失败: $*" >&2
  exit 1
}

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 \
    | cut -d= -f2 | tr -d ':\r\n' | tr '[:lower:]' '[:upper:]'
}

fingerprint_sha1() {
  openssl x509 -in "$1" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':\r\n' | tr '[:lower:]' '[:upper:]'
}

validate_pair() {
  local cert=$1 key=$2 cert_pub key_pub
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null \
    || fail '候选证书无效或即将到期'
  openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null \
    || fail '候选证书不包含目标域名'
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null \
    | sha256sum | cut -d' ' -f1)"
  [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] \
    || fail '证书与私钥不匹配'
}

put_certificate() {
  local cert=$1 key=$2 xml=$3
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<BucketCnameConfiguration><Cname>'
    printf '<Domain>%s</Domain>\n' "$DOMAIN"
    printf '%s\n' '<CertificateConfiguration><Certificate>'
    cat "$cert"
    printf '%s\n' '</Certificate><PrivateKey>'
    cat "$key"
    printf '%s\n' '</PrivateKey><Force>true</Force></CertificateConfiguration>'
    printf '%s\n' '</Cname></BucketCnameConfiguration>'
  } >"$xml"
  chmod 600 "$xml"

  "$OSSUTIL" --config-file "$OSS_CONFIG" api put-cname \
    --bucket "$BUCKET" \
    --cname-configuration "file://$xml" \
    --output-format json >/dev/null
}

control_plane_matches() {
  local expected=$1
  "$OSSUTIL" --config-file "$OSS_CONFIG" api list-cname \
    --bucket "$BUCKET" --output-format json 2>/dev/null \
    | /opt/node/bin/node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  try {
    const result = JSON.parse(input);
    const certificate = result.Cname && result.Cname.Certificate;
    const actual = String(certificate && certificate.Fingerprint || "")
      .replace(/:/g, "").toUpperCase();
    process.exit(certificate && certificate.Status === "Enabled" && actual === process.argv[1] ? 0 : 1);
  } catch (_) {
    process.exit(1);
  }
});
' "$expected"
}

wait_until_live() {
  local expected_sha256=$1 expected_sha1=$2 attempt live
  # OSS 边缘节点会逐步同步证书；控制面指纹一致且公网实际命中新证书后，
  # 才确认本次部署成功。无需等待仍持有有效旧证书的每个边缘节点同步完毕。
  for attempt in $(seq 1 60); do
    live="$(timeout 15 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
      | cut -d= -f2 | tr -d ':\r\n' | tr '[:lower:]' '[:upper:]' || true)"
    if control_plane_matches "$expected_sha1" \
      && [ -n "$live" ] && [ "$live" = "$expected_sha256" ] \
      && curl -sSI --max-time 20 "$TEST_URL" >/dev/null; then
      return 0
    fi
    sleep 10
  done
  return 1
}

[ -x "$OSSUTIL" ] || fail '找不到 ossutil'
[ -s "$candidate_cert" ] || fail '找不到候选证书'
[ -s "$candidate_key" ] || fail '找不到候选私钥'
validate_pair "$candidate_cert" "$candidate_key"
/opt/node/bin/node "$SYNC_CONFIG" >/dev/null

candidate_fp="$(fingerprint "$candidate_cert")"
candidate_sha1="$(fingerprint_sha1 "$candidate_cert")"
candidate_xml="$WORK_DIR/candidate.xml"
trap 'rm -f "$WORK_DIR/candidate.xml" "$WORK_DIR/rollback.xml"' EXIT

echo '正在更新 OSS 自定义域名证书...'
put_certificate "$candidate_cert" "$candidate_key" "$candidate_xml"

if ! wait_until_live "$candidate_fp" "$candidate_sha1"; then
  if [ -s "$DEPLOYED_DIR/fullchain.pem" ] && [ -s "$DEPLOYED_DIR/private.key" ]; then
    echo '新证书上线验证失败，正在恢复上一张已验证证书...' >&2
    rollback_xml="$WORK_DIR/rollback.xml"
    put_certificate "$DEPLOYED_DIR/fullchain.pem" "$DEPLOYED_DIR/private.key" "$rollback_xml" || true
  fi
  fail 'OSS 更新后未在规定时间内通过 HTTPS 验证'
fi

install -m 600 "$candidate_cert" "$DEPLOYED_DIR/fullchain.pem.new"
install -m 600 "$candidate_key" "$DEPLOYED_DIR/private.key.new"
mv -f "$DEPLOYED_DIR/fullchain.pem.new" "$DEPLOYED_DIR/fullchain.pem"
mv -f "$DEPLOYED_DIR/private.key.new" "$DEPLOYED_DIR/private.key"
echo "OSS 证书已生效，SHA-256 指纹: $candidate_fp"
