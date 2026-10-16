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
  src/cli.sh
)

for f in "${files[@]}"; do
  [[ -f $f ]] || { printf '缺少模块: %s\n' "$f" >&2; exit 1; }
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat "${files[@]}" >"$tmp"
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
