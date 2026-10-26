# ============================================================
#                 REALITY 目标网站 (SNI) 自动优选
# ============================================================
# 规则：与 VPS 同国家/地区（最好同城/同 ASN）；TLS1.3 + X25519 + ALPN h2 + HSTS；
#       证书链有效；不在 CDN / WAF 后面（Cloudflare、Imperva、Fastly、Akamai、CloudFront、Azure Front Door 等）；
#       不是被墙网站/大厂默认域名。支持 X25519MLKEM768（后量子）的目标优先，但不是硬性要求。
# 候选列表按地区组织（以大学及本地中型网站为主），运行时在 VPS 上逐一实测。
# v1.1.1：已剔除响应头显示使用 CDN/WAF 的候选；SG / PH 本地自建站点很少，合格数不足时自动扩大到邻近地区。
sni_candidates() { # $1 = 地区键
  case $1 in
    US-CA)  echo "www.csun.edu www.cpp.edu www.uci.edu www.ucsd.edu www.stanford.edu www.sjsu.edu www.chapman.edu www.lmu.edu" ;;
    US-NW)  echo "www.washington.edu www.uw.edu www.wsu.edu www.unr.edu www.utah.edu" ;;
    US-SW)  echo "www.nau.edu www.unm.edu www.utah.edu www.colorado.edu" ;;
    US-TX)  echo "www.uh.edu www.smu.edu www.tcu.edu www.utdallas.edu www.unt.edu www.utsa.edu www.ou.edu" ;;
    US-OH)  echo "www.miamioh.edu www.bgsu.edu www.utoledo.edu www.wayne.edu www.purdue.edu www.iu.edu www.pitt.edu www.cmu.edu www.louisville.edu" ;;
    US-IL)  echo "www.uchicago.edu www.northwestern.edu www.uic.edu www.depaul.edu www.slu.edu www.ku.edu www.unl.edu" ;;
    US-EAST) echo "www.virginia.edu www.vcu.edu www.jmu.edu www.udel.edu www.duke.edu" ;;
    US-NE)  echo "www.cornell.edu www.rutgers.edu www.rochester.edu www.temple.edu www.drexel.edu www.bu.edu www.northeastern.edu www.tufts.edu www.yale.edu" ;;
    US-SE)  echo "www.emory.edu www.ufl.edu www.miami.edu www.usf.edu www.fiu.edu www.sc.edu www.clemson.edu www.lsu.edu" ;;
    CA)     echo "www.yorku.ca www.torontomu.ca www.mcmaster.ca www.queensu.ca www.carleton.ca www.mcgill.ca www.concordia.ca www.umontreal.ca www.ulaval.ca www.sfu.ca www.uvic.ca www.ucalgary.ca www.umanitoba.ca www.usask.ca" ;;
    MX)     echo "www.tec.mx www.ipn.mx www.udg.mx www.uanl.mx www.ibero.mx" ;;
    BR)     echo "www.usp.br www.ufrj.br www.unesp.br www.ufmg.br www.puc-rio.br www.ufsc.br" ;;
    JP)     echo "www.u-tokyo.ac.jp www.osaka-u.ac.jp www.titech.ac.jp www.isct.ac.jp www.tohoku.ac.jp www.nagoya-u.ac.jp www.kyushu-u.ac.jp www.hokudai.ac.jp www.hit-u.ac.jp www.ritsumei.ac.jp www.kobe-u.ac.jp www.chiba-u.ac.jp www.ynu.ac.jp" ;;
    KR)     echo "www.snu.ac.kr www.kaist.ac.kr www.yonsei.ac.kr www.korea.ac.kr www.postech.ac.kr www.skku.edu www.hanyang.ac.kr www.kyunghee.ac.kr www.ewha.ac.kr www.sogang.ac.kr www.cau.ac.kr www.pusan.ac.kr www.unist.ac.kr" ;;
    HK)     echo "my.hkust.edu.hk factsfigures.cuhk.edu.hk dsbs.cuhk.edu.hk rmda.cuhk.edu.hk" ;; # 后两个 HSTS 仅 300s，放最后
    TW)     echo "www.ntu.edu.tw www.nthu.edu.tw www.ncku.edu.tw www.nccu.edu.tw www.ntnu.edu.tw www.ncu.edu.tw www.ntust.edu.tw www.fju.edu.tw www.tku.edu.tw" ;;
    SG)     echo "www.ntuc.org.sg www.uob.com.sg www.sgnog.org www.curtin.edu.sg" ;;
    MY)     echo "www.um.edu.my www.ukm.my www.upm.edu.my www.usm.my www.utm.my www.taylors.edu.my www.sunway.edu.my" ;;
    TH)     echo "www.mahidol.ac.th www.ku.ac.th www.tu.ac.th www.cmu.ac.th www.kmutt.ac.th" ;;
    VN)     echo "www.hust.edu.vn www.vnu.edu.vn www.hcmus.edu.vn www.ueh.edu.vn" ;;
    ID)     echo "www.ui.ac.id www.itb.ac.id www.ugm.ac.id www.binus.ac.id www.its.ac.id www.unair.ac.id" ;;
    PH)     echo "www.pup.edu.ph www.upd.edu.ph www.feu.edu.ph" ;;
    IN)     echo "www.iitb.ac.in www.iitd.ac.in www.iitm.ac.in www.iisc.ac.in www.iitk.ac.in www.du.ac.in www.jnu.ac.in www.bits-pilani.ac.in www.amity.edu" ;;
    AU)     echo "www.rmit.edu.au www.anu.edu.au www.uq.edu.au" ;;
    NZ)     echo "www.wgtn.ac.nz" ;;
    DE)     echo "www.tum.de www.lmu.de www.uni-heidelberg.de www.fu-berlin.de www.hu-berlin.de www.tu-berlin.de www.kit.edu www.rwth-aachen.de www.goethe-university-frankfurt.de www.tu-darmstadt.de www.uni-mainz.de www.uni-koeln.de www.uni-bonn.de www.uni-hamburg.de www.tu-dresden.de www.uni-muenster.de www.uni-goettingen.de" ;;
    NL)     echo "www.uva.nl www.vu.nl www.uu.nl www.universiteitleiden.nl www.rug.nl www.ru.nl www.utwente.nl www.eur.nl www.maastrichtuniversity.nl" ;;
    GB)     echo "www.imperial.ac.uk www.kcl.ac.uk www.lse.ac.uk www.gre.ac.uk www.gla.ac.uk www.leeds.ac.uk www.sheffield.ac.uk www.bristol.ac.uk www.birmingham.ac.uk www.nottingham.ac.uk www.warwick.ac.uk www.soton.ac.uk" ;;
    FR)     echo "www.u-paris.fr www.universite-paris-saclay.fr www.psl.eu www.ens.psl.eu www.polytechnique.edu www.sciencespo.fr www.univ-lyon1.fr www.univ-grenoble-alpes.fr www.unistra.fr www.univ-amu.fr www.u-bordeaux.fr www.univ-lille.fr www.univ-tlse3.fr www.insa-lyon.fr www.centralesupelec.fr" ;;
    IE)     echo "www.tudublin.ie www.ucc.ie" ;;
    BE)     echo "www.kuleuven.be www.uantwerpen.be www.ulb.be www.uclouvain.be www.vub.be www.uliege.be" ;;
    CH)     echo "www.ethz.ch www.uzh.ch www.unibe.ch www.unibas.ch www.unige.ch www.unil.ch www.zhaw.ch" ;;
    AT)     echo "www.univie.ac.at www.tuwien.at www.meduniwien.ac.at www.uibk.ac.at www.tugraz.at www.uni-graz.at www.jku.at" ;;
    IT)     echo "www.polimi.it www.uniroma1.it www.unibo.it www.polito.it www.unina.it" ;;
    ES)     echo "www.uam.es www.ucm.es www.upm.es www.uc3m.es www.ub.edu www.uab.cat www.upc.edu www.uv.es www.us.es" ;;
    PL)     echo "www.uw.edu.pl www.pw.edu.pl www.uj.edu.pl www.agh.edu.pl www.put.poznan.pl www.pwr.edu.pl www.umk.pl" ;;
    SE)     echo "www.kth.se www.su.se www.ki.se www.uu.se www.lu.se www.gu.se www.liu.se" ;;
    FI)     echo "www.tuni.fi www.utu.fi www.oulu.fi www.jyu.fi" ;;
    NO)     echo "www.uio.no www.ntnu.no www.uib.no www.oslomet.no www.uit.no" ;;
    DK)     echo "www.dtu.dk www.sdu.dk www.aau.dk www.cbs.dk" ;;
    CZ)     echo "www.cuni.cz www.cvut.cz www.muni.cz www.vutbr.cz www.vse.cz" ;;
    RU)     echo "www.msu.ru www.hse.ru www.spbu.ru www.itmo.ru www.mipt.ru www.bmstu.ru" ;;
    TR)     echo "www.boun.edu.tr www.metu.edu.tr www.itu.edu.tr www.bilkent.edu.tr www.sabanciuniv.edu" ;;
    AE)     echo "www.uaeu.ac.ae www.ku.ac.ae www.zu.ac.ae www.hct.ac.ae" ;;
    IL)     echo "www.tau.ac.il www.huji.ac.il www.technion.ac.il www.weizmann.ac.il www.bgu.ac.il" ;;
    ZA)     echo "www.wits.ac.za www.sun.ac.za" ;;
    *)      echo "" ;;
  esac
}

# 根据 VPS 位置返回地区键（主）与同国家其它地区键（次）
sni_region_keys() {
  local cc=$GEO_CC region=${GEO_REGION,,}
  if [[ $cc == US ]]; then
    local main
    case $region in
      california) main=US-CA ;;
      washington|oregon|idaho|nevada|montana|alaska) main=US-NW ;;
      arizona|"new mexico"|utah|colorado|wyoming) main=US-SW ;;
      texas|oklahoma|arkansas) main=US-TX ;;
      ohio|michigan|indiana|kentucky|pennsylvania|"west virginia") main=US-OH ;;
      illinois|wisconsin|minnesota|missouri|iowa|kansas|nebraska|"north dakota"|"south dakota") main=US-IL ;;
      virginia|"district of columbia"|maryland|delaware|"north carolina") main=US-EAST ;;
      "new york"|"new jersey"|massachusetts|connecticut|"rhode island"|vermont|"new hampshire"|maine) main=US-NE ;;
      georgia|florida|"south carolina"|alabama|tennessee|mississippi|louisiana) main=US-SE ;;
      *) main=US-EAST ;;
    esac
    local k others=""
    for k in US-CA US-NW US-SW US-TX US-OH US-IL US-EAST US-NE US-SE; do [[ $k == "$main" ]] || others+="$k "; done
    echo "$main|$others"
    return
  fi
  case $cc in
    UK) cc=GB ;;
    MO) cc=HK ;;
  esac
  if [[ -n $cc && -n $(sni_candidates "$cc") ]]; then
    # 邻近地区作为次选
    local near=""
    case $cc in
      JP) near="KR TW" ;; KR) near="JP" ;; HK) near="TW SG" ;; TW) near="HK JP" ;; SG) near="MY HK" ;;
      MY) near="SG" ;; TH|VN|ID|PH) near="SG" ;; IN) near="SG" ;; AU) near="NZ" ;; NZ) near="AU" ;;
      DE) near="NL AT CH" ;; NL) near="DE BE" ;; BE) near="NL FR" ;; FR) near="BE DE" ;; GB) near="IE NL" ;; IE) near="GB" ;;
      CH|AT) near="DE" ;; IT) near="CH" ;; ES) near="FR" ;; PL|CZ) near="DE" ;; SE|FI|NO|DK) near="SE FI NO DK" ;;
      CA) near="US-NE US-NW" ;; MX) near="US-TX" ;; BR) near="" ;; RU) near="FI" ;; TR) near="DE" ;;
      AE|IL|ZA) near="" ;;
    esac
    echo "$cc|$near"
  else
    echo "|US-EAST US-CA JP SG HK DE GB NL"
  fi
}

# 大厂/被墙/CDN 默认域名黑名单（按域名标签精确匹配）
SNI_BLACK_LABELS=" google googleapis gstatic googlevideo youtube ytimg gmail blogspot yahoo apple icloud mzstatic microsoft msn bing live office office365 microsoftonline azure azureedge windowsupdate xbox skype amazon amazonaws cloudfront cloudflare workers facebook fbcdn instagram whatsapp twitter twimg telegram github githubusercontent netflix nflxvideo akamai akamaized akamaihd edgekey fastly wikipedia wikimedia openai chatgpt discord tiktok bytedance speedtest paypal dropbox reddit pinterest linkedin tesla nvidia samsung "
SNI_BLACK_DOMAINS=" x.com t.co vercel.app vercel.com vercel-infra.com netlify.app herokuapp.com pages.dev workers.dev "
sni_blacklisted() {
  local h=${1,,} l
  h=${h%.}
  [[ $SNI_BLACK_DOMAINS == *" $h "* ]] && return 0
  local d
  for d in $SNI_BLACK_DOMAINS; do [[ $h == *".$d" ]] && return 0; done
  local IFS=.
  for l in $h; do [[ $SNI_BLACK_LABELS == *" $l "* ]] && return 0; done
  [[ $h == *.cn ]] && return 0
  return 1
}

