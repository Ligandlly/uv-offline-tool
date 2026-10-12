#!/usr/bin/env bash
# install.sh —— 在【离线机器】上安装由 GitHub Actions (uv-offline-tool.yml) 下载好的
# wheel/sdist 产物。不针对任何特定包：包名、模式、解释器都可指定。
#
# 典型用法：
#   ./install.sh -w uv-wheels-py3.12-123456.zip -- 'qwenpaw[hub]'
#   ./install.sh -w ./wheels --mode tool -- ruff black
#   ./install.sh --mode venv -e .venv -- some-package==1.2.3
#   ./install.sh -w ./wheels --list
#
# 说明：安装时始终使用 --no-index（只用本地目录当包源），默认给 uv 再加 --offline，
# 因此不会向 PyPI 发请求。

set -euo pipefail

SCRIPT_NAME=${0##*/}

MODE=venv                 # tool | venv | pip
WHEELS_SRC=               # 目录或 zip（留空则自动探测）
PYTHON=python3            # 用于安装/vvenv 的解释器
VENV_DIR=./.uv-offline-venv
NO_BUILD_ISOLATION=auto   # auto | 1 | 0（auto: 目录里有需要构建的 sdist 且没有 setuptools wheel 时自动开启）
DRY_RUN=0
LIST_ONLY=0
QUIET=0
PACKAGES=()

TMP_DIR=

usage() {
  cat <<EOF
用法: $SCRIPT_NAME [选项] -- 包名 [包名...]

包名    要安装的包（可带版本/extras，如 qwenpaw[hub] 'ruff==0.6.9'），可写多个。
        注意必须加 '--'，避免包名被当成选项。

选项:
  -w, --wheels PATH     wheel/sdist 所在目录，或 Actions 下载的 artifact zip。
                        留空时自动探测: ./wheels、./uv-wheels-*、当前目录下的 *.zip
  -m, --mode MODE       tool  = uv tool install（全局命令行工具，生成 ~/.local/bin 下的命令）
                        venv  = 新建/复用一个虚拟环境再安装（默认）
                        pip   = 直接装进 --python 指定的解释器
  -p, --python PATH     解释器（默认: $PYTHON）。也是 venv 的基础解释器
  -e, --env DIR         mode=venv 时的虚拟环境目录（默认: $VENV_DIR）
  -n, --no-build-isolation   构建 sdist 时不做构建隔离（离线时通常需要）
      --build-isolation      强制开启构建隔离（覆盖 -n 和 auto 判断）
  -l, --list            只列出产物内容与预检查结果，不安装
  -N, --dry-run         只打印将要执行的命令，不安装
  -q, --quiet           少打印
  -h, --help            显示本帮助

示例:
  $SCRIPT_NAME -w uv-wheels-py3.12-38188961568.zip -- 'qwenpaw[hub]'
  $SCRIPT_NAME -w ./wheels -m tool -- ruff
  $SCRIPT_NAME -w ./wheels -m pip -p /usr/bin/python3.12 -- black mypy
EOF
}

# 日志一律走 stderr：stdout 留给「数据」（如 --list 的文件列表、resolve_wheels 的返回值）
log()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "警告: $*" >&2; }
die()  { printf '%s\n' "错误: $*" >&2; exit 1; }

cleanup() { if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi; }
trap cleanup EXIT

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case $1 in
    -w|--wheels)              WHEELS_SRC=${2:?$1 需要一个参数}; shift 2 ;;
    -m|--mode)                MODE=${2:?$1 需要一个参数}; shift 2 ;;
    -p|--python)              PYTHON=${2:?$1 需要一个参数}; shift 2 ;;
    -e|--env)                 VENV_DIR=${2:?$1 需要一个参数}; shift 2 ;;
    -n|--no-build-isolation)  NO_BUILD_ISOLATION=1; shift ;;
    --build-isolation)        NO_BUILD_ISOLATION=0; shift ;;
    -l|--list)                LIST_ONLY=1; shift ;;
    -N|--dry-run)             DRY_RUN=1; shift ;;
    -q|--quiet)               QUIET=1; shift ;;
    -h|--help)                usage; exit 0 ;;
    --)                       shift; PACKAGES+=("$@"); break ;;
    -*)                       die "未知选项: $1（看 $SCRIPT_NAME --help）" ;;
    *)                        PACKAGES+=("$1"); shift ;;
  esac
