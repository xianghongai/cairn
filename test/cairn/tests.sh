#!/usr/bin/env bash
# SC2088：清单中的 ~ 是字面量路径，由 cairn.sh 自己展开，此处不应由 shell 展开。
# shellcheck disable=SC2088
# 只在一次性 Docker 容器中执行（入口见 test/compose.yaml），不在宿主机上运行。
# 覆盖 cairn.sh 的外部行为：配置来源、Gist 获取、清单校验、路径规则、replace 与 merge 写入、备份、
# 交互清单、--dry-run、结果汇总与 install。全部通过命令行调用，不断言内部函数。
#
# 用法（容器内）：TEST_SHELL=bash|zsh bash test/cairn/tests.sh
set -uo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
CAIRN="${WORKSPACE}/cairn.sh"
FAKE_GIST="${WORKSPACE}/test/cairn/fake_gist.py"
PORT="${CAIRN_TEST_PORT:-18080}"
API_BASE="http://127.0.0.1:${PORT}"
TOKEN="test-token"
GIST_ID="0123abcd"
MANIFEST="cairn-manifest.json"
SHELL_BIN="${TEST_SHELL:-bash}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [ok]   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
head_() { printf '\n== %s (%s) ==\n' "$1" "$SHELL_BIN"; }

command -v jq >/dev/null 2>&1 || { printf '前提不满足：缺少 jq。\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '前提不满足：缺少 python3。\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf '前提不满足：缺少 curl。\n' >&2; exit 1; }
command -v wget >/dev/null 2>&1 || { printf '前提不满足：缺少 wget。\n' >&2; exit 1; }

ROOT="$(mktemp -d)"
GISTS="${ROOT}/gists"
mkdir -p "$GISTS"
SERVER_PID=""
HTTP_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

python3 "$FAKE_GIST" "$GISTS" "$PORT" "$TOKEN" &
SERVER_PID=$!
i=0
until curl -s -o /dev/null "${API_BASE}/" || [ "$i" -ge 50 ]; do
  sleep 0.1
  i=$((i + 1))
done

# 每个用例使用独立的 HOME，避免互相影响
new_home() { HOME_DIR="$(mktemp -d "${ROOT}/home.XXXXXX")"; }

# 写入 Mock Gist：$1 清单 JSON，其后每两个参数为一个远程文件的文件名与内容
put_gist() {
  local files
  files="$(jq -n --arg n "$MANIFEST" --arg c "$1" '{($n): {content: $c}}')"
  shift
  while [ $# -ge 2 ]; do
    files="$(jq --arg n "$1" --arg c "$2" '. + {($n): {content: $c}}' <<< "$files")"
    shift 2
  done
  jq -n --argjson f "$files" '{id: "x", files: $f}' >"${GISTS}/${GIST_ID}.json"
}

# 在清空的环境中运行命令，环境只含指向 Mock Gist 的完整配置。参数依次为附加或覆盖的 VAR=值
# （如 CAIRN_UNAME=Darwin、PATH=/usr/bin:/bin，后写的覆盖先写的）与要运行的命令。
# NODE_PATH 与 PYTHONPATH 原样传入，让容器中的 jsonc-parser 与 tomlkit 可以被找到。
# 界面语言固定为 zh-CN：部分用例按中文报错区分是哪条规则拦下的
cairn_env() {
  env -i PATH="$PATH" HOME="$HOME_DIR" NODE_PATH="${NODE_PATH:-}" PYTHONPATH="${PYTHONPATH:-}" CAIRN_LANG=zh-CN \
    CAIRN_API_BASE="$API_BASE" CAIRN_GITHUB_TOKEN="$TOKEN" CAIRN_GIST_ID="$GIST_ID" CAIRN_MANIFEST="$MANIFEST" \
    "$@"
}

# 非交互运行 pull --yes；参数追加在后面（如条目名、--dry-run）
run_pull() {
  cairn_env timeout 60 "$SHELL_BIN" "$CAIRN" pull --yes "$@" </dev/null
}

# 以指定的 CAIRN_UNAME（$1）模拟平台运行 pull --yes，其余参数追加在后面
run_as() {
  local uname="$1"
  shift
  cairn_env CAIRN_UNAME="$uname" timeout 60 "$SHELL_BIN" "$CAIRN" pull --yes "$@" </dev/null
}

ZSHRC_MANIFEST='{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"}}}'
ZSHRC_CONTENT=$'export A=1\n\n# 末尾保留空行\n'
TWO_MANIFEST='{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"},"gitconfig":{"remote":"gitconfig.txt","path":{"linux":"~/.gitconfig"},"strategy":"replace"}}}'
GIT_CONTENT=$'[user]\n\tname = test\n'

head_ "缺少 Gist ID 时报错，且不写入任何文件"
new_home
out="$(env -i PATH="$PATH" HOME="$HOME_DIR" \
  CAIRN_API_BASE="$API_BASE" CAIRN_GITHUB_TOKEN="$TOKEN" CAIRN_MANIFEST="$MANIFEST" \
  "$SHELL_BIN" "$CAIRN" pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "缺少 CAIRN_GIST_ID 时非零退出，未写入"
else
  bad "缺少 CAIRN_GIST_ID 时应报错（rc=$rc，输出：$out）"
fi

head_ "replace 把远程文件原样写入 Linux 路径，~ 展开为 HOME"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
run_pull >/dev/null 2>&1
rc=$?
printf '%s' "$ZSHRC_CONTENT" >"${ROOT}/expected"
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "文件内容与远程逐字节一致（含末尾空行）"
else
  bad "文件内容应与远程一致（rc=$rc）"
fi
# 缺少 token 或清单名时，同样报错并指出缺哪个
head_ "缺少 token 时报错；清单名缺省为 cairn-manifest.json"
new_home
out="$(env -i PATH="$PATH" HOME="$HOME_DIR" CAIRN_API_BASE="$API_BASE" \
  CAIRN_GIST_ID="$GIST_ID" CAIRN_MANIFEST="$MANIFEST" "$SHELL_BIN" "$CAIRN" pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "缺少 token 时非零退出"
else
  bad "缺少 token 时应报错（输出：$out）"
fi
# 清单名缺省为 cairn-manifest.json：不设置 CAIRN_MANIFEST 时，按该名字在 Gist 中查找
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf '%s' "$ZSHRC_CONTENT" >"${ROOT}/expected"
out="$(env -i PATH="$PATH" HOME="$HOME_DIR" CAIRN_API_BASE="$API_BASE" \
  CAIRN_GIST_ID="$GIST_ID" CAIRN_GITHUB_TOKEN="$TOKEN" "$SHELL_BIN" "$CAIRN" pull --yes </dev/null 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "未设置 CAIRN_MANIFEST 时使用默认清单名 cairn-manifest.json"
else
  bad "未设置清单名时应使用默认清单名（rc=$rc，输出：$out）"
fi

# token 错误时，Gist 返回 401，应报错且不写入
head_ "token 错误时报错，且不写入任何文件"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(env -i PATH="$PATH" HOME="$HOME_DIR" CAIRN_API_BASE="$API_BASE" \
  CAIRN_GITHUB_TOKEN="wrong-token" CAIRN_GIST_ID="$GIST_ID" CAIRN_MANIFEST="$MANIFEST" \
  "$SHELL_BIN" "$CAIRN" pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "错误 token 时报错，未写入文件"
else
  bad "错误 token 时应报错（rc=$rc，输出：$out）"
fi

# 命令行参数可以代替环境变量；参数优先于环境变量
head_ "--gist 与 --manifest 可代替环境变量，且优先于环境变量"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
env -i PATH="$PATH" HOME="$HOME_DIR" CAIRN_API_BASE="$API_BASE" \
  CAIRN_GITHUB_TOKEN="$TOKEN" \
  "$SHELL_BIN" "$CAIRN" pull --gist "$GIST_ID" --manifest "$MANIFEST" --yes </dev/null >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "仅用参数（无环境变量）即可拉取"
else
  bad "参数应可代替环境变量（rc=$rc）"
fi
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
cairn_env CAIRN_GIST_ID=0000dead CAIRN_MANIFEST=wrong.json \
  "$SHELL_BIN" "$CAIRN" pull --gist "$GIST_ID" --manifest "$MANIFEST" --yes </dev/null >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "参数优先于环境变量"
else
  bad "参数应优先于环境变量（rc=$rc）"
fi

# 清单中的远程文件不存在于 Gist 时报错，且不写入
head_ "远程文件缺失时报错，且不写入"
new_home
put_gist "$ZSHRC_MANIFEST" other.txt "$ZSHRC_CONTENT"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "远程文件缺失时非零退出，未写入"
else
  bad "远程文件缺失时应报错（rc=$rc，输出：$out）"
fi

# 某个条目失败时，其余条目仍然执行，且整体以非零状态退出
head_ "单个条目失败时其余条目仍执行，退出码非零"
new_home
MULTI_MANIFEST='{"entries":{"bashrc":{"remote":"bashrc.txt","path":{"linux":"~/.bashrc"},"strategy":"replace"},"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"}}}'
put_gist "$MULTI_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf '%s' "$ZSHRC_CONTENT" >"${ROOT}/expected"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "失败条目之后的条目仍被写入，且退出码非零"
else
  bad "其余条目应仍执行且退出码非零（rc=$rc，输出：$out）"
fi

# 选项缺少参数时应立即报错退出，不能死循环
head_ "选项缺少参数时快速报错"
new_home
for opt in --gist --manifest; do
  out="$(env -i PATH="$PATH" HOME="$HOME_DIR" CAIRN_API_BASE="$API_BASE" \
    CAIRN_GITHUB_TOKEN="$TOKEN" timeout 5 "$SHELL_BIN" "$CAIRN" pull "$opt" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    ok "$opt 缺少参数时报错"
  else
    bad "$opt 缺少参数时应报错而非挂起（rc=$rc）"
  fi
done

# 平台检测通过 CAIRN_UNAME 覆盖 uname -s，使测试在 Linux 容器中也能模拟其他系统
MACOS_MANIFEST='{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.linux-rc","macos":"~/Library/rc"},"strategy":"replace"}}}'
head_ "macOS 使用 path.macos，不使用 path.linux"
new_home
put_gist "$MACOS_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
run_as Darwin >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/Library/rc" && [ ! -e "$HOME_DIR/.linux-rc" ]; then
  ok "Darwin 写入 path.macos 指向的位置"
else
  bad "Darwin 应写入 path.macos（rc=$rc）"
fi

# windows 字段可以存在于清单中，但在 Windows 上拒绝运行
WINDOWS_MANIFEST='{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc","macos":"~/.zshrc","windows":"%USERPROFILE%\\.zshrc"},"strategy":"replace"}}}'
head_ "Windows 上拒绝运行，且不写入任何文件"
new_home
put_gist "$WINDOWS_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(run_as MINGW64_NT-10.0-19045 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "Windows 上非零退出，未写入"
else
  bad "Windows 应给出不支持提示（rc=$rc，输出：$out）"
fi

# 条目没有当前平台可用的路径：该条目不适用于此平台，被跳过，其余条目照常执行，不算失败
MACOS_ONLY_MANIFEST='{"entries":{"mac-only":{"remote":"zshrc.txt","path":{"macos":"~/Library/rc"},"strategy":"replace"},"zshrc":{"remote":"zshrc.txt","path":"~/.zshrc","strategy":"replace"}}}'
head_ "缺少当前平台路径的条目被跳过，其余条目照常写入，退出码为 0"
new_home
put_gist "$MACOS_ONLY_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(run_as Linux 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" && [ ! -e "$HOME_DIR/Library/rc" ]; then
  ok "mac-only 在 Linux 上被跳过，zshrc 已写入，退出码为 0"
else
  bad "缺少平台路径的条目应跳过而不是失败（rc=$rc，输出：$out）"
fi

head_ "清单中的 windows 字段在 Linux 上被忽略，不影响拉取"
new_home
put_gist "$WINDOWS_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
run_as Linux >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "Linux 忽略 windows 字段并正常写入"
else
  bad "存在 windows 字段时 Linux 应正常拉取（rc=$rc）"
fi
# 清单 JSON Schema：示例清单应通过校验；merge 条目缺少 format 应失败
SCHEMA="${WORKSPACE}/cairn-manifest.schema.json"
VALIDATE="${WORKSPACE}/test/cairn/validate_manifest.py"
SAMPLE_MANIFEST='{"entries":{
  "zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc","macos":"~/.zshrc"},"strategy":"replace","description":"整文件"},
  "editor":{"remote":"editor.jsonc","path":{"linux":"~/.config/editor/settings.json","macos":"~/Library/Application Support/Editor/settings.json","windows":"%APPDATA%\\Editor\\settings.json"},"strategy":"merge","format":"jsonc"}
}}'
# merge 条目省略 format：Schema 不要求（由 remote 后缀推断是运行时行为），应通过
MERGE_NO_FORMAT='{"entries":{
  "editor":{"remote":"editor.jsonc","path":{"linux":"~/.config/editor/settings.json","macos":"~/Library/Application Support/Editor/settings.json"},"strategy":"merge"}
}}'