CF_V4_DEFAULT="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6_DEFAULT="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
CF_V4="" CF_V6=""
load_cf_ranges() {
  [[ -n $CF_V4 ]] && return 0
  local v4 v6
  v4=$(curl -fsS --connect-timeout 5 -m 8 https://www.cloudflare.com/ips-v4 2>/dev/null | tr -d '\r' | grep -E '^[0-9.]+/[0-9]+$' | tr '\n' ' ') || true
  v6=$(curl -fsS --connect-timeout 5 -m 8 https://www.cloudflare.com/ips-v6 2>/dev/null | tr -d '\r' | grep -E '^[0-9a-fA-F:]+/[0-9]+$' | tr '\n' ' ') || true
  CF_V4=${v4:-$CF_V4_DEFAULT} CF_V6=${v6:-$CF_V6_DEFAULT}
}
ip4_to_int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
in_cf_v4() {
  local ip=$1 n cidr net bits mask
  n=$(ip4_to_int "$ip")
  for cidr in $CF_V4; do
    net=${cidr%/*} bits=${cidr#*/}
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (n & mask) == ($(ip4_to_int "$net") & mask) )) && return 0
  done
  return 1
}
ip6_prefix32() { # 返回 IPv6 前 32 位整数
  local a=${1,,} head g1 g2
  head=${a%%::*}
  IFS=: read -r g1 g2 _ <<<"$head"
  [[ $a == *::* && $head != *:* ]] && g2=0
  echo $(( (16#${g1:-0} << 16) | 16#${g2:-0} ))
}
in_cf_v6() {
  local n cidr bits mask
  n=$(ip6_prefix32 "$1")
  for cidr in $CF_V6; do
    bits=${cidr#*/}; (( bits > 32 )) && bits=32
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (n & mask) == ($(ip6_prefix32 "${cidr%/*}") & mask) )) && return 0
  done
  return 1
}

# 根据响应头识别 CDN / WAF（$1 = curl -D 保存的响应头文件，可含多次跳转）。
# 命中时输出 CDN 名称并返回 0。只用 tr + grep -iE，兼容 busybox（Alpine / NAT 模式）。
SNI_CDN_RULES=(
  'Cloudflare|^(server:[[:space:]]*cloudflare|cf-ray:|cf-cache-status:|cf-mitigated:)'
  'Imperva/Incapsula|^(x-iinfo:|x-cdn:[[:space:]]*(imperva|incapsula)|set-cookie:.*(incap_ses|visid_incap))'
  'Fastly|^(x-served-by:.*cache-|x-fastly-|fastly-|via:.*varnish)'
  'Akamai|^(server:[[:space:]]*akamai|x-akamai-|akamai-)'
  'CloudFront|^(via:.*cloudfront|x-amz-cf-|x-cache:.*cloudfront)'
  'Azure Front Door|^(x-azure-ref|x-msedge-ref)'
  'Sucuri|^(server:[[:space:]]*sucuri|x-sucuri-)'
  'BunnyCDN|^(server:[[:space:]]*bunnycdn|cdn-pullzone:)'
)
sni_cdn_detect() { # $1 响应头文件
  [[ -s $1 ]] || return 1
  local h rule
  h=$(tr -d '\r' <"$1" 2>/dev/null) || return 1
  for rule in "${SNI_CDN_RULES[@]}"; do
    if printf '%s\n' "$h" | grep -qiE "${rule#*|}"; then echo "${rule%%|*}"; return 0; fi
  done
  return 1
}

# 目标是否支持后量子密钥交换 X25519MLKEM768（新版 Xray 客户端的 uTLS 指纹默认携带）。
# 这是「优先」条件而非硬性要求：支持的目标排在前面；不支持的目标只给出警告，仍可使用。
# 用已安装的 xray 自带的 `xray tls ping` 检测；返回 0=支持 1=明确不支持 2=无法判断（xray 未安装/网络失败）
# 同时记录证书链总长度到全局 SNI_CHAIN_LEN（ML-DSA-65 需要 ≥ 3500 字节，见 mldsa_decide）。
SNI_CHAIN_LEN=""
sni_pq_check() { # $1 域名 [$2 IP]
  SNI_CHAIN_LEN=""
  [[ -x $XRAY_BIN ]] || return 2
  local out pq
  out=$(timeout 12 "$XRAY_BIN" tls ping ${2:+-ip "$2"} "$1" 2>&1) || true
  SNI_CHAIN_LEN=$(awk '/Pinging with SNI/{f=1} f && /total length:/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' <<<"$out")
  pq=$(awk '/Pinging with SNI/{f=1} f && /Post-Quantum key exchange:/{print; exit}' <<<"$out")
  [[ -n $pq ]] || return 2
  [[ $pq == *true* ]] && return 0
  return 1
}

# ML-DSA-65 (pqv) 要求目标证书链总长度 ≥ 3500 字节，否则服务端 REALITY 握手失败（所有客户端都连不上，
# 与客户端是否填写 pqv 无关）。按当前 SNI 决定是否启用：不满足时仅对该目标关闭 pqv，REALITY 本身照常。
MLDSA_MIN_CHAIN=3500
mldsa_decide() {
  MLDSA_ON=1
  [[ -n $MLDSA_SEED && -n $SNI ]] || return 0
  sni_pq_check "$SNI" || true
  if [[ $SNI_CHAIN_LEN =~ ^[0-9]+$ ]] && (( SNI_CHAIN_LEN < MLDSA_MIN_CHAIN )); then
    MLDSA_ON=0
    warn "目标 ${SNI} 证书链总长度 ${SNI_CHAIN_LEN} 字节 < ${MLDSA_MIN_CHAIN}，无法使用 ML-DSA-65 后量子签名，已对该目标关闭 pqv（REALITY 本身不受影响）。"
  fi
  return 0
}
# 当前是否在链接 / 配置中使用 pqv
pqv_active() { [[ -n $MLDSA_VERIFY && -n $MLDSA_SEED && ${MLDSA_ON:-1} != 0 ]]; }

# 探测单个候选域名。输出一行:
#   PASS|域名|TCP延迟ms|TLS握手完成ms|IP|国家|城市|ASN|PQ|证书链长度
#   （PQ: Y=支持 X25519MLKEM768 N=不支持 ?=无法判断；证书链长度 ≥ 3500 才能启用 ML-DSA-65 pqv，?=无法判断）
#   FAIL|域名|原因
sni_probe() {
  local host=${1,,} ip4s ip6s ip first out hdr w ver tconn tapp code best=999999 tls_ms geo cc="" city="" org=""
  host=${host%.}
  [[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "FAIL|$host|域名格式无效"; return; }
  if sni_blacklisted "$host"; then echo "FAIL|$host|大厂/被墙/CDN/国内域名（黑名单）"; return; fi
  ip4s=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u) || true
  ip6s=$(getent ahostsv6 "$host" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1}' | sort -u) || true
  if (( IPFAM == 6 )); then
    [[ -n $ip6s ]] || { echo "FAIL|$host|无 IPv6 解析（IPv6-only 机器需目标支持 IPv6 或配置 DNS64）"; return; }
  else
    [[ -n $ip4s ]] || { echo "FAIL|$host|无 IPv4 解析"; return; }
  fi
  for ip in $ip4s; do in_cf_v4 "$ip" && { echo "FAIL|$host|解析到 Cloudflare IP ($ip)"; return; }; done
  for ip in $ip6s; do in_cf_v6 "$ip" && { echo "FAIL|$host|解析到 Cloudflare IPv6 ($ip)"; return; }; done
  local conn
  if (( IPFAM == 6 )); then first=$(head -n1 <<<"$ip6s"); conn="[${first}]:443"
  else first=$(head -n1 <<<"$ip4s"); conn="${first}:443"; fi

  out=$(timeout 12 openssl s_client -connect "$conn" -servername "$host" -tls1_3 -groups X25519 -alpn h2 \
        -verify_return_error -verify_hostname "$host" </dev/null 2>&1) || true
  grep -q 'TLSv1.3' <<<"$out" || { echo "FAIL|$host|不支持 TLS1.3 / X25519"; return; }
  grep -q 'ALPN protocol: h2' <<<"$out" || { echo "FAIL|$host|不支持 ALPN h2"; return; }
  grep -q 'Verify return code: 0 (ok)' <<<"$out" || { echo "FAIL|$host|证书链/域名校验失败"; return; }

  hdr=$(mktemp)
  w=$(curl "-${IPFAM}" -sS -o /dev/null -D "$hdr" --http2 -L --max-redirs 3 --connect-timeout 5 -m 15 -A "$UA" \
        -w '%{http_version} %{time_connect} %{time_appconnect} %{http_code}' "https://${host}/" 2>/dev/null) || true
  read -r ver tconn tapp code <<<"$w"
  if [[ -z $code || $code == 000 ]]; then rm -f "$hdr"; echo "FAIL|$host|HTTPS 请求失败"; return; fi
  local cdn=""
  cdn=$(sni_cdn_detect "$hdr") || cdn=""
  if [[ -n $cdn ]]; then rm -f "$hdr"; echo "FAIL|$host|响应头显示使用 CDN/WAF（${cdn}）"; return; fi
  if ! grep -qi '^strict-transport-security:' "$hdr"; then rm -f "$hdr"; echo "FAIL|$host|无 HSTS 响应头"; return; fi
  rm -f "$hdr"
  [[ $ver == 2 ]] || { echo "FAIL|$host|HTTP/2 协商失败 (HTTP/$ver)"; return; }

  # 后量子 X25519MLKEM768：仅作排序偏好，不再因此淘汰
  local pqrc=0 pq="?"
  sni_pq_check "$host" "$first" || pqrc=$?
  case $pqrc in 0) pq=Y ;; 1) pq=N ;; esac

  # 延迟：TCP 建连 (≈1 RTT) 与 TLS 握手完成时间，各取 3 次中的最小值
  local i best_tls=999999 t_ms a_ms
  for i in 0 1 2; do
    if (( i > 0 )); then
      w=$(curl "-${IPFAM}" -sS -o /dev/null -I --http2 --connect-timeout 5 -m 8 -A "$UA" -w '%{time_connect} %{time_appconnect}' "https://${host}/" 2>/dev/null) || true
      read -r tconn tapp <<<"$w"
    fi
    t_ms=$(awk -v t="${tconn:-0}" 'BEGIN{printf "%d", t*1000}')
    a_ms=$(awk -v t="${tapp:-0}" 'BEGIN{printf "%d", t*1000}')
    (( t_ms > 0 && t_ms < best )) && best=$t_ms
    (( a_ms > 0 && a_ms < best_tls )) && best_tls=$a_ms
  done
  (( best == 999999 )) && best=0
  (( best_tls == 999999 )) && best_tls=9999
  tls_ms=$best_tls

  geo=$(curl -fsS --connect-timeout 4 -m 6 "https://ipinfo.io/${first}/json" 2>/dev/null) || true
  if [[ -n $geo ]]; then
    cc=$(jq -r '.country // ""' <<<"$geo" 2>/dev/null) || cc=""
    city=$(jq -r '.city // ""' <<<"$geo" 2>/dev/null) || city=""
    org=$(jq -r '.org // ""' <<<"$geo" 2>/dev/null | tr '|' ' ') || org=""
  fi
  echo "PASS|$host|$best|$tls_ms|$first|$cc|$city|$org|$pq|${SNI_CHAIN_LEN:-?}"
}

# NAT 模式（小内存）降低并发并减少候选数量
SNI_PAR=10
sni_cap() { # 输出候选列表（NAT 模式最多 12 个）
  if (( NAT_MODE )); then tr ' ' '\n' <<<"$*" | awk 'NF && ++n <= 12' | tr '\n' ' '; else printf '%s' "$*"; fi
}
# 并发测试一组域名，结果写入 $1 文件
sni_test_list() {
  local outfile=$1; shift
  local h n=0 total=$#
  mktmp
  load_cf_ranges
  local dir; dir=$(mktemp -d "${TMP_DIR}/probe.XXXXXX")
  for h in "$@"; do
    n=$((n + 1))
    while (( $(jobs -rp | wc -l) >= SNI_PAR )); do wait -n 2>/dev/null || true; done
    ( trap - ERR; set +e; sni_probe "$h" >"${dir}/${n}.res" 2>/dev/null ) &
    printf '\r  正在检测 %d/%d ...' "$n" "$total"
  done
  wait || true
  printf '\r%-40s\r' " "
  cat "${dir}"/*.res 2>/dev/null >"$outfile" || : >"$outfile"
}

# 排序：同国家优先，其次支持 X25519MLKEM768 优先（Y > ? > N），再证书链 ≥ 3500（可用 pqv）优先，最后按 TLS 握手 / TCP 延迟
sni_sorted_pass() { # $1 结果文件
  awk -F'|' -v cc="$GEO_CC" -v min="$MLDSA_MIN_CHAIN" '$1=="PASS"{s=($6==cc || cc=="")?0:1; p=($9=="Y")?0:(($9=="N")?2:1)
      c=($10 ~ /^[0-9]+$/ && $10+0 < min+0)?1:0; print s"|"p"|"c"|"$0}' "$1" |
    sort -t'|' -k1,1n -k2,2n -k3,3n -k7,7n -k6,6n | cut -d'|' -f4-
}
# PQ 字段显示文字
sni_pq_label() { case $1 in Y) echo "支持" ;; N) echo "不支持" ;; *) echo "未知" ;; esac; }
# 选定的 SNI 不支持 X25519MLKEM768 时的提示（$1 域名 $2 PQ 字段）
sni_pq_warn() {
  [[ $2 == N ]] || return 0
  warn "${1} 不支持后量子密钥交换 X25519MLKEM768：其余检测均通过，REALITY 可正常使用，只是没有后量子密钥交换保护。"
  warn "  以后可用 proxy sni 换成支持 MLKEM 的目标（安装后的 REALITY 自检会验证实际可用性）。"
}

sni_print_table() { # $1 = 已排序 PASS 列表文件, $2 = 显示条数
  local i=0 line host rtt tls ip cc city org pq chain
  printf '  %-4s %-30s %-9s %-9s %-6s %-6s %-16s %s\n' "No." "Domain(域名)" "TCP-RTT" "TLS-HS" "MLKEM" "Chain" "IP" "位置 / ASN"
  while IFS='|' read -r _ host rtt tls ip cc city org pq chain; do
    i=$((i + 1)); (( i > $2 )) && break
    local mark=""; [[ -n $GEO_CC && -n $cc && $cc != "$GEO_CC" ]] && mark="${C_YELLOW}(异国)${C_NONE}"
    local pqm="?"; [[ $pq == Y ]] && pqm="yes"; [[ $pq == N ]] && pqm="no"
    printf '  %-4s %-30s %-9s %-9s %-6s %-6s %-16s %s %s %s\n' "$i)" "$host" "${rtt}ms" "${tls}ms" "$pqm" "${chain:-?}" "$ip" "${cc}/${city}" "${org:0:28}" "$mark"
  done <"$1"
}

# 解析 RealiTLScanner CSV：按表头定位列，筛选 TLS1.3 + h2，去掉通配符/黑名单域名
scanner_parse() {
  local dom
  awk -F',' 'NR==1{for(i=1;i<=NF;i++){gsub(/"/,"",$i); c[$i]=i}; next}
    { tls=(c["TLS"] ? $(c["TLS"]) : "TLS 1.3"); alpn=(c["ALPN"] ? $(c["ALPN"]) : "h2"); d=$(c["CERT_DOMAIN"]); gsub(/"/,"",d)
      if (tls ~ /1\.3/ && alpn=="h2" && d !~ /^\*/ && d ~ /\./) print tolower(d) }' "$1" | sort -u |
    while read -r dom; do sni_blacklisted "$dom" || echo "$dom"; done | awk 'NR <= 40'
}

# 使用 RealiTLScanner 扫描 VPS 附近 IP（同 ASN / 同机房）的可用目标
scanner_collect() { # $1 输出候选列表文件
  local out=$1 url csv secs=${SCAN_SECS:-60}
  [[ -n $PUBLIC_IP4 ]] || { warn "无 IPv4，无法扫描。"; return 1; }
  # proxy sni 不经过 preflight，ARCH 仍为空时下载地址会变成 RealiTLScanner-linux- 并 404
  [[ -n $ARCH ]] || detect_os
  if [[ ! -x $SCANNER_BIN ]]; then
    url="https://github.com/XTLS/RealiTLScanner/releases/download/${SCANNER_VER}/RealiTLScanner-linux-${ARCH}"
    info "下载 RealiTLScanner ${SCANNER_VER} ..."
    mkdir -p "$(dirname "$SCANNER_BIN")"
    fetch -o "${SCANNER_BIN}.tmp" "$url" || { warn "RealiTLScanner 下载失败。"; rm -f "${SCANNER_BIN}.tmp"; return 1; }
    chmod 755 "${SCANNER_BIN}.tmp"; mv -f "${SCANNER_BIN}.tmp" "$SCANNER_BIN"
  fi
  mktmp
  csv="${TMP_DIR}/scan.csv"
  warn "在 VPS 上扫描可能被服务商视为端口扫描（少数商家会警告），将以低并发扫描 ${secs} 秒。"
  info "正在扫描 ${PUBLIC_IP4} 附近的 IP ..."
  ( cd "$TMP_DIR" && timeout "$secs" "$SCANNER_BIN" -addr "$PUBLIC_IP4" -port 443 -thread 4 -timeout 4 -out "$csv" >/dev/null 2>&1 ) || true
  [[ -s $csv ]] || { warn "扫描未得到结果。"; return 1; }
  scanner_parse "$csv" >"$out"
  [[ -s $out ]] || { warn "扫描结果中没有符合 TLS1.3 + h2 的域名。"; return 1; }
  info "扫描得到 $(wc -l <"$out") 个候选域名，开始逐一验证 ..."
}