done

case $MODE in tool|venv|pip) ;; *) die "--mode 只能是 tool / venv / pip，收到: $MODE" ;; esac
[ "$LIST_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ] || [ ${#PACKAGES[@]} -gt 0 ] || { usage; die "请至少指定一个包名"; }

PYTHON_PATH=$(command -v "$PYTHON" 2>/dev/null || true)
[ -n "$PYTHON_PATH" ] || die "找不到解释器: $PYTHON"
PYTHON=$PYTHON_PATH   # 统一用绝对路径，避免 uv/pip 把 'python3' 当成需要下载的版本请求
HAVE_UV=0; command -v uv >/dev/null 2>&1 && HAVE_UV=1
if [ "$MODE" = tool ] && [ "$HAVE_UV" = 0 ]; then
  die "mode=tool 需要 uv（离线机器请先准备 uv，或用 -m venv / -m pip）"
fi

# ---------- 定位产物目录 ----------
resolve_wheels() {    # 把结果写进全局 WHEELS（因此不能用 $(...) 调用，否则 TMP_DIR 留在子 shell 里清不掉）
  local src=$1 dest
  if [ -d "$src" ]; then WHEELS=${src%/}; return 0; fi
  if [ -f "$src" ]; then
    case $src in
      *.zip)
        # 注意：TMP_DIR 必须在当前 shell 里赋值（后面 cleanup 才能清掉解压目录）
        [ -n "$TMP_DIR" ] || TMP_DIR=$(mktemp -d)
        log "解压 $src -> $TMP_DIR"
        if command -v unzip >/dev/null 2>&1; then
          unzip -q "$src" -d "$TMP_DIR"
        else
          "$PYTHON" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$src" "$TMP_DIR"
        fi
        if [ -d "$TMP_DIR/wheels" ]; then WHEELS=$TMP_DIR/wheels; return 0; fi
        dest=$(find "$TMP_DIR" -name '*.whl' -o -name '*.tar.gz' | head -n1 || true)
        if [ -n "$dest" ]; then WHEELS=$(dirname "$dest"); return 0; fi
        die "zip 里没有找到 .whl/.tar.gz: $src"
        ;;
      *) die "不支持的产物文件（需要目录或 .zip）: $src" ;;
    esac
  fi
  die "产物路径不存在: $src"
}

if [ -n "$WHEELS_SRC" ]; then
  WHEELS=
  resolve_wheels "$WHEELS_SRC"
else
  WHEELS=
  for cand in ./wheels ./uv-wheels-*; do
    if [ -d "$cand" ]; then WHEELS=$cand; break; fi
  done
  if [ -z "$WHEELS" ]; then
    for z in ./*.zip; do
      if [ -f "$z" ]; then resolve_wheels "$z"; break; fi
    done
  fi
  [ -n "$WHEELS" ] || die "没找到产物目录，请用 -w 指定（目录或 artifact zip）"
  log "自动探测到产物目录: $WHEELS"
fi

# ---------- 预检查 ----------
shopt -s nullglob
WHLS=("$WHEELS"/*.whl)
SDISTS=("$WHEELS"/*.tar.gz)
shopt -u nullglob
[ ${#WHLS[@]} -gt 0 ] || [ ${#SDISTS[@]} -gt 0 ] || die "$WHEELS 里没有 .whl/.tar.gz"

PY_DESC=$("$PYTHON" -c 'import platform,sys; print(f"{platform.python_implementation()} {platform.python_version()} ({sys.platform}-{platform.machine()})")')

log "产物目录 : $WHEELS"
log "wheel 数 : ${#WHLS[@]}"
log "sdist 数 : ${#SDISTS[@]}"
log "解释器   : $PY_DESC  [$PYTHON]"
log "安装模式 : $MODE"

if [ "$LIST_ONLY" = 1 ]; then
  for f in "${WHLS[@]}" "${SDISTS[@]}"; do printf '  %s\n' "${f##*/}"; done