head_ "清单 Schema：示例清单通过校验"
printf '%s' "$SAMPLE_MANIFEST" >"${ROOT}/sample-manifest.json"
out="$(python3 -I "$VALIDATE" "$SCHEMA" "${ROOT}/sample-manifest.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "示例清单通过 Schema 校验（replace 无 format，merge 有 format）"
else
  bad "示例清单应通过校验（rc=$rc，输出：$out）"
fi

head_ "清单 Schema：merge 条目可省略 format（推断在运行时进行）"
printf '%s' "$MERGE_NO_FORMAT" >"${ROOT}/merge-no-format.json"
out="$(python3 -I "$VALIDATE" "$SCHEMA" "${ROOT}/merge-no-format.json" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "merge 省略 format 时 Schema 通过（退出码 0）"
else
  bad "merge 省略 format 时 Schema 应通过（输出：$out）"
fi

# merge 的 format 不含 text：Schema 与运行时一致，均拒绝 text
head_ "清单 Schema：merge 条目 format 为 text 时校验失败"
MERGE_TEXT_FORMAT='{"entries":{
  "notes":{"remote":"notes.txt","path":{"linux":"~/.notes","macos":"~/.notes"},"strategy":"merge","format":"text"}
}}'
printf '%s' "$MERGE_TEXT_FORMAT" >"${ROOT}/merge-text-format.json"
out="$(python3 -I "$VALIDATE" "$SCHEMA" "${ROOT}/merge-text-format.json" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'format'; then
  ok "merge 的 format 为 text 时 Schema 校验失败（退出码 1）"
else
  bad "merge 的 format 为 text 时应校验失败（rc=$rc，输出：$out）"
fi

head_ "清单 Schema：path 只写 linux 时通过；两个平台都没写时失败"
LINUX_ONLY_MANIFEST='{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"}}}'
EMPTY_PATH_MANIFEST='{"entries":{"zshrc":{"remote":"zshrc.txt","path":{},"strategy":"replace"}}}'
printf '%s' "$LINUX_ONLY_MANIFEST" >"${ROOT}/linux-only.json"
printf '%s' "$EMPTY_PATH_MANIFEST" >"${ROOT}/empty-path.json"
out="$(python3 -I "$VALIDATE" "$SCHEMA" "${ROOT}/linux-only.json" 2>&1)"
rc_ok=$?
out2="$(python3 -I "$VALIDATE" "$SCHEMA" "${ROOT}/empty-path.json" 2>&1)"
rc_bad=$?
if [ "$rc_ok" -eq 0 ] && [ "$rc_bad" -eq 1 ]; then
  ok "只写 linux 的 path 通过，两个平台都没写则失败"
else
  bad "path 校验应与运行时一致（只写 linux：rc=$rc_ok，输出：$out；都没写：rc=$rc_bad，输出：$out2）"
fi

# 条目名含 | 时不得误判为重复：a|b 与 a 是两个不同的名字
head_ "条目名含 | 时不误判为重复"
new_home
PIPE_MANIFEST='{"entries":{
  "a|b":{"remote":"ab.txt","path":{"linux":"~/.ab"},"strategy":"replace"},
  "a":{"remote":"a.txt","path":{"linux":"~/.a"},"strategy":"replace"}
}}'
put_gist "$PIPE_MANIFEST" ab.txt 'AB' a.txt 'A'
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$HOME_DIR/.ab")" = AB ] && [ "$(cat "$HOME_DIR/.a")" = A ]; then
  ok "a|b 与 a 都被正常处理"
else
  bad "含 | 的名字不应被判为重复（rc=$rc，输出：$out）"
fi

# 符号链接循环（.zshrc -> c2 -> .zshrc）时应报错退出，不能挂起
head_ "符号链接循环时报错退出，不挂起"
new_home
ln -s "$HOME_DIR/c2" "$HOME_DIR/.zshrc"
ln -s "$HOME_DIR/.zshrc" "$HOME_DIR/c2"
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  ok "循环链接时报错退出（rc=$rc），未挂起"
else
  bad "循环链接应报错退出而不是挂起（rc=$rc，输出：$out）"
fi

# install：复制到用户可执行目录，可直接用命令名运行，不修改 shell 配置
head_ "install 复制脚本到 ~/.local/bin 且可执行"
new_home
out="$(env -i PATH="$PATH" HOME="$HOME_DIR" "$SHELL_BIN" "$CAIRN" install 2>&1)"
rc=$?
INSTALLED="${HOME_DIR}/.local/bin/cairn"
if [ "$rc" -eq 0 ] && [ -f "$INSTALLED" ] && [ -x "$INSTALLED" ] && cmp -s "$CAIRN" "$INSTALLED"; then
  ok "安装文件与源脚本一致且可执行"
else
  bad "install 应复制可执行文件（rc=$rc，输出：$out）"
fi

head_ "安装后可用命令名直接运行"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
env -i PATH="$PATH" HOME="$HOME_DIR" "$SHELL_BIN" "$CAIRN" install >/dev/null 2>&1
cairn_env PATH="${HOME_DIR}/.local/bin:${PATH}" "$SHELL_BIN" -c 'cairn pull --yes' </dev/null >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "通过命令名 cairn 执行 pull 成功"
else
  bad "安装后应能用命令名运行（rc=$rc）"
fi

head_ "install 不修改任何 shell 配置文件"
new_home
for f in .bashrc .bash_profile .profile .zshrc .zprofile; do
  printf 'original %s\n' "$f" >"${HOME_DIR}/${f}"
done
before="$(cd "$HOME_DIR" && find . -type f -exec cksum {} + | sort)"
env -i PATH="$PATH" HOME="$HOME_DIR" "$SHELL_BIN" "$CAIRN" install >/dev/null 2>&1
rc=$?
after="$(cd "$HOME_DIR" && find . -type f ! -path './.local/bin/cairn' -exec cksum {} + | sort)"
if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then
  ok "rc 文件内容不变且未新增 rc 文件"
else
  bad "install 不应修改或新增 shell 配置（rc=$rc）"
fi

# 清单校验失败：整次执行必须报错退出，且 HOME 下不产生任何文件
# 用法：reject_case 描述 清单 JSON 报错信息需匹配的正则
reject_case() {
  head_ "$1"
  new_home
  put_gist "$2" zshrc.txt "$ZSHRC_CONTENT"
  out="$(run_pull 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qE -- "$3" &&
    [ -z "$(find "$HOME_DIR" -type f)" ]; then
    ok "报错退出（$3），且未写入任何文件"
  else
    bad "应报错且不写入（rc=$rc，输出：$out）"
  fi
}

ZSHRC_ENTRY='"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"}'

reject_case "清单不是合法 JSON 时报错，且不写入" \
  '{"entries":{' '清单.*JSON'

reject_case "后面的条目 strategy 不合法时，前面的合法条目也不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"append\"}}}" \
  '条目 bad.*strategy'

reject_case "后面的条目缺少 remote 时报错，并指出条目与字段" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"replace\"}}}" \
  '条目 bad.*remote'

reject_case "条目的 path 取值不合法时报错，不当作不适用跳过，且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":5,\"default\":\"~/.bad\"},\"strategy\":\"replace\"}}}" \
  '条目 bad.*path'

reject_case "条目值不是对象时报错，并指出条目名" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":\"oops\"}}" \
  '条目 bad.*不是对象'

reject_case "merge 条目缺少 format 且无法从 remote 后缀推断时报错" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"merge\"}}}" \
  '条目 bad.*format'

reject_case "merge 条目 format 为 text 时报错（运行时不支持）" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"merge\",\"format\":\"text\"}}}" \
  '条目 bad.*format'



# 覆盖已有文件前，原文件备份到状态目录 cairn/backup/，文件名 <原文件名>.<时间戳>.bak
head_ "覆盖已有文件前备份原文件"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf 'export OLD=1\n' >"$HOME_DIR/.zshrc"
printf 'export OLD=1\n' >"${ROOT}/old"
run_pull >/dev/null 2>&1
rc=$?
bak_dir="$HOME_DIR/.local/state/cairn/backup"
bak_list="$(find "$bak_dir" -maxdepth 1 -type f 2>/dev/null)"
bak="$(printf '%s\n' "$bak_list" | head -n 1)"
if [ "$rc" -eq 0 ] && [ -n "$bak" ] && [ "$(printf '%s\n' "$bak_list" | grep -c .)" -eq 1 ] &&
  cmp -s "${ROOT}/old" "$bak" && basename "$bak" | grep -Eq '^\.zshrc\.[0-9]{8}-[0-9]{6}\.bak$'; then
  ok "备份内容与原文件一致，文件名带秒级时间戳"
else
  bad "覆盖前应备份原文件（rc=$rc，备份：${bak_list:-无}）"
fi

# 连续多次覆盖（同一秒内也一样）：每次的原文件各自保留，互不覆盖
head_ "同一秒内多次覆盖，备份互不覆盖"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf 'export V=0\n' >"$HOME_DIR/.zshrc"
run_pull >/dev/null 2>&1
rc1=$?
printf 'export V=1\n' >"$HOME_DIR/.zshrc"
run_pull >/dev/null 2>&1
rc2=$?
bak_list="$(find "$HOME_DIR/.local/state/cairn/backup" -maxdepth 1 -type f 2>/dev/null)"
n_all="$(printf '%s\n' "$bak_list" | grep -c .)"
bak_dir="$HOME_DIR/.local/state/cairn/backup"
n_v0="$(find "$bak_dir" -maxdepth 1 -type f -exec grep -lx 'export V=0' {} + 2>/dev/null | grep -c .)"
n_v1="$(find "$bak_dir" -maxdepth 1 -type f -exec grep -lx 'export V=1' {} + 2>/dev/null | grep -c .)"
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$n_all" -eq 2 ] && [ "$n_v0" -eq 1 ] && [ "$n_v1" -eq 1 ]; then
  ok "两次覆盖各留一份备份，内容分别为两次覆盖前的原文件"
else
  bad "同一秒内多次覆盖应保留两份备份（备份数 $n_all，V=0 $n_v0，V=1 $n_v1）"
fi

# 目标文件不存在时，不生成备份
head_ "目标文件不存在时不生成备份"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
run_pull >/dev/null 2>&1
rc=$?
n_bak="$(find "$HOME_DIR/.local" -name '*.bak' 2>/dev/null | grep -c .)"
if [ "$rc" -eq 0 ] && [ "$n_bak" -eq 0 ]; then
  ok "首次写入不生成备份"
else
  bad "目标不存在时不应生成备份（rc=$rc，备份数 $n_bak）"