# 主流程：自动优选 SNI。结果写入全局 SNI
select_sni() {
  SELF_SNI=0
  mktmp
  local keys main near cands="" k res="${TMP_DIR}/sni.res" sorted="${TMP_DIR}/sni.sorted"
  # 1) 命令行指定
  if [[ -n $OPT_SNI ]]; then
    info "验证指定的 SNI: ${OPT_SNI} ..."
    load_cf_ranges
    local r; r=$( ( trap - ERR; set +e; sni_probe "$OPT_SNI" ) )
    if [[ $r == PASS* ]]; then
      SNI=${OPT_SNI,,}; ok "SNI ${SNI} 通过检测（TLS 握手 $(cut -d'|' -f4 <<<"$r")ms，X25519MLKEM768: $(sni_pq_label "$(cut -d'|' -f9 <<<"$r")")）。"
      sni_pq_warn "$SNI" "$(cut -d'|' -f9 <<<"$r")"
      return 0
    fi
    warn "SNI ${OPT_SNI} 未通过检测：$(cut -d'|' -f3 <<<"$r")"
    if (( OPT_FORCE_SNI )); then warn "已指定 --force-sni，仍然使用。"; SNI=${OPT_SNI,,}; return 0; fi
    (( OPT_AUTO )) && die "指定的 SNI 不合格。如确认要使用，请追加 --force-sni。"
  fi

  keys=$(sni_region_keys)
  main=${keys%%|*} near=${keys#*|}
  step "自动优选 REALITY 目标网站 (SNI)"
  if (( NAT_MODE )); then
    SNI_PAR=3
    (( OPT_SCAN )) && { warn "NAT 模式不支持 --scan（节省资源，且 NAT 机器扫描邻居 IP 意义不大），已忽略。"; OPT_SCAN=0; }
    info "NAT 精简模式：每个地区最多测试 12 个候选，并发 3。"
  fi
  info "VPS 位置: ${GEO_CC:-未知} ${GEO_REGION} ${GEO_CITY}  ${GEO_ORG}"
  info "筛选规则: 同地区 · TLS1.3+X25519 · ALPN h2 · HSTS · 证书有效 · 非 CDN/WAF · 非大厂/被墙域名（支持 X25519MLKEM768 者优先）"

  if (( OPT_SCAN )); then
    local scanned="${TMP_DIR}/scan.list"
    if scanner_collect "$scanned"; then
      # shellcheck disable=SC2046
      sni_test_list "$res" $(cat "$scanned")
      sni_sorted_pass "$res" >"$sorted"
    fi
  fi
  if [[ ! -s ${sorted} ]]; then
    [[ -n $main ]] && cands=$(sni_cap "$(sni_candidates "$main")")
    info "测试 ${main:-通用} 地区候选（$(wc -w <<<"$cands") 个）..."
    # shellcheck disable=SC2086
    [[ -n $cands ]] && sni_test_list "$res" $cands
    [[ -f $res ]] || : >"$res"
    sni_sorted_pass "$res" >"$sorted"
    if (( $(wc -l <"$sorted") < 3 )) && [[ -n $near ]]; then
      cands=""
      for k in $near; do cands+=" $(sni_candidates "$k")"; done
      cands=$(sni_cap "$cands")
      info "本地区合格数量不足，扩大到邻近地区（$(wc -w <<<"$cands") 个）..."
      # shellcheck disable=SC2086
      sni_test_list "${res}.2" $cands
      cat "${res}.2" >>"$res"
      sni_sorted_pass "$res" >"$sorted"
    fi
  fi

  local npass; npass=$(wc -l <"$sorted")
  if (( npass == 0 )); then
    warn "没有候选域名通过全部检测。"
    awk -F'|' '$1=="FAIL" && ++n <= 15 {printf "    %s: %s\n", $2, $3}' "$res"
    (( OPT_AUTO )) && die "自动模式下无法确定 SNI，请用 --sni 指定（或 --force-sni）。"
    manual_sni && return 0
    die "未选择 SNI。"
  fi
  echo
  _green "通过检测的候选（按 同国家优先 + 支持 MLKEM 优先 + TLS 握手延迟 排序）："
  sni_print_table "$sorted" 8
  local fails; fails=$(grep -c '^FAIL' "$res" || true)
  printf '  （另有 %s 个候选未通过，已排除）\n\n' "$fails"
  if ! cut -d'|' -f9 "$sorted" | grep -q '^Y$'; then
    warn "通过检测的候选均不支持（或无法确认支持）X25519MLKEM768，已放宽为偏好条件，仍从中选择。"
  fi
  local best; best=$(head -n1 "$sorted" | cut -d'|' -f2)
  if (( OPT_AUTO )); then
    SNI=$best; ok "自动选择: ${SNI}"
    sni_pq_warn "$SNI" "$(head -n1 "$sorted" | cut -d'|' -f9)"
    return 0
  fi
  local choice
  while :; do
    ask choice "请选择序号，或输入 m 手动填写域名" "1"
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= npass && choice <= 8 )); then
      SNI=$(sed -n "${choice}p" "$sorted" | cut -d'|' -f2)
      sni_pq_warn "$SNI" "$(sed -n "${choice}p" "$sorted" | cut -d'|' -f9)"
      break
    elif [[ $choice == [mM] ]]; then
      manual_sni && break
    else
      warn "输入无效。"
    fi
  done
  ok "已选择 SNI: ${SNI}"
}