fi

# 当前解释器是否能直接用目录里的二进制 wheel（纯 shell 的 best-effort 判断，只告警）
TAGS=
if "$PYTHON" -m pip debug --verbose >/dev/null 2>&1; then
  TAGS=$("$PYTHON" -m pip debug --verbose 2>/dev/null \
    | sed -n '/Compatible tags:/,/^$/p' | sed 's/^[[:space:]]*//' | grep -vE '^$|^Compatible tags:')
fi

wheel_tag_matches() {  # $1 = wheel 路径
  local base py abi plat p
  base=${1##*/}; base=${base%.whl}
  py=$(awk -F- '{print $(NF-2)}' <<<"$base")
  abi=$(awk -F- '{print $(NF-1)}' <<<"$base")
  plat=$(awk -F- '{print $NF}' <<<"$base")
  [ "$plat" = any ] && return 0
  [ -z "$TAGS" ] && return 1
  local IFS=.
  for p in $plat; do
    printf '%s\n' "$TAGS" | grep -qxF "$py-$abi-$p" && return 0
  done
  return 1
}

if [ ${#WHLS[@]} -gt 0 ] && [ -n "$TAGS" ]; then
  tag_ok=0
  for f in "${WHLS[@]}"; do
    if wheel_tag_matches "$f"; then tag_ok=1; break; fi
  done
  if [ "$tag_ok" = 0 ]; then
    warn "产物里的 wheel 与当前解释器/平台不匹配（$PY_DESC）。"
    warn "请确认离线机的 Python 版本和系统架构与 CI 下载时一致（如 cp312 + manylinux x86_64）。"
  fi
fi

# 需要构建的 sdist：优先保持构建隔离（构建依赖也从本地目录解析），
# 产物里没有 setuptools 时才退化为 --no-build-isolation
SDIST_NAMES=()
for f in "${SDISTS[@]}"; do SDIST_NAMES+=("${f##*/}"); done
HAVE_SETUPTOOLS_WHL=0
for f in "${WHLS[@]}"; do
  case ${f##*/} in setuptools-*.whl|setuptools_*.whl) HAVE_SETUPTOOLS_WHL=1 ;; esac
done

NEED_BUILD=0
[ ${#SDISTS[@]} -gt 0 ] && NEED_BUILD=1

USE_NO_ISOLATION=0
BUILD_FLAG=()
if [ "$NEED_BUILD" = 1 ]; then
  log "含源码包（需要本地构建）: ${SDIST_NAMES[*]}"
  case $NO_BUILD_ISOLATION in
    1) USE_NO_ISOLATION=1 ;;
    0) USE_NO_ISOLATION=0 ;;
    auto)
      if [ "$HAVE_SETUPTOOLS_WHL" = 1 ]; then
        log "产物含 setuptools wheel：保持构建隔离，构建依赖也从本地目录解析"
      else
        warn "产物里没有 setuptools wheel：改用 --no-build-isolation（需要目标环境已能 import setuptools）"
        USE_NO_ISOLATION=1
      fi
      ;;
  esac
  [ "$USE_NO_ISOLATION" = 1 ] && BUILD_FLAG=(--no-build-isolation)
fi

# 在真正安装前确认「无隔离构建」所需的后端可用；能兜底就兜底，不能就给出可操作的建议
check_build_backend() {
  local py=$1
  [ "$USE_NO_ISOLATION" = 1 ] || return 0
  "$py" -c 'import setuptools' >/dev/null 2>&1 && return 0
  if [ "$HAVE_SETUPTOOLS_WHL" = 1 ]; then
    log "目标环境缺 setuptools，先从产物目录补齐构建依赖: setuptools wheel"
    if [ "$HAVE_UV" = 1 ]; then
      run uv pip install --python "$py" --no-index --offline --find-links "$WHEELS" setuptools wheel
    else
      run "$py" -m pip install --no-index --find-links "$WHEELS" --disable-pip-version-check setuptools wheel
    fi
    return 0
  fi
  die "目标环境缺少 setuptools，离线状态下无法构建 sdist（${SDIST_NAMES[*]}）。
     解决办法（任选）：
       1) 在 CI 的 packages 输入里加上 'setuptools wheel' 一起下载，产物就能自给自足；
       2) 改用 -m venv / -m pip，并在目标环境中预装 setuptools 后用 --no-build-isolation；
       3) 只用 --list 查看产物内容，不安装。"
}

