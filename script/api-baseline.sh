#!/bin/bash
# 导出/比对公共 API 基线。
#
# 项目明确不承诺旧 API 向后兼容（见 README「版本策略」），因此 CI 不做“破坏即失败”，
# 而是在发布前生成一份人类可读的变更清单，让宿主一眼看到需要改哪些调用点。
#
# 用法：
#   script/api-baseline.sh dump           # 输出当前公共 API 到 stdout
#   script/api-baseline.sh check <file>   # 与基线文件比对，列出新增/移除/变更
#
# 实现说明：使用 SwiftPM 的 symbol graph（不需要额外工具链）导出各产品模块的公共符号，
# 只保留影响调用方的字段（模块、种类、名称），保证输出稳定、可 diff。
#
# 退出码：0 无变化或仅新增；2 存在移除或签名变更；1 参数/环境错误。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# 被分析源码的根目录。CI 比对旧标签时会传入临时工作树路径，
# 因此不能假设它等于脚本所在的仓库。
SOURCE_ROOT="${BRSK_SOURCE_ROOT:-$REPO_ROOT}"
cd "$SOURCE_ROOT"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/brsk-api.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

dump_api() {
    # 一次性构建 symbol graph；--minimum-access-level public 只保留公共 API。
    swift build --build-path "$SCRATCH/build" >/dev/null 2>&1
    local symbols="$SCRATCH/symbols.txt"
    : > "$symbols"
    # symbolgraph-extract 不会自动创建输出目录，必须预先建好。
    mkdir -p "$SCRATCH/sg"
    # 必须显式提供 SDK 与 target，否则找不到 Swift 标准库模块（Swift、_Concurrency 等）。
    local sdk
    sdk="$(xcrun --show-sdk-path)"
    local target_triple
    target_triple="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')"
    # 目标模块从被分析源码的 Package.swift 解析：旧标签可能没有 Transfer/Catalog 等模块，
    # 写死列表会在比对历史版本时失败。
    local targets
    targets="$(swift package describe --type json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
names = [t["name"] for t in data["targets"] if t["type"] != "test"]
for name in sorted(names):
    if name.startswith("BoneRemoteSync"):
        print(name)
')"
    [ -n "$targets" ] || { echo "无法从 Package.swift 解析出模块列表" >&2; return 1; }
    local target
    for target in $targets; do
        xcrun swift symbolgraph-extract \
            -module-name "$target" \
            -I "$SCRATCH/build/debug" \
            -sdk "$sdk" \
            -target "$target_triple" \
            -minimum-access-level public \
            -output-dir "$SCRATCH/sg" || {
                echo "symbolgraph-extract 失败：$target" >&2
                return 1
            }
    done
    # 归一化：模块 + 符号种类 + 精确标识符，按字典序排列，去掉无关的文档与位置信息。
    python3 - "$SCRATCH/sg" <<'PY' >> "$symbols"
import glob, json, sys
rows = []
for path in glob.glob(sys.argv[1] + "/*.symbols.json"):
    data = json.load(open(path, encoding="utf-8"))
    module = data["module"]["name"]
    for symbol in data.get("symbols", []):
        rows.append(f'{module}\t{symbol["kind"]["identifier"]}\t{symbol["identifier"]["precise"]}')
for row in sorted(set(rows)):
    print(row)
PY
    cat "$symbols"
}

case "${1:-dump}" in
    dump)
        dump_api
        ;;
    check)
        baseline="${2:-}"
        [ -n "$baseline" ] || { echo "用法：script/api-baseline.sh check <基线文件>" >&2; exit 1; }
        [ -f "$baseline" ] || { echo "基线不存在：$baseline" >&2; exit 1; }
        current="$SCRATCH/current.txt"
        dump_api > "$current"
        # 用 Python 做集合差而不是 comm：行内含有制表符，comm 会按字段切分导致误判。
        python3 - "$baseline" "$current" "$SCRATCH/added.txt" "$SCRATCH/removed.txt" <<'PY'
import io, sys
base_path, cur_path, added_path, removed_path = sys.argv[1:5]
def load(path):
    with io.open(path, encoding="utf-8") as handle:
        return {line.rstrip("\n") for line in handle if line.strip()}
base, cur = load(base_path), load(cur_path)
with io.open(added_path, "w", encoding="utf-8") as handle:
    for row in sorted(cur - base):
        handle.write(row + "\n")
with io.open(removed_path, "w", encoding="utf-8") as handle:
    for row in sorted(base - cur):
        handle.write(row + "\n")
PY
        echo "## 公共 API 变更"
        echo
        status=0
        if [ ! -s "$SCRATCH/added.txt" ] && [ ! -s "$SCRATCH/removed.txt" ]; then
            echo "无变化。"
        else
            if [ -s "$SCRATCH/added.txt" ]; then
                echo "### 新增"
                echo '```'
                cat "$SCRATCH/added.txt"
                echo '```'
                echo
            fi
            if [ -s "$SCRATCH/removed.txt" ]; then
                echo "### 移除或签名变更（宿主需同步修改）"
                echo '```'
                cat "$SCRATCH/removed.txt"
                echo '```'
                status=2
            fi
        fi
        exit "$status"
        ;;
    *)
        echo "未知子命令：${1}（可用 dump / check）" >&2
        exit 1
        ;;
esac