sni_own_port_busy() {
  local candidate=$1 v
  for v in "$XRAY_PORT" "$XHTTP_PORT" "$TROJAN_PORT" "$ANYTLS_PORT" "$XHTTP_TLS_PORT" "$WS_PORT" "$SUB_PORT" "$OPT_SUB_PORT" "$LAND_PORT" "$OPT_LAND_PORT"; do
    [[ -n $v && $v == "$candidate" ]] && return 0
  done
  port_in_use tcp "$candidate"
}
sni_own_port_planned() {
  local candidate=$1 v
  for v in "$XRAY_PORT" "$XHTTP_PORT" "$TROJAN_PORT" "$ANYTLS_PORT" "$XHTTP_TLS_PORT" "$WS_PORT" "$SUB_PORT" "$OPT_SUB_PORT" "$LAND_PORT" "$OPT_LAND_PORT"; do
    [[ -n $v && $v == "$candidate" ]] && return 0
  done
  return 1
}
sni_own_pick_target() {
  local old=${SNI_TARGET##*:} p
  if [[ ${SELF_SNI:-0} == 1 && $old =~ ^[0-9]+$ ]] && ! sni_own_port_planned "$old" \
      && svc_active proxy-oneclick-reality-site; then
    printf '127.0.0.1:%s' "$old"
    return 0
  fi
  for ((p=REALITY_SITE_DEFAULT_PORT; p<REALITY_SITE_DEFAULT_PORT+20; p++)); do
    sni_own_port_busy "$p" || { printf '127.0.0.1:%s' "$p"; return 0; }
  done
  die "没有可用于自有域名 HTTPS 回落服务的本机端口（${REALITY_SITE_DEFAULT_PORT}–$((REALITY_SITE_DEFAULT_PORT + 19))）。"
}
select_self_sni() { # $1 自有域名；REALITY TLS 回落到本机 HTTPS 服务
  local d=${1#https://} kind
  d=${d%%/*}; d=${d,,}; d=${d%.}; d=${d// /}
  cert_domain_syntax "$d" || die "自有 SNI 必须是有效域名，例如 node.example.com。"
  (( NAT_MODE )) && die "自有域名 SNI 需要公网证书和本机 HTTPS 回落服务，NAT 模式不支持。"
  (( REALITY_ENABLED )) || die "自有域名 SNI 只适用于 VLESS-REALITY；请启用 REALITY。"
  [[ ${INIT_SYS:-} == systemd ]] || die "自有域名 SNI 的本机 HTTPS 回落服务目前需要 systemd。"
  [[ -z $OPT_SNI ]] || die "--own-sni 不能和 --sni 同时使用。"
  [[ ${OPT_CERT:-1} != 0 ]] || die "自有域名 SNI 需要公开证书，不能同时使用 --no-cert。"
  [[ -z ${OPT_CERT_DOMAIN:-} || ${OPT_CERT_DOMAIN} == "$d" ]] || die "--cert-domain 必须与 --own-sni 相同。"
  [[ -z ${OPT_CERT_NAMES:-} || ${OPT_CERT_NAMES} == "$d" ]] || die "--cert-names 必须与 --own-sni 相同。"
  [[ -z ${OPT_CERT_NAMES:-}${OPT_CF_ORIGIN_KEY:-}${OPT_ZEROSSL_KID:-}${OPT_ZEROSSL_HMAC:-} ]] || die "自有域名 SNI 使用 Let's Encrypt 单域名证书，不能同时指定其它证书类型或凭据。"
  if [[ -n ${OPT_CERT_KIND:-} ]]; then
    kind=$(cert_normalize_kind "$OPT_CERT_KIND") || die "自有域名 SNI 只支持 Let's Encrypt 单域名证书。"
    [[ $kind == le ]] || die "自有域名 SNI 只支持 Let's Encrypt 单域名证书。"
  fi
  [[ -n ${PUBLIC_IP4:-}${PUBLIC_IP6:-} ]] || detect_ip
  cert_domain_points_here "$d" || die "域名 ${d} 没有全部解析到本机；请先修改 A/AAAA 记录并关闭 CDN 代理。"
  SELF_SNI=1
  SNI=$d
  OPT_CERT=1
  OPT_CERT_KIND=le
  OPT_CERT_DOMAIN=$d
  SNI_TARGET=$(sni_own_pick_target)
  # 自有域名的回落证书链长度不保证满足 Xray 的 ML-DSA pqv 门槛；保留 REALITY，关闭可选的 pqv。
  MLDSA_ON=0
  info "SNI ${SNI} 将回落到本机 HTTPS 服务 ${SNI_TARGET}。请将域名 A/AAAA 指向本机、关闭 CDN 代理，并确保公网 TCP 80 可用于签发证书。"
  warn "自有域名模式不输出 ML-DSA pqv（可选增强）；REALITY 仍正常工作。"
}

select_install_sni() {
  local d
  if [[ -n $OPT_OWN_SNI ]]; then select_self_sni "$OPT_OWN_SNI"; return; fi
  if [[ -z $OPT_SNI ]] && (( ! OPT_AUTO )) && confirm "是否使用自己的域名作为 REALITY SNI？域名需解析到本机，并通过 TCP 80 申请公开证书。" y; then
    ask d "请输入指向本机的域名（例如 node.example.com，留空继续普通 SNI）" ""
    if [[ -n $d ]]; then select_self_sni "$d"; return; fi
    warn "没有输入自有域名，继续原有 SNI 优选流程。"
  fi
  SELF_SNI=0
  select_sni
  SNI_TARGET="${SNI}:443"
}

install_should_select_sni() {
  (( ! OPT_AUTO )) || [[ -n $OPT_SNI || -n $OPT_OWN_SNI || -z $SNI ]]
}

manual_sni() {
  local d r
  while :; do
    ask d "请输入目标域名（例如 www.example.edu，留空返回）" ""
    [[ -z $d ]] && return 1
    d=${d#https://}; d=${d%%/*}; d=${d,,}
    info "正在检测 ${d} ..."
    load_cf_ranges
    r=$( ( trap - ERR; set +e; sni_probe "$d" ) )
    if [[ $r == PASS* ]]; then
      local pq
      IFS='|' read -r _ _ _ rtt ip cc city org pq _ <<<"$r"
      ok "${d} 通过检测：TLS 握手 ${rtt}ms，IP ${ip} (${cc} ${city} ${org})，X25519MLKEM768: $(sni_pq_label "$pq")"
      [[ -n $GEO_CC && $cc != "$GEO_CC" ]] && warn "该网站 IP 与 VPS 不在同一国家，不推荐。"
      sni_pq_warn "$d" "$pq"
      SNI=$d; return 0
    fi
    warn "${d} 未通过检测：$(cut -d'|' -f3 <<<"$r")"
    if confirm "仍然坚持使用 ${d} 吗？（不推荐）" n; then SNI=$d; return 0; fi
  done
}

# ============================================================
#                        端口 / SSH 检测
# ============================================================
# 返回占用某端口的进程名（空=未占用）。$1=tcp|udp $2=端口
port_owner() {
  local flag=-Htlnp; [[ $1 == udp ]] && flag=-Hulnp
  ss "$flag" "sport = :$2" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | sed -E 's/^users:\(\("//; s/"$//' || true
}
port_in_use() { [[ -n $(ss "$([[ $1 == udp ]] && echo -Huln || echo -Htln)" "sport = :$2" 2>/dev/null) ]]; }

# 检查端口是否可用（被自己的服务占用视为可用）
check_port_free() { # $1 proto $2 port $3 允许的进程名(正则)
  local owner
  port_in_use "$1" "$2" || return 0
  owner=$(port_owner "$1" "$2")
  [[ -n $owner && $owner =~ ^($3)$ ]] && return 0
  # 容器内缺少 CAP_SYS_PTRACE 时 ss 看不到进程名：若本脚本服务正在运行且配置的就是该端口，视为自身占用
  if [[ -z $owner ]]; then
    [[ $1 == tcp && $2 == "$XRAY_PORT" && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$XHTTP_PORT" && ${XHTTP_ENABLED:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$TROJAN_PORT" && ${TROJAN_ENABLED:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$ANYTLS_PORT" && ${ANYTLS_ENABLED:-0} == 1 && sing-box =~ ^($3)$ ]] && svc_active sing-box && return 0
    [[ $1 == udp && $2 == "$HY2_PORT" && hysteria =~ ^($3)$ ]] && svc_active hysteria-server && return 0
    [[ $1 == udp && $2 == "$TUIC_PORT" && ${TUIC_ENABLED:-0} == 1 && sing-box =~ ^($3)$ ]] && svc_active sing-box && return 0
    [[ $1 == udp && $2 == "$XRAY_PORT" && ${LAND_MODE:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "${LAND_PORT:-}" && ${LAND_IN:-0} == 1 && ${LAND_MODE:-0} != 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == udp && $2 == "${LAND_PORT:-}" && ${LAND_IN:-0} == 1 && ${LAND_MODE:-0} != 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$SUB_PORT" ]] && cert_is_public && [[ $3 =~ python ]] && svc_active proxy-oneclick-sub && return 0
    [[ $1 == tcp && $2 == "$XHTTP_TLS_PORT" && ${XHTTP_TLS_ENABLED:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$WS_PORT" && ${WS_ENABLED:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
  fi
  warn "${1^^} 端口 $2 已被占用（进程: ${owner:-未知}）。"
  return 1
}

detect_ssh_ports() {
  local ports="" p
  if have sshd; then
    ports+=" $(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | tr '\n' ' ')" || true
  fi
  if [[ -z ${ports// /} ]]; then
    ports+=" $(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | tr '\n' ' ')" || true
  fi
  # 监听中的 sshd / ssh.socket
  ports+=" $(ss -Htlnp 2>/dev/null | awk '/"sshd"|sshd:/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')" || true
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    ports+=" $(systemctl show ssh.socket -p Listen 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}' | tr '\n' ' ')" || true
  fi
  # 当前 SSH 会话实际使用的端口
  if [[ -n ${SSH_CONNECTION:-} ]]; then ports+=" $(awk '{print $4}' <<<"$SSH_CONNECTION")"; fi
  local uniq=""
  for p in $ports; do is_port "$p" && [[ " $uniq " != *" $p "* ]] && uniq+="$p "; done
  [[ -n $uniq ]] || uniq="22 "
  SSH_PORTS=${uniq% }
}

# 列出除本脚本服务 / SSH 外其它对外监听的端口
other_listen_ports() { # $1 = tcp|udp
  local flag=-Htlnp; [[ $1 == udp ]] && flag=-Hulnp
  local elo=32768 ehi=60999
  read -r elo ehi </proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true
  ss "$flag" 2>/dev/null | awk '{print $4, $NF}' | while read -r addr users; do
    local port=${addr##*:} ip=${addr%:*}
    # 看不到进程名（容器内缺少权限）的临时端口 UDP 套接字多为客户端连接（如 Hysteria2 经 socks5 转发落地的 UDP 会话），不是服务
    [[ $1 == udp && $users != *users:* && $port =~ ^[0-9]+$ ]] && (( port >= elo && port <= ehi )) && continue
    [[ $ip =~ ^(127\.|\[::1\]|::1|\[?fe80) ]] && continue
    [[ $ip == "127.0.0.53%lo" || $ip == 127.0.0.54 ]] && continue
    [[ $users =~ \"(xray|hysteria|sing-box|sshd|systemd-resolve|chronyd|dhclient|systemd-network)\" ]] && continue
    [[ ${CERT_ON:-0} == 1 && $port == "$SUB_PORT" && $users == *python* ]] && continue
    [[ " $SSH_PORTS " == *" $port "* ]] && continue
    echo "$port"
  done | sort -un | tr '\n' ' ' || true
}

# ============================================================
#           内核备份 / 指定版本 / 回滚（xray、hysteria、sing-box）
# ============================================================
# 本次进程里换过程序时才在启动失败后自动换回。跳过备份时单独记住，避免被下一次覆盖。
BIN_UPDATED_XRAY=0
BIN_UPDATED_HY2=0
BIN_UPDATED_SB=0
BIN_BAK_MADE=0
BIN_BAK_SKIP_XRAY=0
BIN_BAK_SKIP_HY2=0
BIN_BAK_SKIP_SB=0
# 50 MB = 51200 KiB。df -Pk 的第 4 列是可用的 1 KiB 块。
readonly BIN_FREE_MIN_KB=51200

bin_free_kb() { # $1 目录。失败时输出空
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}
bin_backup() { # $1 程序路径  $2 xray|hy2|singbox。先写成 .prebak，替换成功后再收成 .bak
  BIN_BAK_MADE=0
  local p=$1 kind=$2 kb="" dir
  [[ -f $p && -s $p ]] || return 0
  dir=$(dirname "$p")
  kb=$(bin_free_kb "$dir") || kb=""
  if [[ $kb =~ ^[0-9]+$ ]] && (( kb < BIN_FREE_MIN_KB )); then
    if (( kb >= 1024 )); then
      warn "剩余空间不足 50 MB（${dir} 可用约 $((kb / 1024)) MB），跳过备份 ${p##*/}.bak。"
    else
      warn "剩余空间不足 50 MB（${dir} 可用不足 1 MB），跳过备份 ${p##*/}.bak。"
    fi
    case $kind in
      xray) BIN_BAK_SKIP_XRAY=1 ;;
      hy2) BIN_BAK_SKIP_HY2=1 ;;
      singbox) BIN_BAK_SKIP_SB=1 ;;
    esac
    return 0
  fi
  rm -f "${p}.prebak"
  if ! cp -a "$p" "${p}.prebak"; then
    warn "备份 ${p} 失败，继续更新（这次失败时无法自动换回）。"
    rm -f "${p}.prebak"
    case $kind in
      xray) BIN_BAK_SKIP_XRAY=1 ;;
      hy2) BIN_BAK_SKIP_HY2=1 ;;
      singbox) BIN_BAK_SKIP_SB=1 ;;
    esac
    return 0
  fi
  BIN_BAK_MADE=1
}
bin_backup_keep() { # $1 程序路径  $2 xray|hy2|singbox。新程序已经放好，把临时备份收成 .bak
  local p=$1 kind=$2
  [[ -f ${p}.prebak ]] || return 0
  # 临时备份和当前程序相同就丢掉。不能拿它盖掉已有的 .bak，否则更早的版本没了。
  if [[ -e $p ]] && cmp -s "${p}.prebak" "$p"; then
    rm -f "${p}.prebak"
    return 0
  fi
  mv -f "${p}.prebak" "${p}.bak"
  case $kind in
    xray) BIN_UPDATED_XRAY=1 ;;
    hy2) BIN_UPDATED_HY2=1 ;;
    singbox) BIN_UPDATED_SB=1 ;;
  esac
  info "已备份当前程序: ${p}.bak"
}
bin_backup_drop() { rm -f "${1}.prebak"; }
bin_version() { # $1 xray|hy2|singbox  $2 程序路径
  local kind=$1 p=$2
  [[ -x $p ]] || return 0
  case $kind in
    xray) "$p" version 2>/dev/null | awk 'NR==1{print $2}' || true ;;
    hy2) "$p" version 2>/dev/null | awk '/^Version:/{print $2}' || true ;;
    singbox) "$p" version 2>/dev/null | awk 'NR==1{print $NF}' || true ;;
  esac
}
bin_norm_tag() { # $1 xray|hy2|singbox  $2 用户写的版本。输出 GitHub 标签
  local kind=$1 raw=$2 t
  t=${raw#refs/tags/}
  t=${t// /}
  [[ -n $t ]] || return 1
  case $kind in
    xray|singbox)
      if [[ $t == [Vv]* ]]; then t="v${t:1}"; else t="v${t}"; fi
      [[ $t =~ ^v[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || return 1
      ;;
    hy2)
      t=${t#app/}
      if [[ $t == [Vv]* ]]; then t="v${t:1}"; else t="v${t}"; fi
      t="app/${t}"
      [[ $t =~ ^app/v[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s' "$t"
}
hy_official_ver() { # app/v2.6.1 -> v2.6.1（get.hy2.sh 的 --version 必须带 v，不能带 app/）
  local t=${1#app/}
  [[ $t == v* ]] || t="v${t}"
  printf '%s' "$t"
}
xray_ver_same() { # $1 程序打出的版本  $2 标签 vX
  local a=$1 b=$2
  [[ -n $a && -n $b ]] || return 1
  a=v${a#v}; b=v${b#v}
  [[ $a == "$b" ]]
}
hy_ver_same() { # $1 程序打出的版本  $2 标签 app/vX 或 vX
  local a=$1 b=$2
  [[ -n $a && -n $b ]] || return 1
  a=${a#app/}; a=${a#v}
  b=${b#app/}; b=${b#v}
  [[ $a == "$b" ]]
}
gh_release_ok() { # $1 仓库（owner/name）  $2 标签。存在返回 0
  local repo=$1 tag=$2 code="" enc
  enc=${tag//\//%2F}
  code=$(gh_curl -sS -o /dev/null -w '%{http_code}' "${FETCH_IP[@]}" --connect-timeout 10 -m 20 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repo}/releases/tags/${enc}" 2>/dev/null) || code=""
  [[ $code == 200 ]] && return 0
  # 接口被限流或不可达时，再看发布页本身在不在。令牌不会出现在这条命令里。
  curl -fsSIL "${FETCH_IP[@]}" --connect-timeout 10 -m 20 -o /dev/null \
    "https://github.com/${repo}/releases/tag/${tag}" 2>/dev/null
}
xray_check_bin() { # $1 程序路径。version，有当前配置时再 run -test
  local b=$1 log
  [[ -x $b ]] || { warn "无法执行 ${b}。"; return 1; }
  "$b" version >/dev/null 2>&1 || { warn "xray version 没有成功（${b}）。"; return 1; }
  [[ -s $XRAY_CONF ]] || return 0
  log=$(mktemp)
  if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$b" run -test -config "$XRAY_CONF" >"$log" 2>&1; then
    warn "xray run -test 未通过（${b}）。"
    tail -n 20 "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}
sb_check_bin() { # $1 程序路径。version，有当前配置时再 check
  local b=$1 log
  [[ -x $b ]] || { warn "无法执行 ${b}。"; return 1; }
  "$b" version >/dev/null 2>&1 || { warn "sing-box version 没有成功（${b}）。"; return 1; }
  [[ -s $SB_CONF ]] || return 0
  log=$(mktemp)
  if ! "$b" check -c "$SB_CONF" >"$log" 2>&1; then
    warn "sing-box check 未通过（${b}）。"
    tail -n 20 "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}
hy_check_bin() { # hysteria 没有配置检查，只确认 version 能跑
  local b=$1
  [[ -x $b ]] || { warn "无法执行 ${b}。"; return 1; }
  "$b" version >/dev/null 2>&1 || { warn "hysteria version 没有成功（${b}）。"; return 1; }
}
bin_finish_install() { # $1 种类  $2 程序  $3 显示名  $4 替换前的版本。版本变了才记「已更新」
  local kind=$1 bin=$2 name=$3 old=$4 new=""
  new=$(bin_version "$kind" "$bin" || true)
  if [[ -z $new ]]; then bin_backup_drop "$bin"; die "安装后无法读取 ${name} 的版本。"; fi
  if [[ -n $old && $old == "$new" ]]; then
    # 版本没变。丢掉这次的临时备份，原来的 .bak 还在。
    bin_backup_drop "$bin"
    case $kind in
      xray) BIN_UPDATED_XRAY=0 ;;
      hy2) BIN_UPDATED_HY2=0 ;;
      singbox) BIN_UPDATED_SB=0 ;;
    esac
    ok "${name} 已安装: ${new}"
    return 0
  fi
  if [[ -f ${bin}.prebak ]]; then bin_backup_keep "$bin" "$kind"; fi
  if [[ -n $old ]]; then
    case $kind in
      xray) BIN_UPDATED_XRAY=1 ;;
      hy2) BIN_UPDATED_HY2=1 ;;
      singbox) BIN_UPDATED_SB=1 ;;
    esac
    ok "${name} ${old} -> ${new}"
  else
    ok "${name} 已安装: ${new}"
  fi
}
bin_restore_prebak() { # $1 种类 $2 程序 $3 服务 $4 显示名 $5 原因（带前导空格）
  local kind=$1 bin=$2 svc=$3 name=$4 why=$5 cur="" bakv=""
  if [[ ! -f ${bin}.prebak ]]; then die "${name}${why}。"; fi
  cur=$(bin_version "$kind" "$bin" || true)
  bakv=$(bin_version "$kind" "${bin}.prebak" || true)
  warn "${name}${why}，正在恢复备份 ..."
  install -m 755 "${bin}.prebak" "$bin" || die "恢复 ${bin}.prebak 失败。"
  rm -f "${bin}.prebak"
  if [[ $kind == xray ]]; then xray_geo_restore; fi
  if svc_exists "$svc"; then svc_restart "$svc" || true; sleep 1; fi
  die "${name}${why}，已恢复备份（${cur:-未知} -> ${bakv:-未知}）。"
}
bin_reject_new() { # $1 种类 $2 程序 $3 服务 $4 显示名 $5 是否有本次备份 $6 原因（带前导空格）
  local kind=$1 bin=$2 svc=$3 name=$4 made=$5 why=$6 cur="" bakv=""
  if [[ $made == 1 && -f ${bin}.prebak ]]; then
    cur=$(bin_version "$kind" "$bin" || true)
    bakv=$(bin_version "$kind" "${bin}.prebak" || true)
    if [[ ! -x $bin || $cur != "$bakv" ]]; then
      warn "${name}${why}，正在恢复备份 ..."
      install -m 755 "${bin}.prebak" "$bin" || die "恢复 ${bin}.prebak 失败。"
      rm -f "${bin}.prebak"
      if [[ $kind == xray ]]; then xray_geo_restore; fi
      if svc_exists "$svc"; then svc_restart "$svc" || true; sleep 1; fi
      die "${name}${why}，已恢复备份（${cur:-未知} -> ${bakv:-未知}）。"
    fi
    bin_backup_drop "$bin"
  fi
  if [[ $kind == xray ]]; then xray_geo_restore; fi
  die "${name}${why}。"
}
bin_restart_failed() { # 启动失败且这次换过程序：用 .bak 盖回去再拉起。0=已恢复且在跑 1=没有备份可换 2=换了仍没起来
  local kind=$1 bin=$2 svc=$3 name=$4 updated=0 skipped=0 old="" new=""
  case $kind in
    xray) updated=${BIN_UPDATED_XRAY:-0}; skipped=${BIN_BAK_SKIP_XRAY:-0} ;;
    hy2) updated=${BIN_UPDATED_HY2:-0}; skipped=${BIN_BAK_SKIP_HY2:-0} ;;
    singbox) updated=${BIN_UPDATED_SB:-0}; skipped=${BIN_BAK_SKIP_SB:-0} ;;
  esac
  [[ $updated == 1 ]] || return 1
  if [[ ! -f ${bin}.bak ]]; then
    if (( skipped )); then warn "${name} 没有备份（更新前剩余空间不足 50 MB），无法自动换回。"; fi
    return 1
  fi
  old=$(bin_version "$kind" "$bin" || true)
  new=$(bin_version "$kind" "${bin}.bak" || true)
  warn "${name} 启动失败，正在恢复 ${bin}.bak ..."
  install -m 755 "${bin}.bak" "$bin" || { warn "恢复 ${bin}.bak 失败。"; return 2; }
  if [[ $kind == xray ]]; then xray_geo_restore_bak; fi
  case $kind in
    xray) BIN_UPDATED_XRAY=0 ;;
    hy2) BIN_UPDATED_HY2=0 ;;
    singbox) BIN_UPDATED_SB=0 ;;
  esac
  svc_restart "$svc" || true
  sleep 1
  if svc_active "$svc"; then
    ok "${name} 已自动回滚: ${old:-未知} -> ${new:-未知}"
    return 0
  fi
  warn "${name} 回滚后仍未运行。"
  return 2
}
bin_swap_bak() { # 当前程序和 .bak 对调，这样再执行一次回滚可以换回去
  local p=$1 tmp
  [[ -f ${p}.bak ]] || return 1
  if [[ ! -e $p ]]; then
    install -m 755 "${p}.bak" "$p" || return 1
    return 0
  fi
  tmp="${p}.swaptmp"
  rm -f "$tmp"
  mv -f "$p" "$tmp" || return 1
  if ! mv -f "${p}.bak" "$p"; then
    mv -f "$tmp" "$p" || true
    return 1
  fi
  if ! mv -f "$tmp" "${p}.bak"; then
    warn "已换回 ${p}，但没能把刚才的程序留作 .bak。"
  fi
  chmod 755 "$p" 2>/dev/null || true
  if [[ -f ${p}.bak ]]; then chmod 755 "${p}.bak" 2>/dev/null || true; fi
  return 0
}
rollback_one() { # $1 xray|hy2|singbox
  local kind=$1 bin svc name old="" new=""
  case $kind in
    xray) bin=$XRAY_BIN; svc=xray; name=Xray ;;
    hy2) bin=$HY_BIN; svc=hysteria-server; name=Hysteria2 ;;
    singbox) bin=$SB_BIN; svc=sing-box; name=sing-box ;;
    *) die "未知组件: ${kind}（可选 xray、hy2、singbox、all）" ;;
  esac
  if [[ ! -f ${bin}.bak ]]; then
    # 点名回滚某一个时必须失败。all 仍跳过没有备份的组件。
    if [[ ${2-} == 1 ]]; then die "没有 ${bin}.bak，无法回滚 ${name}。"; fi
    warn "没有 ${bin}.bak，跳过 ${name}。"
    return 0
  fi
  old=$(bin_version "$kind" "$bin" || true)
  new=$(bin_version "$kind" "${bin}.bak" || true)
  bin_swap_bak "$bin" || die "换回 ${bin}.bak 失败。"
  if [[ $kind == xray ]]; then xray_geo_swap_bak; fi
  if [[ $kind == xray ]] && land_raw_active; then
    svc_disable_stop xray || true
    ok "${name} ${old:-未知} -> ${new:-未知}（原样转发中，未启动 Xray）"
    return 0
  fi
  if ! svc_exists "$svc"; then
    ok "${name} ${old:-未知} -> ${new:-未知}（服务未安装，只换回了程序）"
    return 0
  fi
  svc_restart "$svc" || true
  sleep 1
  if ! svc_active "$svc"; then
    warn "${name} 换回 ${new:-未知} 后没有跑起来，正在换回刚才的程序 ..."
    bin_swap_bak "$bin" || true
    if [[ $kind == xray ]]; then xray_geo_swap_bak; fi
    svc_restart "$svc" || true
    die "${name} 回滚失败，已换回 ${old:-未知}。"
  fi
  ok "${name} ${old:-未知} -> ${new:-未知}"
}
do_rollback() { # $1 xray|hy2|singbox|all
  local which=${1:-all} part
  load_state
  (( INSTALLED )) || die "尚未安装，请先选择「安装」。"
  [[ -n $INIT_SYS ]] || detect_init
  case $which in
    xray|hy2|singbox) rollback_one "$which" 1 ;;
    all)
      for part in xray hy2 singbox; do rollback_one "$part"; done
      ;;
    *) die "回滚目标无效: ${which}（可选 xray、hy2、singbox、all）" ;;
  esac
}

