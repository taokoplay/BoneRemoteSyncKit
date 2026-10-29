#!/bin/bash
# 回收本地构建与测试残留，避免长期累积占用磁盘。
#
# 设计原则：默认只清理可再生成的产物，不触碰源码、文档或 git 状态。
# 所有删除动作都先打印将要处理的目标与体积，便于核对。
#
# 用法：
#   script/clean.sh              # 清理 .build、测试临时目录与残留临时文件（默认）
#   script/clean.sh --dry-run    # 只报告，不删除
#   script/clean.sh --build-only # 只清理 .build
#   script/clean.sh --all        # 额外清理 SwiftPM 全局缓存与 DerivedData 中的本包产物
#
# 退出码：0 成功；1 参数错误。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
BUILD_ONLY=0
INCLUDE_GLOBAL=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --build-only) BUILD_ONLY=1 ;;
        --all) INCLUDE_GLOBAL=1 ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数：${arg}（可用 --dry-run / --build-only / --all）" >&2
            exit 1
            ;;
    esac
done

# Temp paths that the test fixtures create. Both patterns are owned by this package's
# test servers; a bare UUID directory cannot be attributed safely, so it is not matched.
TEST_TEMP_PATTERNS=(
    "$TMPDIR""BoneDAVTests-*"
    "$TMPDIR""BoneODTests-*"
    "$TMPDIR""BoneODWriteTests-*"
    "$TMPDIR""CatalogTests-*"
)

size_of() {
    # du on a missing path would fail; guard so --dry-run stays usable on clean trees.
    [ -e "$1" ] && du -sh "$1" 2>/dev/null | cut -f1 || echo "0B"
}

remove_path() {
    local path="$1"
    [ -e "$path" ] || return 0
    local bytes
    bytes="$(size_of "$path")"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] 将删除 $bytes  $path"
    else
        rm -rf "$path"
        echo "  已删除 $bytes  $path"
    fi
}

echo "== BoneRemoteSyncKit 缓存回收 =="
echo "仓库：$REPO_ROOT"
[ "$DRY_RUN" -eq 1 ] && echo "模式：演练（不实际删除）"
echo

echo "-- SwiftPM 构建产物 --"
remove_path "$REPO_ROOT/.build"
# 允许在使用 --scratch-path 时留下的并行构建目录
for dir in "$REPO_ROOT"/.build-*; do
    [ -d "$dir" ] && remove_path "$dir"
done
remove_path "$REPO_ROOT/.swiftpm"

if [ "$BUILD_ONLY" -eq 0 ]; then
    echo
    echo "-- 测试夹具临时目录 --"
    found=0
    for pattern in "${TEST_TEMP_PATTERNS[@]}"; do
        for dir in $pattern; do
            [ -e "$dir" ] || continue
            found=1
            remove_path "$dir"
        done
    done
    [ "$found" -eq 0 ] && echo "  无残留"
fi

if [ "$INCLUDE_GLOBAL" -eq 1 ]; then
    echo
    echo "-- 共享缓存（--all）--"
    remove_path "$HOME/Library/Caches/org.swift.swiftpm"
    # DerivedData 中的本包构建目录；保留其他项目的 DerivedData。
    for dir in "$HOME"/Library/Developer/Xcode/DerivedData/BoneRemoteSyncKit-*; do
        [ -e "$dir" ] && remove_path "$dir"
    done
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "演练完成，未删除任何内容。"
else
    echo "回收完成。磁盘可用空间："
    df -h "$REPO_ROOT" | tail -1
fi
