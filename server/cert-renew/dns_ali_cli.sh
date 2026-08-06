#!/usr/bin/env sh

dns_ali_cli_info='AliDNS through the preconfigured Alibaba Cloud CLI profile'

ZT_ALIYUN_BIN="${ZT_ALIYUN_BIN:-/usr/local/bin/aliyun}"
ZT_ALIYUN_PROFILE="${ZT_ALIYUN_PROFILE:-ztransfer-}"
ZT_DNS_DOMAIN='ztransfer.top'
ZT_DNS_FQDN='_acme-challenge.apk.ztransfer.top'
ZT_DNS_RR='_acme-challenge.apk'
ZT_NODE_BIN="${ZT_NODE_BIN:-/opt/node/bin/node}"

dns_ali_cli_add() {
  fulldomain=$1
  txtvalue=$2

  if [ "$fulldomain" != "$ZT_DNS_FQDN" ]; then
    _err "拒绝修改非目标 DNS 记录: $fulldomain"
    return 1
  fi

  response="$($ZT_ALIYUN_BIN alidns AddDomainRecord \
    --profile "$ZT_ALIYUN_PROFILE" \
    --DomainName "$ZT_DNS_DOMAIN" \
    --RR "$ZT_DNS_RR" \
    --Type TXT \
    --Value "$txtvalue" \
    --TTL 600 2>&1)" || {
      _err "添加 AliDNS 验证记录失败: $response"
      return 1
    }

  record_id="$(printf '%s' "$response" | "$ZT_NODE_BIN" -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try { process.stdout.write(String(JSON.parse(input).RecordId || "")); }
      catch (_) { process.exitCode = 1; }
    });
  ')" || return 1

  if [ -z "$record_id" ]; then
    _err "AliDNS 未返回 RecordId"
    return 1
  fi
  _info "AliDNS 验证记录已创建"
}

dns_ali_cli_rm() {
  fulldomain=$1
  txtvalue=$2

  if [ "$fulldomain" != "$ZT_DNS_FQDN" ]; then
    _err "拒绝删除非目标 DNS 记录: $fulldomain"
    return 1
  fi

  response="$($ZT_ALIYUN_BIN alidns DescribeSubDomainRecords \
    --profile "$ZT_ALIYUN_PROFILE" \
    --SubDomain "$ZT_DNS_FQDN" \
    --DomainName "$ZT_DNS_DOMAIN" \
    --Type TXT \
    --PageSize 100 2>&1)" || {
      _err "查询 AliDNS 验证记录失败: $response"
      return 1
    }

  record_ids="$(ZT_EXPECTED_TXT="$txtvalue" "$ZT_NODE_BIN" -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try {
        const records = JSON.parse(input)?.DomainRecords?.Record || [];
        const ids = records
          .filter(item => item && item.Type === "TXT" && item.Value === process.env.ZT_EXPECTED_TXT)
          .map(item => String(item.RecordId || ""))
          .filter(Boolean);
        process.stdout.write(ids.join("\n"));
      } catch (_) { process.exitCode = 1; }
    });
  ' <<EOF
$response
EOF
  )" || return 1

  if [ -z "$record_ids" ]; then
    _info "AliDNS 验证记录已不存在"
    return 0
  fi

  for record_id in $record_ids; do
    delete_response="$($ZT_ALIYUN_BIN alidns DeleteDomainRecord \
      --profile "$ZT_ALIYUN_PROFILE" \
      --RecordId "$record_id" 2>&1)" || {
        _err "删除 AliDNS 验证记录失败: $delete_response"
        return 1
      }
  done
  _info "AliDNS 验证记录已清理"
}