# ============================================================
#                        Xray 安装与配置
# ============================================================
# 地理数据文件和程序一起换。失败或回滚时按 .prebak / .bak 换回去。
xray_geo_snapshot() {
  local f
  mkdir -p "$XRAY_ASSET_DIR"
  for f in geoip.dat geosite.dat; do
    rm -f "${XRAY_ASSET_DIR}/${f}.prebak"
    [[ -s ${XRAY_ASSET_DIR}/$f ]] || continue
    cp -a "${XRAY_ASSET_DIR}/$f" "${XRAY_ASSET_DIR}/${f}.prebak" || warn "备份 ${f} 失败。"
  done
}
xray_geo_commit() {
  local f src live bak
  for f in geoip.dat geosite.dat; do
    src="${XRAY_ASSET_DIR}/${f}.prebak"
    live="${XRAY_ASSET_DIR}/$f"
    bak="${live}.bak"
    [[ -f $src ]] || continue
    if [[ -f $live ]] && cmp -s "$src" "$live"; then rm -f "$src"; continue; fi
    if [[ -f $bak ]] && cmp -s "$src" "$bak"; then rm -f "$src"; continue; fi
    mv -f "$src" "$bak"
  done
}
xray_geo_restore() {
  local f src
  for f in geoip.dat geosite.dat; do
    src="${XRAY_ASSET_DIR}/${f}.prebak"
    [[ -f $src ]] || continue
    mkdir -p "$XRAY_ASSET_DIR"
    install -m 644 "$src" "${XRAY_ASSET_DIR}/$f" || warn "恢复 ${f} 失败。"
    rm -f "$src"
  done
}
xray_geo_restore_bak() {
  local f live bak
  for f in geoip.dat geosite.dat; do
    live="${XRAY_ASSET_DIR}/$f"
    bak="${live}.bak"
    [[ -f $bak ]] || continue
    if [[ -f $live ]] && cmp -s "$live" "$bak"; then continue; fi
    mkdir -p "$XRAY_ASSET_DIR"
    install -m 644 "$bak" "$live" || warn "恢复 ${f} 失败。"
  done
}
xray_geo_swap_bak() {
  local f live bak tmp
  for f in geoip.dat geosite.dat; do
    live="${XRAY_ASSET_DIR}/$f"
    bak="${live}.bak"
    [[ -f $bak ]] || continue
    if [[ ! -e $live ]]; then
      mkdir -p "$XRAY_ASSET_DIR"
      install -m 644 "$bak" "$live" || warn "恢复 ${f} 失败。"
      continue
    fi
    if cmp -s "$live" "$bak"; then continue; fi
    tmp="${live}.swaptmp"
    rm -f "$tmp"
    mv -f "$live" "$tmp" || continue
    if ! mv -f "$bak" "$live"; then
      mv -f "$tmp" "$live" || true
      warn "换回 ${f} 失败。"
      continue
    fi
    mv -f "$tmp" "$bak" || warn "已换回 ${f}，但没能留下刚才的文件。"
  done
}
xray_abort_swap() {
  if [[ -f ${XRAY_BIN}.prebak ]]; then
    install -m 755 "${XRAY_BIN}.prebak" "$XRAY_BIN" || warn "恢复 Xray 程序失败。"
    rm -f "${XRAY_BIN}.prebak"
  fi
  rm -f "${XRAY_BIN}.new"
  xray_geo_restore
}
# 下载并解压到临时目录。不改正在使用的程序。
xray_fetch_release() { # $1 标签 vX  $2 解压目录
  local tag=$1 dg=$2 asset="" base="" want="" sum=""
  asset=$(xray_asset_name)
  [[ -n $asset ]] || die "当前架构不支持下载 Xray: ${ARCH:-未知}"
  base="https://github.com/XTLS/Xray-core/releases/download/${tag}"
  info "下载 ${asset} (${tag}) ..."
  fetch -o "${TMP_DIR}/${asset}" "${base}/${asset}" || { github_hint; die "下载 Xray 失败。"; }
  if fetch -o "${TMP_DIR}/${asset}.dgst" "${base}/${asset}.dgst" 2>/dev/null; then
    want=$(awk -F'= *' '/^SHA2-256/{print tolower($2); exit}' "${TMP_DIR}/${asset}.dgst" | tr -d '[:space:]')
    sum=$(sha256sum "${TMP_DIR}/${asset}" | awk '{print $1}')
    if [[ -n $want ]]; then
      [[ $want == "$sum" ]] || die "Xray 压缩包 SHA256 校验失败（期望 ${want}，实际 ${sum}），已中止。"
      ok "SHA256 校验通过。"
    else
      warn "无法解析 .dgst 文件，跳过 SHA256 校验。"
    fi
  else
    warn "未能下载 .dgst 校验文件，跳过 SHA256 校验。"
  fi
  rm -rf "$dg"
  mkdir -p "$dg"
  if (( NAT_MODE || LAND_MODE )); then
    unzip -qo "${TMP_DIR}/${asset}" xray -d "$dg" || die "解压 Xray 失败。"
  else
    unzip -qo "${TMP_DIR}/${asset}" -d "$dg" || die "解压 Xray 失败。"
  fi
  rm -f "${TMP_DIR}/${asset}" "${TMP_DIR}/${asset}.dgst"
  [[ -f $dg/xray ]] || die "压缩包中没有 xray 可执行文件。"
}
# 先用临时程序对当前配置做检查。通过之后才备份并替换程序和 geo 文件。检查失败返回 1，什么都不改。
xray_install_tree() { # $1 解压目录
  local dg=$1 old="" newv="" f
  [[ -f $dg/xray ]] || return 1
  chmod 755 "$dg/xray"
  if ! xray_check_bin "$dg/xray"; then return 1; fi
  old=$(bin_version xray "$XRAY_BIN" || true)
  newv=$(bin_version xray "$dg/xray" || true)
  if ! xray_ver_same "$old" "$newv"; then bin_backup "$XRAY_BIN" xray; fi
  if [[ -f $dg/geoip.dat || -f $dg/geosite.dat ]]; then xray_geo_snapshot; fi
  if ! install -m 755 "$dg/xray" "${XRAY_BIN}.new"; then
    xray_abort_swap
    die "写入 Xray 失败，已恢复原程序。"
  fi
  if ! mv -f "${XRAY_BIN}.new" "$XRAY_BIN"; then
    xray_abort_swap
    die "替换 Xray 失败，已恢复原程序。"
  fi
  mkdir -p "$XRAY_ASSET_DIR"
  for f in geoip.dat geosite.dat; do
    [[ -f $dg/$f ]] || continue
    if ! install -m 644 "$dg/$f" "${XRAY_ASSET_DIR}/$f"; then
      xray_abort_swap
      die "写入 ${f} 失败，已恢复原程序和地理数据。"
    fi
  done
  bin_finish_install xray "$XRAY_BIN" "Xray" "$old"
  xray_geo_commit
  return 0
}
xray_ensure_service() {
  if direct_mode || [[ ! -f $XRAY_UNIT ]] || grep -q '由 proxy-oneclick 生成' "$XRAY_UNIT"; then
    write_xray_service
  else
    ensure_xray_runs_as_nobody "$XRAY_UNIT" || true
  fi
}
install_xray_pinned() {
  BIN_UPDATED_XRAY=0
  BIN_BAK_SKIP_XRAY=0
  step "安装 / 更新 Xray-core（指定版本，直接下载发布包）"
  mktmp
  local tag="" old="" dg=""
  tag=$(bin_norm_tag xray "$OPT_XRAY_VER") || die "Xray 版本号无效: ${OPT_XRAY_VER}（例如 v26.3.27）"
  gh_release_ok XTLS/Xray-core "$tag" || die "找不到 Xray 版本 ${tag}（GitHub 上没有这个发布，或网络不可达）。"
  old=$(bin_version xray "$XRAY_BIN" || true)
  if xray_ver_same "$old" "$tag" && [[ -x $XRAY_BIN ]] && { (( NAT_MODE || LAND_MODE )) || [[ -f ${XRAY_ASSET_DIR}/geoip.dat ]]; }; then
    ok "Xray 已是指定版本 ${tag}，跳过下载。"
  else
    dg="${TMP_DIR}/xray-unzip"
    xray_fetch_release "$tag" "$dg"
    if ! xray_install_tree "$dg"; then
      rm -rf "$dg"
      die "下载的 Xray 未通过校验，未替换现有程序。"
    fi
    rm -rf "$dg"
  fi
  xray_ensure_service
}
install_xray() {
  if [[ -n ${OPT_XRAY_VER:-} ]]; then install_xray_pinned; return; fi
  if direct_mode; then install_xray_direct; return; fi
  BIN_UPDATED_XRAY=0
  BIN_BAK_SKIP_XRAY=0
  step "安装 / 更新 Xray-core（官方 XTLS/Xray-install 脚本）"
  mktmp
  # 之前以 NAT / 落地机模式安装过：删除本脚本自建的服务文件，让官方脚本重新安装它的 xray.service
  # （自建服务只在端口 < 1024 时才有 CAP_NET_BIND_SERVICE，官方脚本不会覆盖已存在的服务文件）
  local force=() tag="" old="" backed=0 same=0
  if [[ -f $XRAY_UNIT ]] && grep -q '由 proxy-oneclick 生成' "$XRAY_UNIT"; then
    systemctl stop xray >/dev/null 2>&1 || true
    rm -f "$XRAY_UNIT"; systemctl daemon-reload
  fi
  # 已有 xray 但没有服务文件时，官方脚本会因「版本相同」直接退出而不安装服务：强制重装
  [[ ! -f $XRAY_UNIT && -x $XRAY_BIN ]] && force=(--force)
  old=$(bin_version xray "$XRAY_BIN" || true)
  if [[ -n $OPT_XRAY_VER ]]; then
    tag=$(bin_norm_tag xray "$OPT_XRAY_VER") || die "Xray 版本号无效: ${OPT_XRAY_VER}（例如 v26.3.27）"
    gh_release_ok XTLS/Xray-core "$tag" || die "找不到 Xray 版本 ${tag}（GitHub 上没有这个发布，或网络不可达）。"
  else
    tag=$(gh_latest_tag XTLS/Xray-core)
    [[ -n $tag ]] || { github_hint; die "获取 Xray 最新版本号失败。"; }
  fi
  xray_ver_same "$old" "$tag" && same=1
  if (( same && ${#force[@]} == 0 )); then
    if [[ -n $OPT_XRAY_VER ]]; then ok "Xray 已是指定版本 ${tag}，跳过下载。"
    else ok "Xray 已是最新版本 ${tag}，跳过下载。"; fi
    ensure_xray_runs_as_nobody "$XRAY_UNIT" || true
    return 0
  fi
  # 未指定版本时仍用官方脚本，它会自己覆盖程序。先备份程序和 geo，写完立刻检查，不通过就换回。
  if (( ! same )); then bin_backup "$XRAY_BIN" xray; backed=$BIN_BAK_MADE; fi
  fetch -o "${TMP_DIR}/xray-install.sh" "$XRAY_INSTALL_URL" || { bin_backup_drop "$XRAY_BIN"; die "下载 Xray 安装脚本失败，请检查网络（GitHub 可达性）。"; }
  if (( same )); then force=(--force); fi
  # 官方安装器会在返回前尝试启动服务；先固定用户，避免它用 xray 用户读取 nobody 组的 640 配置而失败。
  ensure_xray_runs_as_nobody "$XRAY_UNIT" || true
  xray_geo_snapshot
  if ! TERM=${TERM:-dumb} bash "${TMP_DIR}/xray-install.sh" install --version "$tag" "${force[@]}" >"${TMP_DIR}/xray-install.log" 2>&1; then
    tail -n 20 "${TMP_DIR}/xray-install.log" >&2 || true
    bin_reject_new xray "$XRAY_BIN" xray "Xray" "$backed" " 安装失败"
  fi
  [[ -x $XRAY_BIN ]] || bin_reject_new xray "$XRAY_BIN" xray "Xray" "$backed" " 安装失败"
  if ! xray_check_bin "$XRAY_BIN"; then
    xray_geo_restore
    if (( backed )); then bin_restore_prebak xray "$XRAY_BIN" xray "Xray" " 未通过校验"; fi
    bin_backup_drop "$XRAY_BIN"
    if (( BIN_BAK_SKIP_XRAY )); then die "Xray 未通过校验。剩余空间不足，没有备份可以恢复。"; fi
    die "Xray 未通过校验。"
  fi
  # 官方脚本会沿用已有 User=（常见为 xray）。配置是 root:nobody 组 640，必须在启动前改成 nobody。
  ensure_xray_runs_as_nobody "$XRAY_UNIT" || true
  bin_finish_install xray "$XRAY_BIN" "Xray" "$old"
  xray_geo_commit
}

# 不依赖 GitHub API，从 releases/latest 的跳转地址解析最新版本号（跟随仓库改名等多次跳转）
latest_tag() {
  curl -fsSIL "${FETCH_IP[@]}" --connect-timeout 10 -m 20 "https://github.com/$1/releases/latest" 2>/dev/null |
    awk -F'/tag/' 'tolower($0) ~ /^location:/ && NF > 1 {gsub(/[\r\n]/, "", $2); t=$2} END{if (t != "") print t}' || true
}
# 最新版本号：先 GitHub API，失败（限流 / 不可达）时改用 releases/latest 跳转
gh_latest_tag() {
  local t=""
  t=$(gh_curl -fsSL "${FETCH_IP[@]}" --connect-timeout 10 -m 20 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null) || t=""
  [[ -n $t ]] || t=$(latest_tag "$1")
  printf '%s' "$t"
}

# ============================================================
#          NAT 模式：直接下载官方二进制 + 自建 systemd / OpenRC 服务
# ============================================================
xray_asset_name() {
  case $ARCH in
    amd64) echo "Xray-linux-64.zip" ;;
    arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7) echo "Xray-linux-arm32-v7a.zip" ;;
  esac
}
hy_asset_name() {
  case $ARCH in
    amd64) echo "hysteria-linux-amd64" ;;
    arm64) echo "hysteria-linux-arm64" ;;
    armv7) echo "hysteria-linux-arm" ;;
  esac
}
github_hint() {
  warn "无法访问 GitHub。$( ((NO_V4)) && echo 'GitHub 不支持 IPv6，IPv6-only 机器请配置 DNS64/NAT64（重新运行并加 --dns64，或手动把 /etc/resolv.conf 改为 DNS64 服务器）。')"
}