fi
# 写入经同目录临时文件再移动覆盖：成功后不残留临时文件，原文件权限保留（600）
head_ "覆盖成功后不残留临时文件，原权限保留"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf 'export OLD=1\n' >"$HOME_DIR/.zshrc"
chmod 600 "$HOME_DIR/.zshrc"
run_pull >/dev/null 2>&1
rc=$?
n_tmp="$(find "$HOME_DIR" -name '*cairn-tmp*' | grep -c .)"
if [ "$rc" -eq 0 ] && [ "$n_tmp" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" &&
  [ -n "$(find "$HOME_DIR/.zshrc" -perm 600)" ]; then
  ok "成功后无临时文件残留，目标内容正确且权限仍为 600"
else
  bad "覆盖后不应残留临时文件或改变权限（rc=$rc，临时文件数 $n_tmp）"
fi

# --dry-run 不修改已有目标文件，也不生成备份
head_ "--dry-run 不修改已有文件，也不生成备份"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf 'export OLD=1\n' >"$HOME_DIR/.zshrc"
printf 'export OLD=1\n' >"${ROOT}/old"
run_pull --dry-run >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/old" "$HOME_DIR/.zshrc" && [ ! -e "$HOME_DIR/.local/state/cairn" ]; then
  ok "目标文件内容不变，未生成备份目录"
else
  bad "--dry-run 不应修改文件或生成备份（rc=$rc）"
fi

# 预览不写入，因此非交互环境下无需 --yes 即可运行
head_ "非交互且未指定 --yes 时，--dry-run 仍可运行"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(cairn_env "$SHELL_BIN" "$CAIRN" pull --dry-run </dev/null 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "无 --yes 的 --dry-run 退出码为 0，且未写入"
else
  bad "--dry-run 不应因缺少 --yes 被拒绝（rc=$rc，输出：$out）"
fi

# 某条目会失败（远程文件缺失）时，预览与实际执行的退出码一致
head_ "--dry-run 的退出码与实际执行一致"
new_home
MISSING_MANIFEST='{"entries":{"bashrc":{"remote":"nosuch.txt","path":{"linux":"~/.bashrc"},"strategy":"replace"},"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"}}}'
put_gist "$MISSING_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out_dry="$(run_pull --dry-run 2>&1)"
rc_dry=$?
run_pull >/dev/null 2>&1
rc_real=$?
if [ "$rc_dry" -ne 0 ] && [ "$rc_dry" -eq "$rc_real" ]; then
  ok "预览退出码（$rc_dry）与实际执行一致"
else
  bad "预览与实际执行的退出码应一致（dry=$rc_dry，real=$rc_real，输出：$out_dry）"
fi

# 交互终端中 --dry-run 不进入清单选择，即使有按键输入也不写入
head_ "交互终端中 --dry-run 不写入"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(run_pick $'a\n' --dry-run 2>&1)"
if [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "按键输入不影响预览，未写入文件"
else
  bad "交互 --dry-run 不应提示或写入（输出：$out）"
fi

# 在伪终端中运行 pull（不带 --yes）。$1 为依次送入的按键原始字节（方向键为 ESC [ A/B），$2 为附加参数
run_pick() {
  printf '%s' "$1" | cairn_env script -qec "\"$SHELL_BIN\" \"$CAIRN\" pull ${2:-}" /dev/null
}

# 两个条目的清单与 Gist：zshrc 与 gitconfig 均为 replace
new_pick_home() {
  new_home
  put_gist "$TWO_MANIFEST" zshrc.txt "$ZSHRC_CONTENT" gitconfig.txt "$GIT_CONTENT"
  printf '%s' "$GIT_CONTENT" >"${ROOT}/expected_gitconfig"
}

# 默认全部不勾选：直接回车不写入，退出码为 0
head_ "交互清单默认不选，回车后不写入"
new_pick_home
out="$(run_pick $'\n' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME_DIR/.zshrc" ] && [ ! -e "$HOME_DIR/.gitconfig" ]; then
  ok "默认不选，回车后不写入"
else
  bad "默认不选时回车不应写入（rc=$rc，输出：$out）"
fi

# 空格勾选当前条目（第一个）：只写入它，第二个保持未选
head_ "空格勾选第一个条目：只写入该条目"
new_pick_home
out="$(run_pick $' \n' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" &&
  [ ! -e "$HOME_DIR/.gitconfig" ]; then
  ok "只写入被勾选的 zshrc，gitconfig 保持未选"
else
  bad "空格只应勾选当前条目（rc=$rc，输出：$out）"
fi

# n 全不选后回车：不写入，退出码为 0
head_ "n 全不选后回车：不写入，退出码为 0"
new_pick_home
out="$(run_pick $'n\n' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME_DIR/.zshrc" ] && [ ! -e "$HOME_DIR/.gitconfig" ]; then
  ok "全不选时不写入，退出码为 0"
else
  bad "n 后回车应不写入且退出码为 0（rc=$rc，输出：$out）"
fi

# a 全选：先 n 全不选，再 a 全选，回车后两项都写入
head_ "n 之后按 a 重新全选"
new_pick_home
out="$(run_pick $'na\n' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" &&
  cmp -s "${ROOT}/expected_gitconfig" "$HOME_DIR/.gitconfig"; then
  ok "a 重新全选后两项都写入"
else
  bad "n 之后 a 应全选（rc=$rc，输出：$out）"
fi

# q 取消：不写入，退出码为 0，并恢复光标显示
head_ "q 取消：不写入，退出码为 0，并恢复光标"
new_pick_home
out="$(run_pick 'q' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME_DIR/.zshrc" ] && [ ! -e "$HOME_DIR/.gitconfig" ] &&
  printf '%s' "$out" | grep -qF "$(printf '\033[?25h')"; then
  ok "q 取消未写入，退出码为 0，光标已恢复"
else
  bad "q 应取消且不写入（rc=$rc，输出：$out）"
fi

# 单独的 Esc 取消：不等待后续字节，直接取消
head_ "单独的 Esc 取消：不写入，退出码为 0"
new_pick_home
out="$(run_pick $'\033' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME_DIR/.zshrc" ] && [ ! -e "$HOME_DIR/.gitconfig" ]; then
  ok "Esc 取消未写入，退出码为 0"
else
  bad "Esc 应取消且不写入（rc=$rc，输出：$out）"
fi

# 下方向键后空格：勾选第二个条目，只写入 gitconfig
head_ "下方向键后空格勾选第二个条目"
new_pick_home
out="$(run_pick $'\033[B \n' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected_gitconfig" "$HOME_DIR/.gitconfig" && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "方向键下移后空格只写入 gitconfig"
else
  bad "下方向键后空格应只勾选第二个条目（rc=$rc，输出：$out）"
fi

# j/k 与方向键等效：j 下移后空格勾选第二个条目
head_ "j 下移后空格勾选第二个条目"
new_pick_home
out="$(run_pick $'j \n' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected_gitconfig" "$HOME_DIR/.gitconfig" && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "j 与下方向键等效"
else
  bad "j 应下移光标（rc=$rc，输出：$out）"
fi

# 选中的条目写入失败（目标是目录）时：其余条目照常写入，退出码非零
head_ "选中的条目写入失败时退出码非零"
new_pick_home
mkdir -p "$HOME_DIR/.gitconfig"
out="$(run_pick $'a\n' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" && [ -d "$HOME_DIR/.gitconfig" ]; then
  ok "写入失败时退出码非零，失败的目标保持原样，其余条目已写入"
else
  bad "写入失败时应非零退出并列出失败条目（rc=$rc，输出：$out）"
fi

# Ctrl-D 视为取消：不写入，退出码为 0
head_ "Ctrl-D 视为取消：不写入，退出码为 0"
new_pick_home
out="$(run_pick $'\004' 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME_DIR/.zshrc" ] && [ ! -e "$HOME_DIR/.gitconfig" ]; then
  ok "Ctrl-D 取消，未写入，退出码为 0"
else
  bad "Ctrl-D 应取消且不写入（rc=$rc，输出：$out）"
fi

# 非交互（标准输入不是 TTY）且未指定 --yes 时，拒绝写入
head_ "非交互且未指定 --yes 时拒绝写入"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(cairn_env "$SHELL_BIN" "$CAIRN" pull </dev/null 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "非零退出，未写入文件"
else
  bad "非交互且无 --yes 时应拒绝写入（rc=$rc，输出：$out）"
fi

# 按名字选择：只处理指定条目
head_ "指定名字时只处理对应条目"
new_home
put_gist "$TWO_MANIFEST" zshrc.txt "$ZSHRC_CONTENT" gitconfig.txt "$GIT_CONTENT"
run_pull zshrc >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" && [ ! -e "$HOME_DIR/.gitconfig" ]; then
  ok "只写入指定的 zshrc，未触及 gitconfig"
else
  bad "指定名字时应只处理该条目（rc=$rc）"
fi

head_ "不带名字时处理清单中全部条目"
new_home
put_gist "$TWO_MANIFEST" zshrc.txt "$ZSHRC_CONTENT" gitconfig.txt "$GIT_CONTENT"
run_pull >/dev/null 2>&1
rc=$?
printf '%s' "$GIT_CONTENT" >"${ROOT}/expected_git"
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" &&
  cmp -s "${ROOT}/expected_git" "$HOME_DIR/.gitconfig"; then
  ok "两个条目都被写入"
else
  bad "不带名字时应处理全部条目（rc=$rc）"
fi

head_ "指定多个名字时处理这些条目"
new_home
put_gist "$TWO_MANIFEST" zshrc.txt "$ZSHRC_CONTENT" gitconfig.txt "$GIT_CONTENT"
run_pull gitconfig zshrc >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc" &&
  cmp -s "${ROOT}/expected_git" "$HOME_DIR/.gitconfig"; then
  ok "多个名字都被处理"
else
  bad "指定多个名字时应都被处理（rc=$rc）"
fi

head_ "指定不存在的名字时报错，且不写入"
new_home
put_gist "$TWO_MANIFEST" zshrc.txt "$ZSHRC_CONTENT" gitconfig.txt "$GIT_CONTENT"
out="$(run_pull zshrc nosuch 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/.zshrc" ]; then
  ok "非零退出，且在写入前退出（合法的 zshrc 也未写入）"
else
  bad "不存在的名字应在写入前报错（rc=$rc，输出：$out）"
fi

# entries 为空：无操作，退出码为 0
head_ "entries 为空时无操作，退出码为 0"
new_home
put_gist '{"entries":{}}' zshrc.txt "$ZSHRC_CONTENT"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(find "$HOME_DIR" -type f)" ]; then
  ok "空 entries 退出码为 0，未写入"
else
  bad "空 entries 应为无操作（rc=$rc，输出：$out）"
fi

# merge 策略（JSON）：远程键覆盖本地同名键（含嵌套对象的深度合并），本地独有键保留
MERGE_MANIFEST='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json"}}}'
head_ "merge 远程键覆盖同名键（深度），本地独有键保留"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"editor":{"fontSize":14},"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' '{"editor":{"fontSize":12,"tabSize":2},"theme":"light","keep":true}' >"$HOME_DIR/.cfg/settings.json"
printf '%s\n' '{' '  "editor": {' '    "fontSize": 14,' '    "tabSize": 2' '  },' '  "theme": "dark",' '  "keep": true' '}' >"${ROOT}/expected_merge"
run_pull >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected_merge" "$HOME_DIR/.cfg/settings.json"; then
  ok "远程覆盖同名键（含嵌套），本地独有键保留，输出为 2 空格缩进 JSON"
else
  bad "merge 应按深度合并（rc=$rc）"
fi

# 数组整体替换：远程数组取代本地数组，不追加、不按元素合并
head_ "merge 数组整体替换"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"list":[9]}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' '{"list":[1,2,3],"n":1}' >"$HOME_DIR/.cfg/settings.json"
printf '%s\n' '{' '  "list": [' '    9' '  ],' '  "n": 1' '}' >"${ROOT}/expected_array"
run_pull >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected_array" "$HOME_DIR/.cfg/settings.json"; then
  ok "远程数组整体取代本地数组"
else
  bad "数组应整体替换（rc=$rc）"
fi

# 目标文件不存在时直接创建，内容为远程片段
head_ "merge 目标不存在时创建为远程片段的内容"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"a":{"b":1},"c":"x"}'
printf '%s\n' '{' '  "a": {' '    "b": 1' '  },' '  "c": "x"' '}' >"${ROOT}/expected_create"
run_pull >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected_create" "$HOME_DIR/.cfg/settings.json"; then
  ok "目标不存在时创建，内容为远程片段"
else
  bad "目标不存在时应创建文件（rc=$rc）"
fi

# 合并前备份原文件；本地文件不是合法 JSON 时失败，不备份也不写入
head_ "merge 合并前备份原文件"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' '{"theme":"light"}' >"$HOME_DIR/.cfg/settings.json"
printf '%s' '{"theme":"light"}' >"${ROOT}/old_merge"
run_pull >/dev/null 2>&1
rc=$?
bak_list="$(find "$HOME_DIR/.local/state/cairn/backup" -maxdepth 1 -type f 2>/dev/null)"
bak="$(printf '%s\n' "$bak_list" | head -n 1)"
if [ "$rc" -eq 0 ] && [ -n "$bak" ] && [ "$(printf '%s\n' "$bak_list" | grep -c .)" -eq 1 ] &&
  cmp -s "${ROOT}/old_merge" "$bak"; then
  ok "合并前备份了原文件内容"
