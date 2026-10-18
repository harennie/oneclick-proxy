#!/usr/bin/env bash
# 把 src/ 按固定顺序拼成仓库根目录的 proxy.sh。
# 顺序写死，不用通配符排序，保证每次结果一致。
set -euo pipefail
cd "$(dirname "$0")"

files=(
  src/core.sh
  src/os.sh
  src/tune.sh
  src/xray.sh
  src/hy2.sh
  src/firewall.sh
  src/cert.sh
  src/cdn.sh
  src/link.sh
  src/singbox.sh
  src/nat.sh
  src/selftest.sh
  src/land.sh
  src/menu.sh
  src/route.sh
  src/export.sh
  src/doctor.sh
  src/cli.sh
)

for f in "${files[@]}"; do
  [[ -f $f ]] || { printf '缺少模块: %s\n' "$f" >&2; exit 1; }
done

# 每个模块前加一行 # @module，并在 src/core.sh 的占位符里写入起始行对照。
# 对照是单行替换，不会把后面的行号挤开。core.sh 的 shebang 仍是第 1 行。
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
map=""
out_line=1
add_map() { # $1 生成文件行号 $2 源文件 $3 源文件行号
  local ent="$1:$2:$3"
  if [[ -n $map ]]; then map+=";${ent}"; else map=$ent; fi
}
idx=0
for f in "${files[@]}"; do
  lines=$(wc -l <"$f" | tr -d ' ')
  if (( idx == 0 )); then
    head -n 1 "$f" >>"$tmp"
    add_map 1 "$f" 1
    printf '# @module %s\n' "$f" >>"$tmp"
    add_map 3 "$f" 2
    tail -n +2 "$f" >>"$tmp"
    out_line=$(( lines + 2 ))
  else
    printf '# @module %s\n' "$f" >>"$tmp"
    out_line=$(( out_line + 1 ))
    add_map "$out_line" "$f" 1
    cat "$f" >>"$tmp"
    out_line=$(( out_line + lines ))
  fi
  idx=$(( idx + 1 ))
done
placeholder='readonly __MODULE_MAP="__BUILD_MODULE_MAP__"'
if [[ $(grep -cF "$placeholder" "$tmp") -ne 1 ]]; then
  printf 'src/core.sh 里的模块映射占位符必须恰好一行。\n' >&2
  exit 1
fi
awk -v map="$map" -v old="$placeholder" '
  $0 == old { print "readonly __MODULE_MAP=\"" map "\""; next }
  { print }
' "$tmp" >"${tmp}.map"
mv -f "${tmp}.map" "$tmp"
if grep -q '^readonly __MODULE_MAP="__BUILD_MODULE_MAP__"$' "$tmp"; then
  printf '模块映射没有写进生成结果。\n' >&2
  exit 1
fi
chmod 755 "$tmp"

if [[ ${1-} == --check ]]; then
  if ! cmp -s "$tmp" proxy.sh; then
    printf 'proxy.sh 与 src/ 拼出来的结果不一致。请运行 ./build.sh 后提交。\n' >&2
    diff -u proxy.sh "$tmp" | head -n 80 >&2 || true
    exit 1
  fi
  exit 0
fi

if [[ $# -gt 0 ]]; then
  printf '用法: ./build.sh [--check]\n' >&2
  exit 1
fi

cat "$tmp" >proxy.sh
chmod 755 proxy.sh
printf '已生成 proxy.sh（%s 字节）\n' "$(wc -c <proxy.sh | tr -d ' ')"