install_xray_direct() {
  BIN_UPDATED_XRAY=0
  BIN_BAK_SKIP_XRAY=0
  step "安装 / 更新 Xray-core（直接下载 XTLS/Xray-core 官方 Release）"
  mktmp
  local tag="" dg="" old=""
  old=$(bin_version xray "$XRAY_BIN" || true)
  if [[ -n $OPT_XRAY_VER ]]; then
    tag=$(bin_norm_tag xray "$OPT_XRAY_VER") || die "Xray 版本号无效: ${OPT_XRAY_VER}（例如 v26.3.27）"
    gh_release_ok XTLS/Xray-core "$tag" || die "找不到 Xray 版本 ${tag}（GitHub 上没有这个发布，或网络不可达）。"
  else
    tag=$(gh_latest_tag XTLS/Xray-core)
    [[ -n $tag ]] || { github_hint; die "获取 Xray 最新版本号失败。"; }
  fi
  if xray_ver_same "$old" "$tag" && { (( NAT_MODE || LAND_MODE )) || [[ -f ${XRAY_ASSET_DIR}/geoip.dat ]]; }; then
    if [[ -n $OPT_XRAY_VER ]]; then ok "Xray 已是指定版本 ${tag}，跳过下载。"
    else ok "Xray 已是最新版本 ${tag}，跳过下载。"; fi
  else
    dg="${TMP_DIR}/xray-unzip"
    xray_fetch_release "$tag" "$dg"
    if ! xray_install_tree "$dg"; then
      rm -rf "$dg"
      die "下载的 Xray 未通过校验，未替换现有程序。"
    fi
    rm -rf "$dg"
  fi
  write_xray_service
  [[ -x $XRAY_BIN ]] || die "未找到 ${XRAY_BIN}，Xray 安装可能失败。"
}

install_hysteria_direct() {
  BIN_UPDATED_HY2=0
  BIN_BAK_SKIP_HY2=0
  step "安装 / 更新 Hysteria2（直接下载 apernet/hysteria 官方 Release）"
  mktmp
  local tag="" asset base cur="" want sum old="" replaced=0
  old=$(bin_version hy2 "$HY_BIN" || true)
  if [[ -n $OPT_HY2_VER ]]; then
    tag=$(bin_norm_tag hy2 "$OPT_HY2_VER") || die "Hysteria2 版本号无效: ${OPT_HY2_VER}（例如 v2.6.1 或 app/v2.6.1）"
    gh_release_ok apernet/hysteria "$tag" || die "找不到 Hysteria2 版本 ${tag}（GitHub 上没有这个发布，或网络不可达）。"
  else
    tag=$(gh_latest_tag apernet/hysteria)
    [[ -n $tag ]] || { github_hint; die "获取 Hysteria2 最新版本号失败。"; }
  fi
  cur=$old
  if hy_ver_same "$cur" "$tag"; then
    if [[ -n $OPT_HY2_VER ]]; then ok "Hysteria2 已是指定版本 $(hy_official_ver "$tag")，跳过下载。"
    else ok "Hysteria2 已是最新版本 ${tag#app/}，跳过下载。"; fi
  else
    asset=$(hy_asset_name)
    base="https://github.com/apernet/hysteria/releases/download/${tag}"
    info "下载 ${asset} (${tag#app/}) ..."
    fetch -o "${TMP_DIR}/${asset}" "${base}/${asset}" || { github_hint; die "下载 Hysteria2 失败。"; }
    if fetch -o "${TMP_DIR}/hy-hashes.txt" "${base}/hashes.txt" 2>/dev/null; then
      want=$(awk -v a="$asset" '{n=$2; sub(/^.*\//, "", n)} n==a {print tolower($1); exit}' "${TMP_DIR}/hy-hashes.txt")
      sum=$(sha256sum "${TMP_DIR}/${asset}" | awk '{print $1}')
      if [[ -n $want ]]; then
        [[ $want == "$sum" ]] || die "Hysteria2 SHA256 校验失败（期望 ${want}，实际 ${sum}），已中止。"
        ok "SHA256 校验通过。"
      else
        warn "hashes.txt 中未找到 ${asset}，跳过 SHA256 校验。"
      fi
    else
      warn "未能下载 hashes.txt，跳过 SHA256 校验。"
    fi
    chmod 755 "${TMP_DIR}/${asset}"
    # hysteria 没有配置检查命令，只确认临时文件能打出 version，再替换
    if ! hy_check_bin "${TMP_DIR}/${asset}"; then
      die "下载的 Hysteria2 未通过校验，未替换现有程序。"
    fi
    bin_backup "$HY_BIN" hy2
    install -m 755 "${TMP_DIR}/${asset}" "${HY_BIN}.new" && mv -f "${HY_BIN}.new" "$HY_BIN"
    replaced=1
  fi
  ensure_hy_user
  write_hy2_service
  if (( replaced )); then bin_finish_install hy2 "$HY_BIN" "Hysteria2" "$old"; fi
}

ensure_hy_user() {
  id hysteria >/dev/null 2>&1 && return 0
  if have useradd; then
    useradd -r -M -s "$(command -v nologin 2>/dev/null || echo /bin/false)" hysteria >/dev/null 2>&1 || true
  elif have adduser; then
    addgroup -S hysteria >/dev/null 2>&1 || true
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G hysteria hysteria >/dev/null 2>&1 || true
  fi
  id hysteria >/dev/null 2>&1 || warn "无法创建 hysteria 用户，将以 root 运行 Hysteria2。"
}

# 需要绑定 1024 以下端口时才申请 CAP_NET_BIND_SERVICE（老内核 / OpenVZ 不支持 ambient capabilities）
need_bind_cap() { (( ${1:-0} > 0 && ${1:-0} < 1024 )); }
# 1 = XHTTP 走 Vision 的同一个 TCP 端口（fallbacks），不再单独监听 8443
xhttp_shared() { (( ${XHTTP_ON_443:-0} == 1 && ${XHTTP_ENABLED:-0} == 1 && ${REALITY_ENABLED:-0} == 1 )); }
xhttp_fallback_prepare() {
  XHTTP_FB_DEST="" XHTTP_FB_LISTEN="" XHTTP_FB_PORT=0
  if [[ -d /dev/shm && -w /dev/shm ]]; then
    rm -f /dev/shm/xray-xhttp.sock
    XHTTP_FB_DEST="/dev/shm/xray-xhttp.sock"
    XHTTP_FB_LISTEN="/dev/shm/xray-xhttp.sock,0666"
    return 0
  fi
  local p=32768
  while (( p < 32820 )); do
    port_in_use tcp "$p" || break
    p=$(( p + 1 ))
  done
  (( p < 32820 )) || die "没有可用的本机回环端口给 XHTTP 回落。"
  XHTTP_FB_PORT=$p
  XHTTP_FB_DEST="127.0.0.1:${p}"
  XHTTP_FB_LISTEN="127.0.0.1"
}
xray_need_cap() {
  if (( ${LAND_MODE:-0} )); then need_bind_cap "$XRAY_PORT"; return; fi
  land_in_on && need_bind_cap "${LAND_PORT:-0}" && return 0
  (( ${REALITY_ENABLED:-1} )) && need_bind_cap "$XRAY_PORT" && return 0
  (( ${XHTTP_ENABLED:-0} )) && ! xhttp_shared && need_bind_cap "$XHTTP_PORT" && return 0
  (( ${TROJAN_ENABLED:-0} )) && need_bind_cap "$TROJAN_PORT" && return 0
  (( ${XHTTP_TLS_ENABLED:-0} )) && need_bind_cap "$XHTTP_TLS_PORT" && return 0
  (( ${WS_ENABLED:-0} )) && need_bind_cap "$WS_PORT" && return 0
  return 1
}
sb_needed() { (( ${TUIC_ENABLED:-0} || ${ANYTLS_ENABLED:-0} )); }

write_xray_service() {
  local envs; envs=$(go_mem_env)
  if is_openrc; then
    local sargs="--env XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}" e
    for e in $envs; do sargs+=" --env ${e}"; done
    cat >"$XRAY_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（NAT 模式）
name="xray"
description="Xray (proxy-oneclick)"
supervisor=supervise-daemon
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONF}"
command_user="nobody:$(id -gn nobody 2>/dev/null || echo nobody)"
output_log="${XRAY_LOG}"
error_log="${XRAY_LOG}"
respawn_delay=3
respawn_max=0
supervise_daemon_args="${sargs}"
$(xray_need_cap && echo 'capabilities="^cap_net_bind_service"')

depend() {
  want net
  after net firewall
}

start_pre() {
  checkpath -d -m 0755 -o "\${command_user}" /var/log/xray
  checkpath -f -m 0644 -o "\${command_user}" "${XRAY_LOG}"
  # 简单的日志大小控制：超过 2MB 时只保留最后 500 行
  if [ "\$(wc -c <"${XRAY_LOG}")" -gt 2097152 ]; then
    tail -n 500 "${XRAY_LOG}" >"${XRAY_LOG}.tmp" && cat "${XRAY_LOG}.tmp" >"${XRAY_LOG}"; rm -f "${XRAY_LOG}.tmp"
  fi
}
RC
    chmod 755 "$XRAY_RC"
  else
    rm -rf /etc/systemd/system/xray.service.d
    {
      echo "# 由 proxy-oneclick 生成（NAT 模式）"
      echo "[Unit]"
      echo "Description=Xray Service (proxy-oneclick)"
      echo "After=network-online.target nss-lookup.target"
      echo "Wants=network-online.target"
      echo
      echo "[Service]"
      echo "User=nobody"
      echo "NoNewPrivileges=true"
      if xray_need_cap; then
        echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      fi
      echo "Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}"
      local e; for e in $envs; do echo "Environment=${e}"; done
      echo "ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}"
      echo "Restart=on-failure"
      echo "RestartSec=3"
      echo "RestartPreventExitStatus=23"
      echo "LimitNOFILE=65535"
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } >"$XRAY_UNIT"
    systemctl daemon-reload
  fi
}

write_hy2_service() {
  local envs user="root" grp="root"; envs=$(go_mem_env)
  if id hysteria >/dev/null 2>&1; then user=hysteria; grp=$(id -gn hysteria); fi
  if is_openrc; then
    local sargs="--env HYSTERIA_LOG_LEVEL=warn --env HYSTERIA_DISABLE_UPDATE_CHECK=1" e
    for e in $envs; do sargs+=" --env ${e}"; done
    cat >"$HY_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（NAT 模式）
name="hysteria-server"
description="Hysteria2 server (proxy-oneclick)"
supervisor=supervise-daemon
command="${HY_BIN}"
command_args="server --config ${HY_CONF}"
command_user="${user}:${grp}"
directory="${HY_DIR}"
output_log="${HY_LOG}"
error_log="${HY_LOG}"
respawn_delay=3
respawn_max=0
supervise_daemon_args="${sargs}"
$(need_bind_cap "$HY2_PORT" && echo 'capabilities="^cap_net_bind_service"')

depend() {
  want net
  after net firewall proxy-oneclick-hop
}

start_pre() {
  checkpath -d -m 0755 -o "\${command_user}" /var/log/hysteria
  checkpath -f -m 0644 -o "\${command_user}" "${HY_LOG}"
  if [ "\$(wc -c <"${HY_LOG}")" -gt 2097152 ]; then
    tail -n 500 "${HY_LOG}" >"${HY_LOG}.tmp" && cat "${HY_LOG}.tmp" >"${HY_LOG}"; rm -f "${HY_LOG}.tmp"
  fi
}
RC
    chmod 755 "$HY_RC"
  else
    rm -rf /etc/systemd/system/hysteria-server.service.d
    {
      echo "# 由 proxy-oneclick 生成（NAT 模式）"
      echo "[Unit]"
      echo "Description=Hysteria2 Server (proxy-oneclick)"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      echo
      echo "[Service]"
      echo "User=${user}"
      echo "Group=${grp}"
      echo "WorkingDirectory=${HY_DIR}"
      echo "NoNewPrivileges=true"
      if need_bind_cap "$HY2_PORT"; then
        echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      fi
      echo "Environment=HYSTERIA_LOG_LEVEL=warn"
      echo "Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1"
      local e; for e in $envs; do echo "Environment=${e}"; done
      echo "ExecStart=${HY_BIN} server --config ${HY_CONF}"
      echo "Restart=on-failure"
      echo "RestartSec=3"
      echo "LimitNOFILE=65535"
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } >"$HY_UNIT"
    systemctl daemon-reload
  fi
}