else
  bad "merge 前应备份原文件（rc=$rc，备份：${bak_list:-无}）"
fi

head_ "merge 目标不是合法 JSON 时失败，不备份也不写入"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' 'not json {' >"$HOME_DIR/.cfg/settings.json"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$HOME_DIR/.cfg/settings.json")" = 'not json {' ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "非法 JSON 时报错，目标与备份目录均未改动"
else
  bad "非法 JSON 应报错且不写入（rc=$rc，输出：$out）"
fi

# 目标根是数组（非对象）时 merge 失败，不备份也不写入（JSON 与 JSONC 行为一致）
head_ "merge json 目标根为数组时失败，不备份也不写入"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' '[1,2,3]' >"$HOME_DIR/.cfg/settings.json"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$HOME_DIR/.cfg/settings.json")" = '[1,2,3]' ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "JSON 根为数组时报错，目标与备份目录均未改动"
else
  bad "JSON 根为数组时应报错且不写入（rc=$rc，输出：$out）"
fi

# 交互清单中取消勾选（n 后回车）时，merge 目标保持原样
head_ "merge 交互取消勾选时不改动目标文件"
new_home
put_gist "$MERGE_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' '{"theme":"light"}' >"$HOME_DIR/.cfg/settings.json"
out="$(run_pick $'n\n' 2>&1)"
if [ "$(cat "$HOME_DIR/.cfg/settings.json")" = '{"theme":"light"}' ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "取消勾选时不合并、不备份、不写入"
else
  bad "取消勾选的 merge 不应改动文件（输出：$out）"
fi

# merge 策略（JSONC）：语义与 JSON 相同；目标中的注释保留。比较时把结果规范化为排序后的紧凑 JSON
jsonc_norm() {
  node -e 'process.stdout.write(JSON.stringify(require("jsonc-parser").parse(require("fs").readFileSync(process.argv[1], "utf8"))))' "$1" | jq -S -c .
}
JSONC_MANIFEST='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.jsonc"},"strategy":"merge","format":"jsonc"}}}'
head_ "merge jsonc 语义与 json 一致，目标中的注释保留"
new_home
put_gist "$JSONC_MANIFEST" settings.json '{"editor":{"fontSize":14},"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
cat >"$HOME_DIR/.cfg/settings.jsonc" <<'EOF'
// 本地说明
{
  // 字体设置
  "editor": {
    "fontSize": 12,
    "tabSize": 2, // 制表宽度
  },
  "theme": "light",
  "keep": true
}
EOF
run_pull >/dev/null 2>&1
rc=$?
got="$(jsonc_norm "$HOME_DIR/.cfg/settings.jsonc" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"editor":{"fontSize":14,"tabSize":2},"keep":true,"theme":"dark"}' ] &&
  grep -q '// 本地说明' "$HOME_DIR/.cfg/settings.jsonc" &&
  grep -q '// 字体设置' "$HOME_DIR/.cfg/settings.jsonc" &&
  grep -q '// 制表宽度' "$HOME_DIR/.cfg/settings.jsonc"; then
  ok "远程键覆盖同名键，本地独有键保留，注释保留"
else
  bad "merge jsonc 结果不正确（rc=$rc，结果：${got:-无}）"
fi

head_ "merge jsonc 数组整体替换"
new_home
put_gist "$JSONC_MANIFEST" settings.json '{"list":[9]}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' '// 数组说明' '{"list":[1,2,3],"n":1}' >"$HOME_DIR/.cfg/settings.jsonc"
run_pull >/dev/null 2>&1
rc=$?
got="$(jsonc_norm "$HOME_DIR/.cfg/settings.jsonc" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"list":[9],"n":1}' ] && grep -q '// 数组说明' "$HOME_DIR/.cfg/settings.jsonc"; then
  ok "远程数组整体取代本地数组，注释保留"
else
  bad "jsonc 数组应整体替换（rc=$rc，结果：${got:-无}）"
fi

head_ "merge jsonc 目标不存在时创建为远程片段的内容"
new_home
put_gist "$JSONC_MANIFEST" settings.json '{"a":{"b":1},"c":"x"}'
run_pull >/dev/null 2>&1
rc=$?
got="$(jsonc_norm "$HOME_DIR/.cfg/settings.jsonc" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"a":{"b":1},"c":"x"}' ]; then
  ok "目标不存在时创建"
else
  bad "jsonc 目标不存在时应创建文件（rc=$rc，结果：${got:-无}）"
fi

head_ "merge jsonc 目标根为数组时失败，不备份也不写入（与 JSON 一致）"
new_home
put_gist "$JSONC_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' '// 数组根' '[1,2,3]' >"$HOME_DIR/.cfg/settings.jsonc"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$HOME_DIR/.cfg/settings.jsonc")" = "$(printf '%s\n' '// 数组根' '[1,2,3]')" ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "JSONC 根为数组时报错，目标与备份目录均未改动"
else
  bad "JSONC 根为数组时应报错且不写入（rc=$rc，输出：$out）"
fi

head_ "merge jsonc 目标不是合法 JSONC 时失败，不备份也不写入"
new_home
put_gist "$JSONC_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' 'not jsonc {' >"$HOME_DIR/.cfg/settings.jsonc"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$HOME_DIR/.cfg/settings.jsonc")" = 'not jsonc {' ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "非法 JSONC 时报错，目标与备份目录均未改动"
else
  bad "非法 JSONC 应报错且不写入（rc=$rc，输出：$out）"
fi

head_ "merge jsonc 缺少 jsonc-parser 时给出安装提示，且不写入"
new_home
put_gist "$JSONC_MANIFEST" settings.json '{"theme":"dark"}'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' '{"theme":"light"}' >"$HOME_DIR/.cfg/settings.jsonc"
out="$(NODE_PATH="${ROOT}/no-such-modules" run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'jsonc-parser' &&
  [ "$(cat "$HOME_DIR/.cfg/settings.jsonc")" = '{"theme":"light"}' ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "缺少依赖时提示 jsonc-parser，且不写入"
else
  bad "缺少 jsonc-parser 应给出提示（rc=$rc，输出：$out）"
fi

# merge 策略（YAML）：语义与 JSON 相同；目标中的注释保留。比较时把结果规范化为排序后的紧凑 JSON（yq 输出）
yaml_norm() {
  yq -o=json -I=0 '.' "$1" | jq -S -c .
}
YAML_MANIFEST='{"entries":{"settings":{"remote":"settings.yaml","path":{"linux":"~/.cfg/settings.yaml"},"strategy":"merge","format":"yaml"}}}'
head_ "merge yaml 语义与 json 一致，目标中的注释保留"
new_home
put_gist "$YAML_MANIFEST" settings.yaml $'editor:\n  fontSize: 14\ntheme: dark\n'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' '# 本地说明' 'editor:' '  fontSize: 12 # 字号' '  tabSize: 2' 'theme: light' 'keep: true' >"$HOME_DIR/.cfg/settings.yaml"
run_pull >/dev/null 2>&1
rc=$?
got="$(yaml_norm "$HOME_DIR/.cfg/settings.yaml" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"editor":{"fontSize":14,"tabSize":2},"keep":true,"theme":"dark"}' ] &&
  grep -q '# 本地说明' "$HOME_DIR/.cfg/settings.yaml" && grep -q '# 字号' "$HOME_DIR/.cfg/settings.yaml"; then
  ok "远程键覆盖同名键，本地独有键保留，注释保留"
else
  bad "merge yaml 结果不正确（rc=$rc，结果：${got:-无}）"
fi

head_ "merge yaml 数组整体替换"
new_home
put_gist "$YAML_MANIFEST" settings.yaml $'list:\n  - 9\n'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' '# 数组说明' 'list:' '  - 1' '  - 2' '  - 3' 'n: 1' >"$HOME_DIR/.cfg/settings.yaml"
run_pull >/dev/null 2>&1
rc=$?
got="$(yaml_norm "$HOME_DIR/.cfg/settings.yaml" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"list":[9],"n":1}' ] && grep -q '# 数组说明' "$HOME_DIR/.cfg/settings.yaml"; then
  ok "远程数组整体取代本地数组，注释保留"
else
  bad "yaml 数组应整体替换（rc=$rc，结果：${got:-无}）"
fi

head_ "merge yaml 目标不存在时创建为远程片段的内容"
new_home
put_gist "$YAML_MANIFEST" settings.yaml $'a:\n  b: 1\nc: x\n'
run_pull >/dev/null 2>&1
rc=$?
got="$(yaml_norm "$HOME_DIR/.cfg/settings.yaml" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"a":{"b":1},"c":"x"}' ]; then
  ok "目标不存在时创建"
else
  bad "yaml 目标不存在时应创建文件（rc=$rc，结果：${got:-无}）"
fi

head_ "merge yaml 目标不是合法 YAML 时失败，不备份也不写入"
new_home
put_gist "$YAML_MANIFEST" settings.yaml $'theme: dark\n'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' 'a: [' >"$HOME_DIR/.cfg/settings.yaml"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$HOME_DIR/.cfg/settings.yaml")" = 'a: [' ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "非法 YAML 时报错，目标与备份目录均未改动"
else
  bad "非法 YAML 应报错且不写入（rc=$rc，输出：$out）"
fi

head_ "merge yaml 的 yq 不是 mikefarah 版时给出提示，且不写入"
new_home
put_gist "$YAML_MANIFEST" settings.yaml $'theme: dark\n'
mkdir -p "$HOME_DIR/.cfg" "${ROOT}/fake-yq"
printf '%s\n' '#!/usr/bin/env bash' 'echo "yq 3.4.1"' >"${ROOT}/fake-yq/yq"
chmod +x "${ROOT}/fake-yq/yq"
printf '%s\n' 'theme: light' >"$HOME_DIR/.cfg/settings.yaml"
out="$(PATH="${ROOT}/fake-yq:$PATH" run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'mikefarah' &&
  [ "$(cat "$HOME_DIR/.cfg/settings.yaml")" = 'theme: light' ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "非 mikefarah 版 yq 时提示安装正确版本，且不写入"
else
  bad "非 mikefarah 版 yq 应给出提示（rc=$rc，输出：$out）"
fi

# merge 策略（TOML）：语义与 JSON 一致，远程键覆盖同名键（含表内），本地独有键保留，数组整体替换
# 语义用 tomllib 读回校验，不依赖输出的具体排版
TOML_MANIFEST='{"entries":{"tool":{"remote":"tool.toml","path":{"linux":"~/.cfg/tool.toml"},"strategy":"merge","format":"toml"}}}'
toml_semantics() {
  python3 -c 'import sys, tomllib, json; print(json.dumps(tomllib.load(open(sys.argv[1], "rb")), sort_keys=True))' "$1"
}
head_ "merge TOML 远程键覆盖同名键（含表内），本地独有键保留，数组整体替换"
new_home
put_gist "$TOML_MANIFEST" tool.toml $'theme = "dark"\nlist = [9]\n\n[editor]\nfont_size = 14\n'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' 'theme = "light"' 'keep = true' 'list = [1, 2, 3]' '' '[editor]' 'font_size = 12' 'tab_size = 2' >"$HOME_DIR/.cfg/tool.toml"
run_pull >/dev/null 2>&1
rc=$?
want='{"editor": {"font_size": 14, "tab_size": 2}, "keep": true, "list": [9], "theme": "dark"}'
got="$(toml_semantics "$HOME_DIR/.cfg/tool.toml" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
  ok "TOML 深度合并：远程覆盖、本地独有保留、数组整体替换"
else
  bad "TOML merge 语义不符（rc=$rc，结果：${got:-无}）"
fi

# merge TOML 保留目标文件中的注释（独立注释行、行尾注释、表头注释）
head_ "merge TOML 合并后保留目标文件中的注释"
new_home
put_gist "$TOML_MANIFEST" tool.toml $'theme = "dark"\n\n[editor]\nfont_size = 14\n'
mkdir -p "$HOME_DIR/.cfg"
printf '%s\n' '# 本地说明：主题颜色' 'theme = "light" # 行尾注释' 'keep = true' '' '# 编辑器设置' '[editor]' 'font_size = 12' >"$HOME_DIR/.cfg/tool.toml"
run_pull >/dev/null 2>&1
rc=$?
got="$(toml_semantics "$HOME_DIR/.cfg/tool.toml" 2>/dev/null)"
keep_ok=1
for c in '# 本地说明：主题颜色' '# 行尾注释' '# 编辑器设置'; do
  grep -qF "$c" "$HOME_DIR/.cfg/tool.toml" || keep_ok=0
done
if [ "$rc" -eq 0 ] && [ "$keep_ok" -eq 1 ] && [ "$got" = '{"editor": {"font_size": 14}, "keep": true, "theme": "dark"}' ]; then
  ok "合并后三处注释全部保留，且值已按远程更新"
else
  bad "TOML 合并应保留注释（rc=$rc，注释保留：$keep_ok，结果：${got:-无}）"
fi

# TOML 目标不存在时直接创建；目标不是合法 TOML 时失败，不备份也不写入
head_ "merge TOML 目标不存在时创建为远程片段的内容"
new_home
put_gist "$TOML_MANIFEST" tool.toml $'[editor]\nfont_size = 14\n'
run_pull >/dev/null 2>&1
rc=$?
got="$(toml_semantics "$HOME_DIR/.cfg/tool.toml" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"editor": {"font_size": 14}}' ]; then
  ok "目标不存在时创建 TOML 文件"
else
  bad "TOML 目标不存在时应创建（rc=$rc，结果：${got:-无}）"
fi

head_ "merge TOML 目标不是合法 TOML 时失败，不备份也不写入"
new_home
put_gist "$TOML_MANIFEST" tool.toml $'theme = "dark"\n'
mkdir -p "$HOME_DIR/.cfg"
printf '%s' 'theme = [' >"$HOME_DIR/.cfg/tool.toml"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$HOME_DIR/.cfg/tool.toml")" = 'theme = [' ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "非法 TOML 时报错，目标与备份目录均未改动"
else
  bad "非法 TOML 应报错且不写入（rc=$rc，输出：$out）"
fi

# 依赖按需检查：PATH 只含系统目录（不含 ~/.local/bin 等处的 yq），用于模拟缺少可选工具
run_pull_path() {
  cairn_env PATH=/usr/bin:/bin "$SHELL_BIN" "$CAIRN" pull --yes </dev/null
}

# merge 数组合并策略（rules）：JSON、JSONC、YAML、TOML 规则一致。
# 用法：check_merge 描述 清单 远程文件名 远程内容 目标相对路径 本地内容 期望 规范化函数
check_merge() {
  head_ "$1"
  new_home
  put_gist "$2" "$3" "$4"
  mkdir -p "$(dirname "$HOME_DIR/.cfg/$5")"
  printf '%s' "$6" >"$HOME_DIR/.cfg/$5"
  run_pull >/dev/null 2>&1
  rc=$?
  got="$($8 "$HOME_DIR/.cfg/$5" 2>/dev/null)"
  if [ "$rc" -eq 0 ] && [ "$got" = "$7" ]; then
    ok "$1"
  else
    bad "$1（rc=$rc，结果：${got:-无}）"
  fi
}
json_norm() {
  jq -S -c . "$1"
}

JSON_UNION='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge json rules.default 为 override：本地顺序保留，远程新增项追加，相同值只留一份（含远程内部重复与对象数组）" \
  "$JSON_UNION" settings.json '{"tags":["b","c","c"],"items":[{"id":1},{"id":2},{"id":2}]}' settings.json \
  '{"tags":["z","a","b"],"items":[{"id":1}],"n":1}' \
  '{"items":[{"id":1},{"id":2}],"n":1,"tags":["z","a","b","c"]}' json_norm

check_merge "merge json allow 与 deny 中同值的项两边都保留，不做内容判断" \
  "$JSON_UNION" settings.json '{"permissions":{"allow":["y"],"deny":["y"]}}' settings.json \
  '{"permissions":{"allow":["x"],"deny":["w"]}}' \
  '{"permissions":{"allow":["x","y"],"deny":["w","y"]}}' json_norm

JSON_PATHS='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"arrays":{"default":"override","paths":{"cfg.pinned":"replace"}}}}}}'
check_merge "merge json rules.paths 精确命中完整路径（优先于 default），未命中的路径用 default" \
  "$JSON_PATHS" settings.json '{"cfg":{"pinned":[3],"tags":[2,3]},"top":[2]}' settings.json \
  '{"cfg":{"pinned":[1,2],"tags":[1,2]},"top":[1]}' \
  '{"cfg":{"pinned":[3],"tags":[1,2,3]},"top":[1,2]}' json_norm

JSON_WILDCARD='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"arrays":{"paths":{"cfg.*":"override"}}}}}}'
check_merge "merge json 缺省为 replace；paths 不支持通配符，cfg.* 不命中 cfg.tags" \
  "$JSON_WILDCARD" settings.json '{"cfg":{"tags":[2,3]},"top":[2]}' settings.json \
  '{"cfg":{"tags":[1,2]},"top":[1]}' \
  '{"cfg":{"tags":[2,3]},"top":[2]}' json_norm

head_ "merge json 目标不存在时，override 数组的远程内部重复同样去掉"
new_home
put_gist "$JSON_UNION" settings.json '{"tags":["b","c","c"]}'
run_pull >/dev/null 2>&1
rc=$?
got="$(json_norm "$HOME_DIR/.cfg/settings.json" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$got" = '{"tags":["b","c"]}' ]; then
  ok "目标不存在时创建的内容中，override 数组已去重"
else
  bad "目标不存在时 override 应去重（rc=$rc，结果：${got:-无}）"
fi

JSONC_UNION='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.jsonc"},"strategy":"merge","format":"jsonc","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge jsonc default 为 override：语义与 json 一致" \
  "$JSONC_UNION" settings.json '{"tags":["b","c","c"],"items":[{"id":1},{"id":2},{"id":2}]}' settings.jsonc \
  $'// 本地说明\n{\n  // 标签\n  "tags": ["z", "a", "b"],\n  "items": [{"id": 1}],\n}\n' \
  '{"items":[{"id":1},{"id":2}],"tags":["z","a","b","c"]}' jsonc_norm

JSONC_PATHS='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.jsonc"},"strategy":"merge","format":"jsonc","rules":{"arrays":{"paths":{"cfg.tags":"override"}}}}}}'
check_merge "merge jsonc paths 精确命中单个数组" \
  "$JSONC_PATHS" settings.json '{"cfg":{"tags":[2,3,3]},"top":[2]}' settings.jsonc \
  '{"cfg":{"tags":[1,2]},"top":[1]}' \
  '{"cfg":{"tags":[1,2,3]},"top":[2]}' jsonc_norm

YAML_UNION='{"entries":{"settings":{"remote":"settings.yaml","path":{"linux":"~/.cfg/settings.yaml"},"strategy":"merge","format":"yaml","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge yaml default 为 override：语义与 json 一致" \
  "$YAML_UNION" settings.yaml $'tags:\n  - b\n  - c\n  - c\nitems:\n  - id: 1\n  - id: 2\n  - id: 2\n' settings.yaml \
  $'tags:\n  - z\n  - a\n  - b\nitems:\n  - id: 1\n' \
  '{"items":[{"id":1},{"id":2}],"tags":["z","a","b","c"]}' yaml_norm

YAML_PATHS='{"entries":{"settings":{"remote":"settings.yaml","path":{"linux":"~/.cfg/settings.yaml"},"strategy":"merge","format":"yaml","rules":{"arrays":{"paths":{"cfg.tags":"override"}}}}}}'
check_merge "merge yaml paths 精确命中单个数组" \
  "$YAML_PATHS" settings.yaml $'cfg:\n  tags: [2, 3, 3]\n  pinned: [4]\n' settings.yaml \
  $'cfg:\n  tags: [1, 2]\n  pinned: [1]\n' \
  '{"cfg":{"pinned":[4],"tags":[1,2,3]}}' yaml_norm

TOML_UNION='{"entries":{"tool":{"remote":"tool.toml","path":{"linux":"~/.cfg/tool.toml"},"strategy":"merge","format":"toml","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge toml default 为 override：语义与 json 一致" \
  "$TOML_UNION" tool.toml $'tags = ["b", "c", "c"]\nitems = [{id = 1}, {id = 2}, {id = 2}]\n' tool.toml \
  $'tags = ["z", "a", "b"]\nitems = [{id = 1}]\n' \
  '{"items": [{"id": 1}, {"id": 2}], "tags": ["z", "a", "b", "c"]}' toml_semantics

TOML_PATHS='{"entries":{"tool":{"remote":"tool.toml","path":{"linux":"~/.cfg/tool.toml"},"strategy":"merge","format":"toml","rules":{"arrays":{"paths":{"cfg.tags":"override"}}}}}}'
check_merge "merge toml paths 精确命中单个数组" \
  "$TOML_PATHS" tool.toml $'[cfg]\ntags = [2, 3, 3]\npinned = [4]\n' tool.toml \
  $'[cfg]\ntags = [1, 2]\npinned = [1]\n' \
  '{"cfg": {"pinned": [4], "tags": [1, 2, 3]}}' toml_semantics

TOML_BOOL_NUM='{"entries":{"tool":{"remote":"tool.toml","path":{"linux":"~/.cfg/tool.toml"},"strategy":"merge","format":"toml","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge toml override：1 与 true 是不同的值，都保留" \
  "$TOML_BOOL_NUM" tool.toml $'tags = [true]\n' tool.toml \
  $'tags = [1]\n' \
  '{"tags": [1, true]}' toml_semantics

check_merge "merge toml override：0 与 false 是不同的值，都保留" \
  "$TOML_BOOL_NUM" tool.toml $'tags = [false]\n' tool.toml \
  $'tags = [0]\n' \
  '{"tags": [0, false]}' toml_semantics

# 数组项类型不同（数字与布尔）时 override 不得误去重：JSON、JSONC、YAML 的结果需一致
TYPED_UNION_JSON='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge json override：数字与布尔不互相去重" \
  "$TYPED_UNION_JSON" settings.json '{"tags":[true,false]}' settings.json \
  '{"tags":[1,0]}' \
  '{"tags":[1,0,true,false]}' json_norm

TYPED_UNION_JSONC='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.jsonc"},"strategy":"merge","format":"jsonc","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge jsonc override：数字与布尔不互相去重" \
  "$TYPED_UNION_JSONC" settings.json '{"tags":[true,false]}' settings.jsonc \
  '{"tags":[1,0]}' \
  '{"tags":[1,0,true,false]}' jsonc_norm

TYPED_UNION_YAML='{"entries":{"settings":{"remote":"settings.yaml","path":{"linux":"~/.cfg/settings.yaml"},"strategy":"merge","format":"yaml","rules":{"arrays":{"default":"override"}}}}}'
check_merge "merge yaml override：数字与布尔不互相去重" \
  "$TYPED_UNION_YAML" settings.yaml $'tags:\n  - true\n  - false\n' settings.yaml \
  $'tags:\n  - 1\n  - 0\n' \
  '{"tags":[1,0,true,false]}' yaml_norm

# 清单 Schema：rules 的取值与适用范围
schema_case() {
  head_ "$1"
  printf '%s' "$2" >"${ROOT}/schema-case.json"
  out="$(python3 -I "$VALIDATE" "$SCHEMA" "${ROOT}/schema-case.json" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$3" ]; then
    ok "$1（退出码 $3）"
  else
    bad "$1（rc=$rc，输出：$out）"
  fi
}
SCHEMA_ENTRY_MERGE='"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json"'
schema_case "清单 Schema：merge 条目的 rules 取值合法时通过" \
  "{\"entries\":{$SCHEMA_ENTRY_MERGE,\"rules\":{\"arrays\":{\"default\":\"override\",\"paths\":{\"a.b\":\"replace\"}}}}}}" 0
schema_case "清单 Schema：rules.default 取值为 union 时失败" \
  "{\"entries\":{$SCHEMA_ENTRY_MERGE,\"rules\":{\"arrays\":{\"default\":\"union\"}}}}}" 1
schema_case "清单 Schema：rules.paths 的值为 union 时失败" \
  "{\"entries\":{$SCHEMA_ENTRY_MERGE,\"rules\":{\"arrays\":{\"paths\":{\"a.b\":\"union\"}}}}}}" 1
schema_case "清单 Schema：rules 含未知子键时失败" \
  "{\"entries\":{$SCHEMA_ENTRY_MERGE,\"rules\":{\"arrays\":{\"arrays\":\"override\"}}}}}" 1
schema_case "清单 Schema：replace 条目带 rules 时失败（仅对 merge 有效）" \
  "{\"entries\":{\"zshrc\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.zshrc\"},\"strategy\":\"replace\",\"rules\":{\"arrays\":{\"default\":\"override\"}}}}}" 1

reject_case "merge 条目 rules.default 取值非法时报错，且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"merge\",\"format\":\"json\",\"rules\":{\"arrays\":{\"default\":\"union\"}}}}}" \
  '条目 bad.*rules'

reject_case "merge 条目 rules.paths 的值非法时报错，且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"merge\",\"format\":\"json\",\"rules\":{\"arrays\":{\"paths\":{\"a\":\"union\"}}}}}}" \
  '条目 bad.*rules'

head_ "仅 replace 条目时，缺少 yq 与 tomlkit 也能成功拉取"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
if PATH=/usr/bin:/bin command -v yq >/dev/null 2>&1; then
  bad "前提不满足：/usr/bin:/bin 中不应存在 yq"
else
  run_pull_path >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
    ok "replace 条目不要求 yq 或 tomlkit"
  else
    bad "仅 replace 时不应因缺少 yq 或 tomlkit 失败（rc=$rc）"
  fi
fi

# 模拟未安装 tomlkit：PYTHONPATH 中的同名模块直接抛出 ImportError
head_ "merge TOML 缺少 tomlkit 时报错并给出安装提示，且不写入"
new_home
put_gist "$TOML_MANIFEST" tool.toml $'theme = "dark"\n'
mkdir -p "$HOME_DIR/.cfg" "${ROOT}/shim-toml"
printf '%s' 'theme = "light"' >"$HOME_DIR/.cfg/tool.toml"
printf '%s\n' 'raise ImportError("模拟未安装")' >"${ROOT}/shim-toml/tomlkit.py"
out="$(cairn_env PATH=/usr/bin:/bin PYTHONPATH="${ROOT}/shim-toml" "$SHELL_BIN" "$CAIRN" pull --yes </dev/null 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'tomlkit' && printf '%s' "$out" | grep -q '请先安装' &&
  [ "$(cat "$HOME_DIR/.cfg/tool.toml")" = 'theme = "light"' ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "缺少 tomlkit 时给出安装提示，目标与备份均未改动"
else
  bad "缺少 tomlkit 时应报错并提示安装（rc=$rc，输出：$out）"
fi

# 用到 yaml 的 merge 条目而缺少 yq：给出 yq 的安装提示
YAML_MANIFEST='{"entries":{"cfg":{"remote":"cfg.yaml","path":{"linux":"~/.cfg/cfg.yaml"},"strategy":"merge","format":"yaml"}}}'
head_ "merge YAML 缺少 yq 时报错并给出安装提示"
new_home
put_gist "$YAML_MANIFEST" cfg.yaml $'a: 1\n'
out="$(run_pull_path 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'yq' && printf '%s' "$out" | grep -q '请先安装' && [ ! -e "$HOME_DIR/.cfg/cfg.yaml" ]; then
  ok "缺少 yq 时给出安装提示，且不写入"
else
  bad "缺少 yq 时应报错并提示安装（rc=$rc，输出：$out）"
fi

# 通过 HTTP 分发：脚本从本地 HTTP 服务取回（curl 或 wget），再用取回的副本执行一次 pull
# 文件服务只托管临时目录中的 cairn.sh 副本，端口由系统分配，避免与其他测试冲突
DIST="${ROOT}/dist"
mkdir -p "$DIST"
cp "$CAIRN" "${DIST}/cairn.sh"
HTTP_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
HTTP_BASE="http://127.0.0.1:${HTTP_PORT}"
python3 -m http.server --bind 127.0.0.1 --directory "$DIST" "$HTTP_PORT" >/dev/null 2>&1 &
HTTP_PID=$!
i=0
until curl -s -o /dev/null "${HTTP_BASE}/cairn.sh" || [ "$i" -ge 50 ]; do
  sleep 0.1
  i=$((i + 1))
done

# 用 curl 或 wget（$1）从 HTTP 服务取回脚本到 $2；清空环境，避免代理变量干扰本地请求
fetch_script() {
  case "$1" in
    curl) env -i PATH="$PATH" HOME="$HOME_DIR" curl -fsSL "${HTTP_BASE}/cairn.sh" -o "$2" ;;
    wget) env -i PATH="$PATH" HOME="$HOME_DIR" wget -q -O "$2" "${HTTP_BASE}/cairn.sh" ;;
  esac
}

# 运行取回的脚本副本（$1）执行 pull，其余参数同 run_pull
run_pull_script() {
  local script="$1"
  shift
  cairn_env "$SHELL_BIN" "$script" pull --yes "$@" </dev/null
}

head_ "通过 curl 获取脚本后拉取一次"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
fetched="${ROOT}/fetched-curl.sh"
fetch_script curl "$fetched"
frc=$?
run_pull_script "$fetched" >/dev/null 2>&1
rc=$?
if [ "$frc" -eq 0 ] && cmp -s "$CAIRN" "$fetched" && [ "$rc" -eq 0 ] &&
  cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "curl 取回的脚本与源一致，拉取成功"
else
  bad "通过 curl 获取后应能拉取（取回 rc=$frc，拉取 rc=$rc）"
fi

head_ "通过 wget 获取脚本后拉取一次"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
fetched="${ROOT}/fetched-wget.sh"
fetch_script wget "$fetched"
frc=$?
run_pull_script "$fetched" >/dev/null 2>&1
rc=$?
if [ "$frc" -eq 0 ] && cmp -s "$CAIRN" "$fetched" && [ "$rc" -eq 0 ] &&
  cmp -s "${ROOT}/expected" "$HOME_DIR/.zshrc"; then
  ok "wget 取回的脚本与源一致，拉取成功"
else
  bad "通过 wget 获取后应能拉取（取回 rc=$frc，拉取 rc=$rc）"
fi

# 目标是符号链接（如指向 dotfiles 仓库）时，应更新链接指向的真实文件，保留链接本身
head_ "目标为符号链接时保留链接，更新其指向的真实文件"
new_home
mkdir -p "$HOME_DIR/dotfiles"
printf 'old\n' >"$HOME_DIR/dotfiles/zshrc"
ln -s "$HOME_DIR/dotfiles/zshrc" "$HOME_DIR/.zshrc"
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
run_pull >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -L "$HOME_DIR/.zshrc" ] && cmp -s "${ROOT}/expected" "$HOME_DIR/dotfiles/zshrc"; then
  ok "链接仍是符号链接，真实文件已更新"
else
  bad "符号链接应被保留并更新真实文件（rc=$rc）"
fi

# 路径规则：前缀、目录目标、越界检查（黑名单）与 --dry-run 输出的真实路径
# 清单只含一个条目；linux 与 macos 使用同一路径
manifest_for() {
  jq -cn --arg p "$1" '{entries: {one: {remote: "zshrc.txt", path: {linux: $p, macos: $p}, strategy: "replace"}}}'
}
# 目标文件内容与远程内容逐字节一致
same_content() {
  printf '%s' "$ZSHRC_CONTENT" | cmp -s - "$1"
}
# 在 HOME/work 中以 Linux 运行写入用例：$1 描述，$2 清单路径（@HOME@ 替换为 HOME），$3 期望写入的文件（相对 HOME）
path_case() {
  head_ "$1"
  new_home
  mkdir -p "$HOME_DIR/work"
  put_gist "$(manifest_for "${2//@HOME@/$HOME_DIR}")" zshrc.txt "$ZSHRC_CONTENT"
  (cd "$HOME_DIR/work" && run_pull) >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ] && same_content "$HOME_DIR/$3"; then
    ok "写入 $3（相对 HOME）"
  else
    bad "应写入 $3（rc=$rc）"
  fi
}
# 越界用例：$1 描述，$2 清单路径（@HOME@ 替换为 HOME），$3 CAIRN_UNAME，$4 报错应指出的黑名单条目，$5 不应被写入的路径
# 期望：非零退出，报错含“黑名单”与条目，未写入任何文件，也未生成备份
blocked_case() {
  head_ "$1"
  new_home
  mkdir -p "$HOME_DIR/work"
  put_gist "$(manifest_for "${2//@HOME@/$HOME_DIR}")" zshrc.txt "$ZSHRC_CONTENT"
  local out rc
  out="$(cd "$HOME_DIR/work" && run_as "$3" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '黑名单' &&
    printf '%s' "$out" | grep -qF -- "$4" &&
    [ ! -e "${5//@HOME@/$HOME_DIR}" ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
    ok "报黑名单并拒绝：$4"
  else
    bad "应因黑名单 $4 拒绝且不写入（rc=$rc，输出：$out）"
  fi
}

path_case "~/x 相对于 HOME" '~/x' 'x'
path_case "./x 相对于运行目录" './x' 'work/x'
path_case "没有前缀的 x/y 相对于运行目录，缺失的目录自动创建" 'x/y' 'work/x/y'
path_case "绝对路径原样使用" '@HOME@/abs/file' 'abs/file'
path_case "~ 作为目录：文件名取 remote" '~' 'zshrc.txt'
path_case ". 作为目录：文件名取 remote" '.' 'work/zshrc.txt'
path_case "以 / 结尾的目录目标，缺失的目录自动创建" '~/out/' 'out/zshrc.txt'

blocked_case "~ 经 .. 逃逸到 /etc 时在写入前拒绝" '~/../../../etc/cairn-test' Linux /etc /etc/cairn-test

head_ "同一清单中有条目越界时，其余条目也不写入"
new_home
mkdir -p "$HOME_DIR/work"
MIX_MANIFEST='{"entries":{"ok":{"remote":"zshrc.txt","path":{"linux":"~/ok.txt"},"strategy":"replace"},"bad":{"remote":"zshrc.txt","path":{"linux":"~/../../../etc/cairn-test"},"strategy":"replace"}}}'
put_gist "$MIX_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out="$(cd "$HOME_DIR/work" && run_as Linux 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$HOME_DIR/ok.txt" ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ] &&
  printf '%s' "$out" | grep -q '黑名单'; then
  ok "任一条目越界则整个清单不写入"
else
  bad "越界条目应使整个清单不写入（rc=$rc，输出：$out）"
fi

head_ "符号链接的真实路径落在黑名单中时拒绝写入"
new_home
mkdir -p "$HOME_DIR/work"
ln -s /etc "$HOME_DIR/link-etc"
put_gist "$(manifest_for '~/link-etc/cairn-test')" zshrc.txt "$ZSHRC_CONTENT"
out="$(cd "$HOME_DIR/work" && run_as Linux 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '黑名单' && [ ! -e /etc/cairn-test ] &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "链接指向 /etc，报黑名单并拒绝，未写入"
else
  bad "指向黑名单的符号链接应被拒绝（rc=$rc，输出：$out）"
fi

blocked_case "macOS：/System 下的路径被拒绝" '/System/cairn-test/zshrc' Darwin /System /System/cairn-test/zshrc

head_ "macOS：经指向 /private/etc 的链接解析后被拒绝"
new_home
mkdir -p "$HOME_DIR/work"
ln -s /private/etc "$HOME_DIR/etc-link"
put_gist "$(manifest_for '~/etc-link/cairn-test')" zshrc.txt "$ZSHRC_CONTENT"
out="$(cd "$HOME_DIR/work" && run_as Darwin 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '黑名单' && printf '%s' "$out" | grep -qF '/private/etc' &&
  [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "真实路径 /private/etc 命中黑名单"
else
  bad "macOS 上 /private/etc 应被拒绝（rc=$rc，输出：$out）"
fi

blocked_case "macOS：/private/var/db 被拒绝" '/private/var/db/cairn-test' Darwin /private/var/db /private/var/db/cairn-test

head_ "macOS：/private/var/folders（TMPDIR）不被拦截"
new_home
put_gist "$(manifest_for '/private/var/folders/ab/T/zshrc')" zshrc.txt "$ZSHRC_CONTENT"
out="$(run_as Darwin --dry-run 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '/private/var/folders/ab/T/zshrc'; then
  ok "dry-run 通过，/private/var/folders 未被拦截"
else
  bad "/private/var/folders 不应被拦截（rc=$rc，输出：$out）"
fi

head_ "--dry-run 显示解析后的真实路径（符号链接展开，目录目标含文件名）"
new_home
mkdir -p "$HOME_DIR/real"
ln -s "$HOME_DIR/real" "$HOME_DIR/linkdir"
real_dir="$(cd -P "$HOME_DIR/real" && pwd -P)"
put_gist "$(manifest_for '~/linkdir/')" zshrc.txt "$ZSHRC_CONTENT"
out="$(run_as Linux --dry-run 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$real_dir/zshrc.txt" &&
  [ ! -e "$HOME_DIR/real/zshrc.txt" ]; then
  ok "预览输出真实路径 $real_dir/zshrc.txt，未写入"
else
  bad "预览应输出真实路径（rc=$rc，输出：$out）"
fi

blocked_case "Linux：/opt 被拒绝" '/opt/cairn-test/zshrc' Linux /opt /opt/cairn-test/zshrc

# HOME 之内的路径不受黑名单检查。真正的 /Users/<你> 无法在 Linux 上创建，
# 因此让 HOME 位于 macOS 黑名单条目 /dev 之下（/dev/shm 可写），验证豁免确实生效
head_ "macOS：HOME 之内的路径不受黑名单检查（HOME 位于 /dev 之下）"
HOME_DIR="$(mktemp -d /dev/shm/cairn-home.XXXXXX 2>/dev/null)" || HOME_DIR=""
if [ -z "$HOME_DIR" ]; then
  bad "需要 /dev/shm 可写，以模拟位于黑名单之下的 HOME"
else
  mkdir -p "$HOME_DIR/work"
  ln -s /dev "$HOME_DIR/devlink"
  put_gist "$(manifest_for '~/out/zshrc')" zshrc.txt "$ZSHRC_CONTENT"
  out="$(cd "$HOME_DIR/work" && run_as Darwin 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && same_content "$HOME_DIR/out/zshrc"; then
    ok "HOME 内的路径被接受，未被黑名单拦截"
  else
    bad "HOME 内的路径应被接受（rc=$rc，输出：$out）"
  fi
  # 对照：HOME 内的符号链接若真实路径落在 /dev，仍然拒绝
  put_gist "$(manifest_for '~/devlink/cairn-test')" zshrc.txt "$ZSHRC_CONTENT"
  out="$(cd "$HOME_DIR/work" && run_as Darwin 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '黑名单' && [ ! -e /dev/cairn-test ]; then
    ok "HOME 内的符号链接指向 /dev 时仍被拒绝"
  else
    bad "HOME 内指向黑名单的符号链接应被拒绝（rc=$rc，输出：$out）"
  fi
  rm -rf "$HOME_DIR"
fi

# merge 条目省略 format 时，由 remote 的后缀推断：.json→json，.jsonc→jsonc，.yml/.yaml→yaml，.toml→toml
check_merge "merge 省略 format 时由 .json 后缀推断为 json" \
  '{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge"}}}' \
  settings.json '{"a":2}' settings.json '{"a":1,"keep":true}' '{"a":2,"keep":true}' json_norm

check_merge "merge 省略 format 时由 .jsonc 后缀推断为 jsonc（允许注释）" \
  '{"entries":{"settings":{"remote":"settings.jsonc","path":{"linux":"~/.cfg/settings.jsonc"},"strategy":"merge"}}}' \
  settings.jsonc '{"a":2}' settings.jsonc $'// 注释\n{"a":1,"keep":true}\n' '{"a":2,"keep":true}' jsonc_norm

check_merge "merge 省略 format 时由 .yml 后缀推断为 yaml" \
  '{"entries":{"settings":{"remote":"settings.yml","path":{"linux":"~/.cfg/settings.yml"},"strategy":"merge"}}}' \
  settings.yml $'a: 2\n' settings.yml $'a: 1\nkeep: true\n' '{"a":2,"keep":true}' yaml_norm

check_merge "merge 省略 format 时由 .yaml 后缀推断为 yaml" \
  '{"entries":{"settings":{"remote":"settings.yaml","path":{"linux":"~/.cfg/settings.yaml"},"strategy":"merge"}}}' \
  settings.yaml $'a: 2\n' settings.yaml $'a: 1\nkeep: true\n' '{"a":2,"keep":true}' yaml_norm

check_merge "merge 省略 format 时由 .toml 后缀推断为 toml" \
  '{"entries":{"tool":{"remote":"tool.toml","path":{"linux":"~/.cfg/tool.toml"},"strategy":"merge"}}}' \
  tool.toml 'a = 2' tool.toml $'a = 1\nkeep = true\n' '{"a": 2, "keep": true}' toml_semantics

# 显式 format 优先于后缀：.json 远程声明为 jsonc 时，按 JSONC 解析（允许注释）并保留注释
check_merge "显式 format 优先于后缀：.json 声明为 jsonc 时按 JSONC 合并" \
  '{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"jsonc"}}}' \
  settings.json '{"a":2}' settings.json $'// 注释\n{"a":1}\n' '{"a":2}' jsonc_norm

# rules（对象整块替换）：paths 中的完整点号路径为 replace 时，本地该对象整体替换为远程对象，本地独有的键被删除
OBJ_JSON_PATHS='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"objects":{"paths":{"mcpServers.firefox":"replace"}}}}}}'
check_merge "rules：paths 命中的对象整体替换，本地独有的键被删除（JSON）" \
  "$OBJ_JSON_PATHS" settings.json '{"mcpServers":{"firefox":{"command":"new"}},"theme":"dark"}' settings.json \
  '{"mcpServers":{"firefox":{"command":"old","extra":1},"other":{"x":1}},"theme":"light"}' \
  '{"mcpServers":{"firefox":{"command":"new"},"other":{"x":1}},"theme":"dark"}' json_norm

# rules 缺省为 merge：本地独有的键保留（与未声明 rules 相同）
OBJ_JSON_DEFAULT='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"objects":{"default":"override"}}}}}'
check_merge "rules.objects.default 为 override 时，本地独有的键保留（JSON）" \
  "$OBJ_JSON_DEFAULT" settings.json '{"mcpServers":{"firefox":{"command":"new"}},"theme":"dark"}' settings.json \
  '{"mcpServers":{"firefox":{"command":"old","extra":1},"other":{"x":1}},"theme":"light"}' \
  '{"mcpServers":{"firefox":{"command":"new","extra":1},"other":{"x":1}},"theme":"dark"}' json_norm

# paths 只做精确匹配：mcp 与 mcpServers.fire 都不等于 mcpServers.firefox，不替换
OBJ_JSON_NOMATCH='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"objects":{"paths":{"mcp":"replace","mcpServers.fire":"replace"}}}}}}'
check_merge "rules.paths 只精确匹配完整路径，前缀与部分路径不替换（JSON）" \
  "$OBJ_JSON_NOMATCH" settings.json '{"mcpServers":{"firefox":{"command":"new"}}}' settings.json \
  '{"mcpServers":{"firefox":{"command":"old","extra":1}}}' \
  '{"mcpServers":{"firefox":{"command":"new","extra":1}}}' json_norm

# 路径不在远程片段中：不做任何事，本地内容保持原样（这里只改 theme）
OBJ_JSON_ABSENT='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"objects":{"paths":{"mcpServers.firefox":"replace"}}}}}}'
check_merge "rules：远程片段中不存在的路径不产生任何变化（JSON）" \
  "$OBJ_JSON_ABSENT" settings.json '{"theme":"dark"}' settings.json \
  '{"mcpServers":{"firefox":{"command":"old","extra":1}},"theme":"light"}' \
  '{"mcpServers":{"firefox":{"command":"old","extra":1}},"theme":"dark"}' json_norm

# default 为 replace：远程片段中每个与本地对象同名的对象都整体替换（这里 mcpServers 与 editor 都被替换）
OBJ_JSON_DEFAULT_REPLACE='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json","rules":{"objects":{"default":"replace"}}}}}'
check_merge "rules.default 为 replace 时，远程中的对象整体替换（JSON）" \
  "$OBJ_JSON_DEFAULT_REPLACE" settings.json '{"mcpServers":{"firefox":{"command":"new"}},"editor":{"font":2}}' settings.json \
  '{"mcpServers":{"firefox":{"command":"old","extra":1},"other":{"x":1}},"editor":{"font":1,"tab":2},"keep":true}' \
  '{"editor":{"font":2},"keep":true,"mcpServers":{"firefox":{"command":"new"}}}' json_norm

# rules 在 JSONC、YAML、TOML 上语义与 JSON 一致
OBJ_JSONC='{"entries":{"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.jsonc"},"strategy":"merge","format":"jsonc","rules":{"objects":{"paths":{"mcpServers.firefox":"replace"}}}}}}'
check_merge "rules：paths 命中的对象整体替换，本地独有的键被删除（JSONC）" \
  "$OBJ_JSONC" settings.json '{"mcpServers":{"firefox":{"command":"new"}}}' settings.jsonc \
  $'// 注释\n{"mcpServers":{"firefox":{"command":"old","extra":1}},"theme":"light"}\n' \
  '{"mcpServers":{"firefox":{"command":"new"}},"theme":"light"}' jsonc_norm

OBJ_YAML='{"entries":{"settings":{"remote":"settings.yaml","path":{"linux":"~/.cfg/settings.yaml"},"strategy":"merge","format":"yaml","rules":{"objects":{"paths":{"mcp.firefox":"replace"}}}}}}'
check_merge "rules：paths 命中的对象整体替换，本地独有的键被删除（YAML）" \
  "$OBJ_YAML" settings.yaml $'mcp:\n  firefox:\n    command: new\n' settings.yaml \
  $'mcp:\n  firefox:\n    command: old\n    extra: 1\nkeep: true\n' \
  '{"keep":true,"mcp":{"firefox":{"command":"new"}}}' yaml_norm

OBJ_TOML='{"entries":{"tool":{"remote":"tool.toml","path":{"linux":"~/.cfg/tool.toml"},"strategy":"merge","format":"toml","rules":{"objects":{"paths":{"mcp.firefox":"replace"}}}}}}'
check_merge "rules：paths 命中的对象整体替换，本地独有的键被删除（TOML）" \
  "$OBJ_TOML" tool.toml $'[mcp.firefox]\ncommand = "new"\n' tool.toml \
  $'keep = true\n\n[mcp.firefox]\ncommand = "old"\nextra = 1\n' \
  '{"keep": true, "mcp": {"firefox": {"command": "new"}}}' toml_semantics

# 无法推断且未声明 format：写入前报错，报错信息指出条目与推断失败，整个清单不写入（包括同清单中的 replace 条目）
head_ "merge 无法从后缀推断 format 且未声明时，写入前报错"
new_home
put_gist '{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"linux":"~/.zshrc"},"strategy":"replace"},"notes":{"remote":"notes.txt","path":{"linux":"~/.cfg/notes"},"strategy":"merge"}}}' zshrc.txt "$ZSHRC_CONTENT"
mkdir -p "$HOME_DIR/.cfg"
printf '%s' 'keep' >"$HOME_DIR/.cfg/notes"
out="$(run_pull 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '条目 notes' && printf '%s' "$out" | grep -q '推断' &&
  [ "$(cat "$HOME_DIR/.cfg/notes")" = keep ] && [ ! -e "$HOME_DIR/.zshrc" ] && [ ! -e "$HOME_DIR/.local/state/cairn/backup" ]; then
  ok "报错指出条目 notes 无法推断 format，且未写入任何文件"
else
  bad "无法推断 format 时应在写入前报错（rc=$rc，输出：$out）"
fi

# rules 的取值与适用范围：Schema 与运行时一致
SCHEMA_OBJ_ENTRY='"settings":{"remote":"settings.json","path":{"linux":"~/.cfg/settings.json"},"strategy":"merge","format":"json"'
schema_case "清单 Schema：merge 条目的 rules.objects 取值合法时通过" \
  "{\"entries\":{$SCHEMA_OBJ_ENTRY,\"rules\":{\"objects\":{\"default\":\"replace\",\"paths\":{\"a.b\":\"override\"}}}}}}" 0

reject_case "replace 条目带 rules 时报错（仅对 merge 有效），且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":{\"linux\":\"~/.bad\"},\"strategy\":\"replace\",\"rules\":{\"objects\":{\"default\":\"override\"}}}}}" \
  '条目 bad.*rules'

# path 可以是字符串（所有平台相同）或对象：当前平台的键优先，没有则用 default，都没有则报错
head_ "path 为字符串时，Darwin 与 Linux 使用同一路径"
new_home
put_gist '{"entries":{"zshrc":{"remote":"zshrc.txt","path":"~/.shared-rc","strategy":"replace"}}}' zshrc.txt "$ZSHRC_CONTENT"
run_as Darwin >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.shared-rc"; then
  ok "Darwin 写入字符串 path 指定的位置"
else
  bad "字符串 path 应适用于所有平台（rc=$rc）"
fi

head_ "path 对象的 default 作为缺省值：Linux 使用 default"
new_home
put_gist '{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"default":"~/.fallback-rc"},"strategy":"replace"}}}' zshrc.txt "$ZSHRC_CONTENT"
run_as Linux >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.fallback-rc"; then
  ok "没有 linux 键时使用 default"
else
  bad "path 只有 default 时 Linux 应使用 default（rc=$rc）"
fi

head_ "path 对象中当前平台的键优先于 default"
new_home
put_gist '{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"default":"~/.dflt-rc","macos":"~/Library/rc"},"strategy":"replace"}}}' zshrc.txt "$ZSHRC_CONTENT"
run_as Darwin >/dev/null 2>&1
rc_mac=$?
if [ "$rc_mac" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/Library/rc" && [ ! -e "$HOME_DIR/.dflt-rc" ]; then
  ok "Darwin 使用 macos 键，未使用 default"
else
  bad "macos 键应优先于 default（rc=$rc_mac）"
fi
new_home
put_gist '{"entries":{"zshrc":{"remote":"zshrc.txt","path":{"default":"~/.dflt-rc","macos":"~/Library/rc"},"strategy":"replace"}}}' zshrc.txt "$ZSHRC_CONTENT"
run_as Linux >/dev/null 2>&1
rc_linux=$?
if [ "$rc_linux" -eq 0 ] && cmp -s "${ROOT}/expected" "$HOME_DIR/.dflt-rc" && [ ! -e "$HOME_DIR/Library/rc" ]; then
  ok "Linux 没有 linux 键时使用 default"
else
  bad "Linux 应使用 default（rc=$rc_linux）"
fi

# path 字符串或对象的 Schema 校验：对象的键只能是 default、linux、macos、windows，值必须是字符串
schema_path_case() {
  schema_case "$1" "{\"entries\":{\"zshrc\":{\"remote\":\"zshrc.txt\",\"path\":$2,\"strategy\":\"replace\"}}}" "$3"
}
schema_path_case "清单 Schema：path 为字符串时通过" '"~/.zshrc"' 0
schema_path_case "清单 Schema：path 对象只有 default 时通过" '{"default":"~/.zshrc"}' 0
schema_path_case "清单 Schema：path 对象含未知键时失败" '{"bsd":"~/.zshrc"}' 1
schema_path_case "清单 Schema：path 既非字符串也非对象时失败" '5' 1

# rules 冲突：paths 中取 override 的路径位于规则为 replace 的上级对象之下，上级整块替换后它不会生效，写入前报错
reject_case "objects.default 为 replace 时，子路径的 objects override 视为冲突，且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":\"~/.bad.json\",\"strategy\":\"merge\",\"format\":\"json\",\"rules\":{\"objects\":{\"default\":\"replace\",\"paths\":{\"a.b\":\"override\"}}}}}}" \
  '条目 bad.*rules 冲突.*a\.b.*上级对象 a '

reject_case "上级对象为 replace 时，其下的 arrays override 视为冲突，且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":\"~/.bad.json\",\"strategy\":\"merge\",\"format\":\"json\",\"rules\":{\"objects\":{\"paths\":{\"a\":\"replace\"}},\"arrays\":{\"paths\":{\"a.list\":\"override\"}}}}}}" \
  '条目 bad.*rules 冲突.*a\.list'

reject_case "上级对象为 replace 时，其下的 arrays append 视为冲突，且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":\"~/.bad.json\",\"strategy\":\"merge\",\"format\":\"json\",\"rules\":{\"objects\":{\"paths\":{\"a\":\"replace\"}},\"arrays\":{\"paths\":{\"a.list\":\"append\"}}}}}}" \
  '条目 bad.*rules 冲突.*a\.list'

reject_case "objects 取 append 时报错（append 只用于数组），且不写入" \
  "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":\"~/.bad.json\",\"strategy\":\"merge\",\"format\":\"json\",\"rules\":{\"objects\":{\"default\":\"append\"}}}}}" \
  '条目 bad.*rules'

schema_case "清单 Schema：arrays 取 append 时通过" \
  "{\"entries\":{$SCHEMA_ENTRY_MERGE,\"rules\":{\"arrays\":{\"default\":\"append\",\"paths\":{\"a.b\":\"append\"}}}}}}" 0
schema_case "清单 Schema：objects 取 append 时失败" \
  "{\"entries\":{$SCHEMA_ENTRY_MERGE,\"rules\":{\"objects\":{\"default\":\"append\"}}}}}" 1

# append：本机数组原样保留（含重复），远程数组原样接在后面，不比较值、不去重；本机没有该数组时为远程数组本身
check_merge "merge json arrays append：本机数组后接远程数组，不比较值、不去重" \
  '{"entries":{"settings":{"remote":"settings.json","path":"~/.cfg/settings.json","strategy":"merge","rules":{"arrays":{"default":"append"}}}}}' \
  settings.json '{"tags":["b","c"],"fresh":["x","x"]}' settings.json \
  '{"tags":["a","b","a"]}' \
  '{"fresh":["x","x"],"tags":["a","b","a","b","c"]}' json_norm

check_merge "merge jsonc arrays append：语义与 json 一致" \
  '{"entries":{"settings":{"remote":"settings.json","path":"~/.cfg/settings.jsonc","strategy":"merge","format":"jsonc","rules":{"arrays":{"default":"append"}}}}}' \
  settings.json '{"tags":["b","c"],"fresh":["x","x"]}' settings.jsonc \
  $'// 注释\n{"tags":["a","b","a"]}\n' \
  '{"fresh":["x","x"],"tags":["a","b","a","b","c"]}' jsonc_norm

check_merge "merge yaml arrays append：语义与 json 一致" \
  '{"entries":{"settings":{"remote":"settings.yaml","path":"~/.cfg/settings.yaml","strategy":"merge","rules":{"arrays":{"default":"append"}}}}}' \
  settings.yaml $'tags: [b, c]\nfresh: [x, x]\n' settings.yaml \
  $'tags: [a, b, a]\n' \
  '{"fresh":["x","x"],"tags":["a","b","a","b","c"]}' yaml_norm

check_merge "merge toml arrays append：语义与 json 一致" \
  '{"entries":{"tool":{"remote":"tool.toml","path":"~/.cfg/tool.toml","strategy":"merge","rules":{"arrays":{"default":"append"}}}}}' \
  tool.toml $'tags = ["b", "c"]\nfresh = ["x", "x"]\n' tool.toml \
  $'tags = ["a", "b", "a"]\n' \
  '{"fresh": ["x", "x"], "tags": ["a", "b", "a", "b", "c"]}' toml_semantics

# 上级逐级显式取 override 时没有冲突：a 与 a.b 按键叠加，未指定的 a.c 与 d 按 default 整块替换
check_merge "objects.default 为 replace 时，逐级显式 override 的路径按键叠加，其余对象整块替换（JSON）" \
  '{"entries":{"settings":{"remote":"settings.json","path":"~/.cfg/settings.json","strategy":"merge","rules":{"objects":{"default":"replace","paths":{"a":"override","a.b":"override"}}}}}}' \
  settings.json '{"a":{"b":{"x":9},"c":{"k":9}},"d":{"m":9}}' settings.json \
  '{"a":{"b":{"x":1,"y":2},"c":{"k":1,"j":2}},"d":{"m":1,"n":2}}' \
  '{"a":{"b":{"x":9,"y":2},"c":{"k":9}},"d":{"m":9}}' json_norm

# 目标文件存在但为空（只含空白）时按空对象处理，合并结果即远程片段
check_merge "merge json 目标为空文件时，结果为远程片段" \
  "$MERGE_MANIFEST" settings.json '{"a":{"b":1}}' settings.json \
  $'\n' '{"a":{"b":1}}' json_norm

check_merge "merge jsonc 目标为空文件时，结果为远程片段" \
  "$JSONC_MANIFEST" settings.json '{"a":{"b":1}}' settings.jsonc \
  '' '{"a":{"b":1}}' jsonc_norm

# 备份目录跟随 XDG_STATE_HOME；未设置或为相对路径时使用 ~/.local/state
head_ "备份目录跟随 XDG_STATE_HOME"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
printf 'export OLD=1\n' >"$HOME_DIR/.zshrc"
cairn_env XDG_STATE_HOME="$HOME_DIR/xdg-state" "$SHELL_BIN" "$CAIRN" pull --yes </dev/null >/dev/null 2>&1
rc=$?
n_xdg="$(find "$HOME_DIR/xdg-state/cairn/backup" -maxdepth 1 -type f -name '.zshrc.*.bak' 2>/dev/null | grep -c .)"
if [ "$rc" -eq 0 ] && [ "$n_xdg" -eq 1 ] && [ ! -e "$HOME_DIR/.local/state" ]; then
  ok "备份写入 \$XDG_STATE_HOME/cairn/backup，未使用 ~/.local/state"
else
  bad "备份应写入 XDG_STATE_HOME 下（rc=$rc，备份数 $n_xdg）"
fi

# 界面语言：CAIRN_LANG 优先（BCP 47 标签），未设置时按 LC_ALL、LC_MESSAGES、LANG 选择，都没有时为英文。
# 只看输出中有没有中文，不核对具体文案；英文的报错路径也要能正常输出（格式串与参数不错位）
has_cjk() { printf '%s' "$1" | LC_ALL=C grep -q $'[\xe4-\xe9]'; }
head_ "界面语言：CAIRN_LANG 优先，其次按系统语言，缺省为英文"
new_home
put_gist "$ZSHRC_MANIFEST" zshrc.txt "$ZSHRC_CONTENT"
out_en="$(cairn_env CAIRN_LANG=en LANG=zh_CN.UTF-8 "$SHELL_BIN" "$CAIRN" pull --yes </dev/null 2>&1)"
rc_en=$?
out_locale="$(cairn_env CAIRN_LANG= LANG=zh_CN.UTF-8 "$SHELL_BIN" "$CAIRN" pull --yes </dev/null 2>&1)"
out_default="$(cairn_env CAIRN_LANG= "$SHELL_BIN" "$CAIRN" pull --yes </dev/null 2>&1)"
if [ "$rc_en" -eq 0 ] && ! has_cjk "$out_en" && has_cjk "$out_locale" && ! has_cjk "$out_default"; then
  ok "CAIRN_LANG=en 输出英文，LANG=zh_CN.UTF-8 输出中文，都未设置时输出英文"
else
  bad "界面语言选择不正确（en：$out_en；LANG：$out_locale；缺省：$out_default）"
fi

head_ "英文界面下清单校验失败时报错退出，且不写入"
new_home
put_gist "{\"entries\":{$ZSHRC_ENTRY,\"bad\":{\"remote\":\"zshrc.txt\",\"path\":\"~/.bad\",\"strategy\":\"append\"}}}" zshrc.txt "$ZSHRC_CONTENT"
out="$(cairn_env CAIRN_LANG=en "$SHELL_BIN" "$CAIRN" pull --yes </dev/null 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'bad' && ! has_cjk "$out" && [ -z "$(find "$HOME_DIR" -type f)" ]; then
  ok "英文报错指出条目 bad，未写入"
else
  bad "英文界面下应报错且不写入（rc=$rc，输出：$out）"
fi

printf '\n通过 %d，失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