[ "$LIST_ONLY" = 1 ] && { log "仅列出（--list），未安装"; exit 0; }

run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

# ---------- 安装 ----------
case $MODE in
  tool)
    if [ "$USE_NO_ISOLATION" = 1 ]; then
      die "mode=tool 需要构建 sdist（${SDIST_NAMES[*]}），但产物里没有 setuptools wheel。
     请在 CI 的 packages 输入里加上 'setuptools wheel' 重新下载，或改用 -m venv 模式。"
    fi
    CMD=(uv tool install --no-index --offline --find-links "$WHEELS" "${BUILD_FLAG[@]}" --python "$PYTHON" "${PACKAGES[@]}")
    log "执行: ${CMD[*]}"
    run "${CMD[@]}"
    if [ "$DRY_RUN" = 0 ]; then
      log ""
      log "已安装的 uv tool:"
      uv tool list || true
      log "可执行文件目录: $(uv tool dir --bin 2>/dev/null || echo '~/.local/bin')（确认它在 PATH 里）"
    fi
    ;;
  venv)
    venv_python() {   # 尚未创建的环境中（如 --dry-run）按操作系统猜路径
      if [ -x "$VENV_DIR/bin/python" ]; then printf '%s\n' "$VENV_DIR/bin/python"; return; fi
      if [ -x "$VENV_DIR/Scripts/python.exe" ]; then printf '%s\n' "$VENV_DIR/Scripts/python.exe"; return; fi
      case ${OS:-$(uname -s 2>/dev/null || echo unknown)} in
        Windows*|MINGW*|MSYS*|CYGWIN*) printf '%s\n' "$VENV_DIR/Scripts/python.exe" ;;
        *) printf '%s\n' "$VENV_DIR/bin/python" ;;
      esac
    }
    VENV_PY=$(venv_python)
    if [ -x "$VENV_PY" ]; then
      log "复用已存在的虚拟环境: $VENV_DIR"
    else
      if [ "$HAVE_UV" = 1 ]; then
        CMD=(uv venv --python "$PYTHON" "$VENV_DIR")
      else
        CMD=("$PYTHON" -m venv "$VENV_DIR")
      fi
      log "创建虚拟环境: ${CMD[*]}"
      run "${CMD[@]}"
      VENV_PY=$(venv_python)
    fi
    if [ "$HAVE_UV" = 1 ]; then
      CMD=(uv pip install --python "$VENV_PY" --no-index --offline --find-links "$WHEELS" "${BUILD_FLAG[@]}" "${PACKAGES[@]}")
    else
      CMD=("$VENV_PY" -m pip install --no-index --find-links "$WHEELS" --disable-pip-version-check "${BUILD_FLAG[@]}" "${PACKAGES[@]}")
    fi
    check_build_backend "$VENV_PY"
    log "执行: ${CMD[*]}"
    run "${CMD[@]}"
    [ "$DRY_RUN" = 0 ] && log "完成。激活: source \"$VENV_DIR/bin/activate\"（Windows: $VENV_DIR\\Scripts\\activate）"
    ;;
  pip)
    if "$PYTHON" -m pip --version >/dev/null 2>&1; then
      CMD=("$PYTHON" -m pip install --no-index --find-links "$WHEELS" --disable-pip-version-check "${BUILD_FLAG[@]}" "${PACKAGES[@]}")
    elif [ "$HAVE_UV" = 1 ]; then
      CMD=(uv pip install --python "$PYTHON" --no-index --offline --find-links "$WHEELS" "${BUILD_FLAG[@]}" "${PACKAGES[@]}")
    else
      die "既没有 pip 也没有 uv 可用于 $PYTHON"
    fi
    check_build_backend "$PYTHON"
    log "执行: ${CMD[*]}"
    run "${CMD[@]}"
    ;;
esac

log "全部完成。"