gen_xray_keys() { # 生成/重新生成全部 Xray 密钥
  local out
  UUID=$("$XRAY_BIN" uuid)
  out=$("$XRAY_BIN" x25519)
  PRIV_KEY=$(awk -F': *' 'tolower($1) ~ /^private ?key/ {print $NF; exit}' <<<"$out")
  PUB_KEY=$(awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $NF; exit}' <<<"$out")
  [[ -n $PRIV_KEY && -n $PUB_KEY ]] || die "无法解析 xray x25519 输出。"
  SHORT_ID=$(rand_hex 4)
  MLDSA_SEED="" MLDSA_VERIFY=""
  if out=$("$XRAY_BIN" mldsa65 2>/dev/null); then
    MLDSA_SEED=$(awk -F': *' '$1=="Seed"{print $NF; exit}' <<<"$out")
    MLDSA_VERIFY=$(awk -F': *' '$1=="Verify"{print $NF; exit}' <<<"$out")
  fi
  if [[ -z $MLDSA_SEED || -z $MLDSA_VERIFY ]]; then
    MLDSA_SEED="" MLDSA_VERIFY=""
    warn "当前 Xray 版本不支持 mldsa65，已跳过后量子签名 (pqv)。"
  fi
}

xray_clients_json() { # $1 = flow（默认 xtls-rprx-vision；XHTTP 传空字符串）
  local flow=${1-xtls-rprx-vision} list
  list=$(jq -n --arg id "$UUID" --arg flow "$flow" '[{id:$id, flow:$flow, email:"main"}]')
  if [[ -s $USERS_FILE ]]; then
    local u r
    while IFS=$'\t' read -r u r; do
      [[ -n $u ]] || continue
      list=$(jq --arg id "$u" --arg e "$r" --arg flow "$flow" '. + [{id:$id, flow:$flow, email:$e}]' <<<"$list")
    done <"$USERS_FILE"
  fi
  printf '%s' "$list"
}

# ----------------------------- 出站地址族 -----------------------------
# 双栈（同时能用 IPv4 和 IPv6 出站）在写节点配置时询问一次：IPv4优先 / IPv6优先 / 仅IPv4 / 仅IPv6。
# 只有一种地址族时不询问，Xray 用 UseIPv4 或 UseIPv6。选择记在 OUTBOUND_IP，之后重配沿用。
# IPv4：默认路由的源地址不是回环 / 链路本地（NAT 内网地址算有 IPv4）。
# IPv6：全球单播（2000::/3）算有。fe80 和 ULA（fc00::/7）本身不算。
# 源地址只有 ULA 时再 curl -6：NAT66 会把 fc00::/7 转成公网 IPv6（例如 2600:1700::）。
# 探测到公网地址就按双栈，才能选「IPv6优先」。回显仍是 ULA 或探测失败，则当作没有 IPv6。
outbound_ipv4_ok() {
  local a=$1 o1 o2 o3 o4
  [[ $a =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  o1=$((10#${BASH_REMATCH[1]})) o2=$((10#${BASH_REMATCH[2]})) o3=$((10#${BASH_REMATCH[3]})) o4=$((10#${BASH_REMATCH[4]}))
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
  (( o1 == 0 || o1 == 127 )) && return 1
  (( o1 == 169 && o2 == 254 )) && return 1
  return 0
}
outbound_ipv6_global() { # 2000::/3；排除 ::1、fe80::/10、ULA fc00::/7
  local a=${1,,}
  [[ $a == *:* ]] || return 1
  [[ $a == ::1 || $a == fe80:* || $a == fc* || $a == fd* ]] && return 1
  [[ $a == [23]* ]]
}
outbound_ipv6_ula() { # fc00::/7。fe80 不是 ULA。
  local a=${1,,}
  [[ $a == *:* ]] || return 1
  [[ $a == fc* || $a == fd* ]]
}
# $1 为文本地址，或 /proc/net/if_inet6 的 32 位十六进制。只置位，不清除。
outbound_note_v6_token() {
  local a=${1,,}
  a=${a%%%*}
  a=${a%%/*}
  if [[ $a == *:* ]]; then
    if outbound_ipv6_global "$a"; then OB_HAS_V6=1
    elif outbound_ipv6_ula "$a"; then OB_HAS_ULA=1
    fi
    return 0
  fi
  # /proc/net/if_inet6 固定 32 位十六进制。短字符串（例如误传入的 IPv4）不算。
  [[ $a =~ ^[0-9a-f]{32}$ ]] || return 0
  if [[ $a == [23]* ]]; then OB_HAS_V6=1
  elif [[ $a == fc* || $a == fd* ]]; then OB_HAS_ULA=1
  fi
  return 0
}
outbound_ipv6_probe_public() { # 打印公网 IPv6；没有则空。curl 失败也返回 0，避免 set -e 中断。
  local u ip=""
  if ! have curl; then
    printf ''
    return 0
  fi
  for u in https://api64.ipify.org https://ipv6.icanhazip.com https://6.ipw.cn; do
    ip=$(curl -6 -fsS --connect-timeout 4 -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
    if outbound_ipv6_global "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  printf ''
  return 0
}
outbound_consider_nat66() { # 只有 ULA、没有全球单播源时才探测，避免无 IPv6 的机器白等。
  local pub=""
  if (( OB_HAS_V6 || ! OB_HAS_ULA )); then return 0; fi
  pub=$(outbound_ipv6_probe_public) || pub=""
  if outbound_ipv6_global "$pub"; then
    OB_HAS_V6=1
    OB_NAT66=1
    OB_NAT66_PUB=${pub,,}
    OB_NAT66_PUB=${OB_NAT66_PUB%%%*}
  fi
  return 0
}
outbound_detect_families_ip() {
  local s4="" s6=""
  s4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || s4=""
  s6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || s6=""
  if outbound_ipv4_ok "$s4"; then OB_HAS_V4=1; fi
  if [[ -n $s6 ]]; then
    outbound_note_v6_token "$s6"
    if outbound_ipv6_ula "$s6"; then OB_ULA_SRC=${s6%%%*}; OB_ULA_SRC=${OB_ULA_SRC,,}; fi
  fi
  return 0
}
outbound_detect_families_proc() {
  local a
  if awk 'NR>1 && $2=="00000000" && $1!="lo" {found=1} END{exit !found}' /proc/net/route 2>/dev/null; then
    while IFS= read -r a; do
      if outbound_ipv4_ok "$a"; then OB_HAS_V4=1; break; fi
    done < <(awk '/32 host LOCAL/{print prev} {prev=$2}' /proc/net/fib_trie 2>/dev/null)
  fi
  if awk '$1=="00000000000000000000000000000000" && $2=="00" && $NF!="lo" {found=1} END{exit !found}' /proc/net/ipv6_route 2>/dev/null; then
    while IFS= read -r a; do
      outbound_note_v6_token "$a"
      if (( OB_HAS_V6 )); then break; fi
    done < <(awk '{print $1}' /proc/net/if_inet6 2>/dev/null)
  fi
  return 0
}
outbound_detect_families() {
  OB_HAS_V4=0
  OB_HAS_V6=0
  OB_HAS_ULA=0
  OB_ULA_SRC=""
  OB_NAT66=0
  OB_NAT66_PUB=""
  if have ip; then outbound_detect_families_ip; else outbound_detect_families_proc; fi
  outbound_consider_nat66
  return 0
}
xray_domain_strategy() {
  case ${OUTBOUND_EFFECTIVE:-} in
    46) printf '%s' UseIPv4v6 ;;
    64) printf '%s' UseIPv6v4 ;;
    4) printf '%s' UseIPv4 ;;
    6) printf '%s' UseIPv6 ;;
    *) printf '%s' "" ;;
  esac
}
hy2_direct_mode() {
  case ${OUTBOUND_EFFECTIVE:-} in
    46|64|4|6) printf '%s' "$OUTBOUND_EFFECTIVE" ;;
    *) printf '%s' "" ;;
  esac
}
hy2_outbound_name() {
  case $1 in
    46) printf '%s' ipv4-first ;;
    64) printf '%s' ipv6-first ;;
    4) printf '%s' ipv4-only ;;
    6) printf '%s' ipv6-only ;;
    *) printf '%s' direct ;;
  esac
}
sb_ip_strategy() {
  case ${OUTBOUND_EFFECTIVE:-} in
    46) printf '%s' prefer_ipv4 ;;
    64) printf '%s' prefer_ipv6 ;;
    4) printf '%s' ipv4_only ;;
    6) printf '%s' ipv6_only ;;
    *) printf '%s' "" ;;
  esac
}
# sing-box 1.12 起 domain_strategy 废弃，1.14 移除；新版本用 domain_resolver.strategy
sb_resolver_is_new() {
  local v
  [[ -x $SB_BIN ]] || return 0
  v=$("$SB_BIN" version 2>/dev/null | awk 'NR==1{print $NF}') || v=""
  v=${v#v}
  [[ $v =~ ^[0-9] ]] || return 0
  ver_ge "$v" "1.12.0"
}
outbound_can_ask() { [[ -t 0 || -r /dev/tty ]]; }
outbound_apply_code() { # 与已保存的值相同则不标记改动，避免每次重配都写 state.env
  local code=$1
  OUTBOUND_EFFECTIVE=$code
  if [[ ${OUTBOUND_IP:-} != "$code" ]]; then
    OUTBOUND_IP=$code
    OUTBOUND_IP_CHANGED=1
  fi
}
outbound_label() {
  case ${1:-} in
    46) printf '%s' 'IPv4优先' ;;
    64) printf '%s' 'IPv6优先' ;;
    4) printf '%s' '仅IPv4' ;;
    6) printf '%s' '仅IPv6' ;;
    auto) printf '%s' '自动' ;;
    *) printf '%s' '未指定' ;;
  esac
}
outbound_ask() {
  local c def=1
  if (( OB_NAT66 )); then
    echo "   出站地址（IPv4 可用；IPv6 经 NAT66 到 ${OB_NAT66_PUB}。只影响代理出站，不会关闭系统 IPv6）："
  else
    echo "   出站地址（本机同时有 IPv4 和 IPv6；只影响代理出站，不会关闭系统 IPv6）："
  fi
  echo "     1) IPv4优先"
  echo "     2) IPv6优先"
  echo "     3) 仅IPv4"
  echo "     4) 仅IPv6"
  while :; do
    ask c "请选择" "$def"
    case $c in
      1) outbound_apply_code 46; break ;;
      2) outbound_apply_code 64; break ;;
      3) outbound_apply_code 4; break ;;
      4) outbound_apply_code 6; break ;;
      *) warn "请输入 1-4。" ;;
    esac
  done
}
outbound_use_saved_or_default() { # 双栈或检测不到时：沿用已保存的选择；--auto 且未保存则 IPv4优先
  if [[ $OUTBOUND_IP =~ ^(46|64|4|6)$ ]]; then
    OUTBOUND_EFFECTIVE=$OUTBOUND_IP
    return 0
  fi
  if (( OPT_AUTO )); then
    outbound_apply_code 46
    info "自动模式：出站使用 IPv4优先。"
    return 0
  fi
  # proxy outbound（不带策略）只查看，不在这里询问。安装和 proxy outbound auto 仍询问。
  if (( OB_HAS_V4 && OB_HAS_V6 )) && [[ ${OUTBOUND_NO_ASK:-0} != 1 ]] && outbound_can_ask; then
    outbound_ask
    return 0
  fi
  # 还没问过，且这次不能问：保持原行为（Xray AsIs，Hy2 不写出站 mode）
  OUTBOUND_EFFECTIVE=""
}
outbound_warn_missing_family() { # 显式 --outbound 与检测结果冲突时只警告，仍按用户的选择写
  case $1 in
    64|6)
      if (( ! OB_HAS_V6 )); then
        warn "检测不到 IPv6 出站，仍按 $(outbound_label "$1") 写入。若客户端连不上，改回 46 或 4。"
      fi
      ;;
    46|4)
      if (( ! OB_HAS_V4 )); then
        warn "检测不到 IPv4 出站，仍按 $(outbound_label "$1") 写入。若客户端连不上，改回 64 或 6。"
      fi
      ;;
  esac
  return 0
}
ensure_outbound_ip() {
  (( OUTBOUND_IP_DONE )) && return 0
  OUTBOUND_IP_DONE=1
  OUTBOUND_IP_CHANGED=0
  outbound_detect_families
  if (( OB_NAT66 )); then
    if [[ -n $OB_ULA_SRC ]]; then
      info "IPv6 源地址是内网 ${OB_ULA_SRC}，探测到 NAT66 公网 ${OB_NAT66_PUB}，IPv6 出站可用。"
    else
      info "IPv6 源地址是内网 ULA，探测到 NAT66 公网 ${OB_NAT66_PUB}，IPv6 出站可用。"
    fi
  fi
  if [[ ${OPT_OUTBOUND:-} =~ ^(46|64|4|6)$ ]]; then
    outbound_apply_code "$OPT_OUTBOUND"
    outbound_warn_missing_family "$OPT_OUTBOUND"
    info "出站使用 $(outbound_label "$OPT_OUTBOUND")。"
    if (( OUTBOUND_IP_CHANGED )); then save_state; fi
    return 0
  fi
  if [[ ${OPT_OUTBOUND:-} == auto ]]; then
    if [[ -n ${OUTBOUND_IP:-} ]]; then
      OUTBOUND_IP=""
      OUTBOUND_IP_CHANGED=1
    fi
    OUTBOUND_EFFECTIVE=""
  fi
  if (( OB_HAS_V4 && ! OB_HAS_V6 )); then
    OUTBOUND_EFFECTIVE=4
    info "本机只有 IPv4，出站使用仅IPv4。"
  elif (( OB_HAS_V6 && ! OB_HAS_V4 )); then
    OUTBOUND_EFFECTIVE=6
    info "本机只有 IPv6，出站使用仅IPv6。"
  else
    outbound_use_saved_or_default
  fi
  if (( OUTBOUND_IP_CHANGED )); then save_state; fi
  return 0
}
outbound_print_status() {
  local fam="未检测到" pol
  if (( OB_HAS_V4 && OB_HAS_V6 )); then
    if (( OB_NAT66 )); then
      if [[ -n $OB_ULA_SRC ]]; then
        fam="双栈（本机 ${OB_ULA_SRC} 经 NAT66 到 ${OB_NAT66_PUB}）"
      else
        fam="双栈（内网 ULA 经 NAT66 到 ${OB_NAT66_PUB}）"
      fi
    else
      fam="双栈"
    fi
  elif (( OB_HAS_V4 )); then
    fam="只有 IPv4"
  elif (( OB_HAS_V6 )); then
    fam="只有 IPv6"
  fi
  if [[ -n ${OUTBOUND_EFFECTIVE:-} ]]; then pol=$(outbound_label "$OUTBOUND_EFFECTIVE")
  else pol="未指定"
  fi
  echo "出站检测: ${fam}"
  echo "出站策略: ${pol}"
  if (( OB_HAS_V4 && OB_HAS_V6 )) && [[ -z ${OUTBOUND_EFFECTIVE:-} ]]; then
    echo "设置: proxy outbound 46|64|4|6|auto"
  fi
  return 0
}
outbound_apply_installed() { # 已安装时按当前策略重写配置。未安装的调用方不要进来。
  (( INSTALLED )) || return 0
  local did=0
  # 原样转发不经过 Xray。换出站策略时按同一策略重选 DNAT 目标。
  # 纯落地机会停掉 Xray。节点上的落地入站只让出 LAND_PORT，其它入站继续跑。
  if land_raw_active; then
    land_fwd_check
    land_fwd_install
    did=1
    info "原样转发已按 $(outbound_label "${OUTBOUND_EFFECTIVE:-}") 重选目标。"
    if land_only; then return 0; fi
  fi
  # 落地机也走这里。不要调用 need_node：落地机没有 Reality / Hysteria2，need_node 会直接拒绝。
  if [[ -x $XRAY_BIN ]] && { [[ -f $XRAY_CONF ]] || (( LAND_MODE )); }; then
    write_xray_config || die "重写 Xray 出站策略失败。"
    restart_xray
    did=1
  fi
  if (( ! LAND_MODE )); then
    if (( ${HY2_ENABLED:-0} )) && [[ -f $HY_CONF && -x $HY_BIN ]]; then
      write_hy2_config || die "重写 Hysteria2 出站策略失败。"
      restart_hy2
      did=1
    fi
    if sb_needed && [[ -f $SB_CONF && -x $SB_BIN ]]; then
      write_singbox_config || die "重写 sing-box 出站策略失败。"
      restart_singbox
      did=1
    fi
  fi
  if (( ! did )); then
    info "已记住出站策略。当前没有可更新的节点配置，下次重写配置时生效。"
  fi
  return 0
}
do_outbound() {
  if [[ -f $STATE_FILE ]]; then load_state; fi
  step "出站地址"
  OUTBOUND_IP_DONE=0
  # 不带 46|64|4|6|auto 时只查看。带 auto 表示清掉旧选择后按检测（双栈且有终端则询问）。
  if [[ -z ${OPT_OUTBOUND:-} ]]; then OUTBOUND_NO_ASK=1; else OUTBOUND_NO_ASK=0; fi
  ensure_outbound_ip
  OUTBOUND_NO_ASK=0
  outbound_print_status
  if [[ -n ${OPT_OUTBOUND:-} ]] || (( OUTBOUND_IP_CHANGED )); then
    if (( INSTALLED )); then
      outbound_apply_installed
    else
      info "尚未安装节点。这个选择会在安装时写入。"
    fi
  fi
  return 0
}
xray_apply_ip_strategy() { # $1 临时配置。未选择时不改（freedom 无 domainStrategy，routing 保持 AsIs）
  local ds f=$1
  ds=$(xray_domain_strategy)
  [[ -n $ds ]] || return 0
  jq --arg ds "$ds" '
    .routing.domainStrategy = $ds
    | .outbounds |= map(
        if .tag == "direct" and .protocol == "freedom"
        then .settings.domainStrategy = $ds
        else . end)
  ' "$f" >"${f}.ip" && mv -f "${f}.ip" "$f"
}
hy2_outbound_yaml() { # 无落地转发时追加。Hy2 是静态 Go 程序，只用 direct.mode，不改系统解析
  local mode name
  mode=$(hy2_direct_mode)
  [[ -n $mode ]] || return 0
  name=$(hy2_outbound_name "$mode")
  cat <<HY

outbounds:
  - name: ${name}
    type: direct
    direct:
      mode: ${mode}
HY
}
singbox_apply_ip_strategy() { # $1 临时配置。TUIC / AnyTLS 走 sing-box 的同一选择
  local st f=$1
  st=$(sb_ip_strategy)
  [[ -n $st ]] || return 0
  if sb_resolver_is_new; then
    jq --arg st "$st" '
      .dns = {servers: [{type: "local", tag: "local"}]}
      | .outbounds |= map(
          if .tag == "direct" and .type == "direct"
          then .domain_resolver = {server: "local", strategy: $st}
          else . end)
    ' "$f" >"${f}.ip" && mv -f "${f}.ip" "$f"
  else
    jq --arg st "$st" '
      .outbounds |= map(
          if .tag == "direct" and .type == "direct"
          then .domain_strategy = $st
          else . end)
    ' "$f" >"${f}.ip" && mv -f "${f}.ip" "$f"
  fi
}

# NAT 模式不下载 geoip.dat：直接列出内网 / 保留地址段
PRIV_NETS_JSON='["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/3","::/127","fc00::/7","fe80::/10","ff00::/8"]'

# 配置只给服务进程读：root 拥有，该用户主组 640。
own_svc_config() { # $1 文件 $2 运行用户
  local f=$1 user=$2 grp=root
  if id "$user" >/dev/null 2>&1; then
    grp=$(id -gn "$user")
  elif [[ $user == nobody ]]; then
    grp=nogroup
  fi
  chown "root:${grp}" "$f" || die "无法设置 ${f} 的属主，${user} 将读不到配置。"
  chmod 640 "$f" || die "无法设置 ${f} 的权限。"
}
xray_unit_user() { # $1 unit。没有 User= 时按 nobody（与自建服务一致）。
  local unit=${1:-$XRAY_UNIT} u=""
  [[ -f $unit ]] || { printf '%s' nobody; return 0; }
  u=$(sed -n -E 's/^[[:space:]]*User[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$unit" | tail -n 1)
  [[ -n $u ]] || u=nobody
  printf '%s' "$u"
}
# 普通模式官方 xray.service 会留下或沿用 User=xray。配置若仍是 nobody 组，xray 读不到。
# 成功时运行用户为 nobody（返回 0）。系统没有 nobody 时不改 unit，返回 1，调用方按实际 User= 授权。
ensure_xray_runs_as_nobody() { # 可选 $1 unit $2 drop-in
  direct_mode && return 0
  is_openrc && return 0
  local unit=${1:-$XRAY_UNIT}
  local drop=${2:-/etc/systemd/system/xray.service.d/zz-proxy-oneclick-user.conf}
  [[ -f $unit ]] || return 0
  id nobody >/dev/null 2>&1 || return 1
  local grp changed=0 want have=""
  grp=$(id -gn nobody)
  mkdir -p "$(dirname "$drop")" || die "无法创建 Xray 服务目录：$(dirname "$drop")"
  want="# 由 proxy-oneclick 生成：配置为 root:${grp} 640，进程必须是 nobody
[Service]
User=nobody
Group=${grp}"
  [[ -f $drop ]] && have=$(<"$drop")
  if [[ $have != "$want" ]]; then
    printf '%s\n' "$want" >"$drop" || die "无法写入 Xray 服务用户覆盖：${drop}"
    changed=1
  fi
  if grep -qE '^[[:space:]]*User[[:space:]]*=' "$unit" && ! grep -qE '^[[:space:]]*User[[:space:]]*=[[:space:]]*nobody[[:space:]]*$' "$unit"; then
    sed -i -E 's/^[[:space:]]*User[[:space:]]*=.*/User=nobody/' "$unit" || die "无法把 Xray 服务用户改为 nobody。"
    changed=1
  fi
  if grep -qE '^[[:space:]]*Group[[:space:]]*=' "$unit"; then
    local gcur
    gcur=$(sed -n -E 's/^[[:space:]]*Group[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$unit" | tail -n 1)
    if [[ $gcur != "$grp" ]]; then
      sed -i -E "s/^[[:space:]]*Group[[:space:]]*=.*/Group=${grp}/" "$unit" || die "无法把 Xray 服务组改为 ${grp}。"
      changed=1
    fi
  fi
  if (( changed )) && [[ $unit == "$XRAY_UNIT" ]] && have systemctl && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  return 0
}
write_xray_config() {
  local clients tmp seed="" cplain tclients
  clients=$(xray_clients_json)
  cplain=$(xray_clients_json "")
  tclients=$(jq -n --arg p "${TROJAN_PASS:-}" '[{password:$p, email:"main"}]')
  pqv_active && seed=$MLDSA_SEED
  mkdir -p "$(dirname "$XRAY_CONF")"
  tmp=$(mktemp "$(dirname "$XRAY_CONF")/.config.XXXXXX"); mv -f "$tmp" "${tmp}.json"; tmp="${tmp}.json"
  if (( LAND_MODE )); then
    ensure_outbound_ip
    land_xray_json >"$tmp" || die "生成落地机 Xray 配置失败。"
  else
  ensure_outbound_ip
  local share=0
  if xhttp_shared; then share=1; xhttp_fallback_prepare; fi
  jq -n \
    --argjson port "$XRAY_PORT" --argjson clients "$clients" --argjson cplain "$cplain" --argjson tclients "$tclients" \
    --argjson reality "${REALITY_ENABLED:-0}" --argjson xhttp "${XHTTP_ENABLED:-0}" --argjson trojan "${TROJAN_ENABLED:-0}" \
    --argjson xport "${XHTTP_PORT:-0}" --argjson tport "${TROJAN_PORT:-0}" --arg xpath "${XHTTP_PATH:-/xhttp}" \
    --arg target "${SNI_TARGET:-$SNI:443}" --arg sni "$SNI" \
    --arg priv "$PRIV_KEY" --arg sid "$SHORT_ID" --arg seed "$seed" --argjson nat "${NAT_MODE:-0}" --argjson privnets "$PRIV_NETS_JSON" \
    --argjson share "$share" --arg fbdest "${XHTTP_FB_DEST:-}" --arg fblisten "${XHTTP_FB_LISTEN:-}" --argjson fbport "${XHTTP_FB_PORT:-0}" '
  def reality: {
    show: false, target: $target, xver: 0,
    serverNames: [$sni], privateKey: $priv, shortIds: [$sid]
  } + (if $seed != "" then {mldsa65Seed: $seed} else {} end);
  def sniff: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true};
  {
    log: ({loglevel: "warning"} + (if $nat == 1 then {access: "none"} else {} end)),
    inbounds: (
      []
      + (if $reality == 1 then [{
          tag: "vless-reality", port: $port, protocol: "vless",
          settings: ({clients: $clients, decryption: "none"}
            + (if $share == 1 then {fallbacks: [{dest: $fbdest, xver: 0}]} else {} end)),
          streamSettings: {network: "raw", security: "reality", realitySettings: reality},
          sniffing: sniff
        }] else [] end)
      + (if $xhttp == 1 then
          if $share == 1 then
            [(if $fbport == 0 then {
                tag: "vless-xhttp", listen: $fblisten, protocol: "vless",
                settings: {clients: $cplain, decryption: "none"},
                streamSettings: {
                  network: "xhttp", security: "none",
                  xhttpSettings: {path: $xpath, mode: "stream-one"}
                },
                sniffing: sniff
              } else {
                tag: "vless-xhttp", listen: $fblisten, port: $fbport, protocol: "vless",
                settings: {clients: $cplain, decryption: "none"},
                streamSettings: {
                  network: "xhttp", security: "none",
                  xhttpSettings: {path: $xpath, mode: "stream-one"}
                },
                sniffing: sniff
              } end)]
          else [{
          tag: "vless-xhttp", port: $xport, protocol: "vless",
          settings: {clients: $cplain, decryption: "none"},
          streamSettings: {
            network: "xhttp", security: "reality",
            xhttpSettings: {path: $xpath, mode: "stream-one"},
            realitySettings: reality
          },
          sniffing: sniff
        }] end
        else [] end)
      + (if $trojan == 1 then [{
          tag: "trojan-reality", port: $tport, protocol: "trojan",
          settings: {clients: $tclients},
          streamSettings: {network: "raw", security: "reality", realitySettings: reality},
          sniffing: sniff
        }] else [] end)
    ),
    outbounds: [
      {tag: "direct", protocol: "freedom"},
      {tag: "block", protocol: "blackhole"}
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: [
        {type: "field", ip: (if $nat == 1 then $privnets else ["geoip:private"] end), outboundTag: "block"},
        {type: "field", protocol: ["bittorrent"], outboundTag: "block"}
      ]
    }
  }' >"$tmp"
    if ! cdn_attach_inbounds "$tmp" "$cplain"; then
      rm -f "$tmp" "${tmp}.cdn"
      return 1
    fi
    # 落地入站的规则必须写在 land-add 兜底之前，ss-in 才不会被送进本机中转。
    land_in_attach "$tmp"
    relay_inject "$tmp"   # 中转机：落地出站（保存在状态文件中，每次重新生成配置都会重新加入）
    if [[ $(jq '.inbounds | length' "$tmp") == 0 ]]; then
      rm -f "$tmp"
      return 2
    fi
  fi
  if (( ! LAND_MODE )); then ensure_outbound_ip; fi
  xray_apply_ip_strategy "$tmp" || die "写入 Xray 出站地址族失败。"
  if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -config "$tmp" >"${tmp}.log" 2>&1; then
    cat "${tmp}.log" >&2
    if cdn_wanted; then
      cdn_explain xray_config
    fi
    rm -f "$tmp" "${tmp}.log"
    die "Xray 配置校验失败（xray run -test），未应用新配置。"
  fi
  rm -f "${tmp}.log"
  # 普通模式先把官方 unit 固定为 nobody，再按实际运行用户授权（NAT / 落地机 / Alpine 的 unit 已是 nobody）。
  local xu=nobody
  if ! ensure_xray_runs_as_nobody "$XRAY_UNIT"; then
    xu=$(xray_unit_user "$XRAY_UNIT")
    warn "系统没有 nobody 用户，已按 Xray 服务用户 ${xu} 设置配置权限。"
  fi
  own_svc_config "$tmp" "$xu"
  if [[ -f $XRAY_CONF ]]; then mkdir -p "$BACKUP_DIR"; cp -a "$XRAY_CONF" "${BACKUP_DIR}/xray-config.json.bak" 2>/dev/null || true; fi
  mv -f "$tmp" "$XRAY_CONF"
  selinux_fix "$(dirname "$XRAY_CONF")"
  ok "Xray 配置已生成并通过校验: ${XRAY_CONF}"
}

restart_xray() {
  # 纯落地机的原样转发：停掉 Xray，把端口留给 DNAT。
  # 节点同时开着落地入站时不能停 Xray，只是配置里不监听 LAND_PORT。
  if land_only && land_raw_active; then
    BIN_UPDATED_XRAY=0
    svc_disable_stop xray
    ok "原样转发中：Xray 已停止，不监听 ${XRAY_PORT}（对外端口 $(pub_xray_port)）。"
    return 0
  fi
  sd_reload
  svc_enable xray
  svc_restart xray || true
  sleep 1
  if ! svc_active xray; then
    svc_logs xray 20 >&2 || true
    local rc=0
    bin_restart_failed xray "$XRAY_BIN" xray "Xray" || rc=$?
    if (( rc == 0 )); then die "Xray 更新后没有跑起来，已恢复备份。"
    elif (( rc == 2 )); then die "Xray 更新后没有跑起来，恢复备份后仍未运行。"
    fi
    die "Xray 启动失败，请查看上方日志。"
  fi
  BIN_UPDATED_XRAY=0
  if (( LAND_MODE )); then
    ok "Xray 运行中 (Shadowsocks 2022 TCP+UDP ${XRAY_PORT}$( ((NAT_MODE)) && [[ $XRAY_EXT_PORT != "$XRAY_PORT" ]] && echo "，外部端口 ${XRAY_EXT_PORT}"))"
  elif land_in_on && ! land_raw_active; then
    ok "Xray 运行中 ($(proto_xray_brief)；落地 SS2022 TCP+UDP $(land_listen_port))"
  else
    ok "Xray 运行中 ($(proto_xray_brief))"
  fi
}

selinux_fix() {
  have selinuxenabled && selinuxenabled 2>/dev/null || return 0
  if have restorecon; then restorecon -R "$@" >/dev/null 2>&1 || true; fi
}

