#!/usr/bin/env bash
# Cairn：从私有 Gist 拉取清单与配置文件，并写入本机对应位置。
#
# 用法：cairn.sh pull [--gist ID] [--manifest NAME] [--dry-run] [--yes] [条目名…]
#       cairn.sh install   （复制到 ~/.local/bin/cairn，可选）
#
# 配置来源：Gist ID 与清单文件名可用环境变量或同名参数提供，参数优先；
# token 只从 CAIRN_GITHUB_TOKEN 获取。
set -uo pipefail

die() {
  printf 'cairn: %s\n' "$1" >&2
  exit 1
}

# 界面语言，取值为 BCP 47 标签：CAIRN_LANG 优先，其次按 POSIX 的优先级取 LC_ALL、LC_MESSAGES、LANG。
# 以 zh 开头（如 zh-CN、zh_CN.UTF-8）时为简体中文 zh-CN，其余为英文 en
ui_lang() {
  case "${CAIRN_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
    zh* | ZH*) printf '%s' zh-CN ;;
    *) printf '%s' en ;;
  esac
}

# 按界面语言输出一条文案（不自动换行）：$1 为 zh-CN 的 printf 格式串，$2 为 en 的格式串，其余为参数
msg() {
  local zh_cn="$1" en="$2"
  shift 2
  # 格式串都是调用方写死的字面量，不含外部输入，故抑制 SC2059
  # shellcheck disable=SC2059
  if [ "$UI_LANG" = zh-CN ]; then printf "$zh_cn" "$@"; else printf "$en" "$@"; fi
}

# 取条目的字符串字段：缺失、非字符串或为空时输出空串
# 用法：str_field 条目 字段名
str_field() {
  jq -r --arg k "$2" \
    'if type == "object" then .[$k] else null end | if type == "string" then . else "" end' <<< "$1"
}

# 条目的写入路径（清单中的原样字符串，不做分隔符转换）：path 为字符串时直接使用；为对象时先取当前平台的键，没有则取 default。
# 两者都没有时输出空串，表示条目不适用于此平台。用法：target_for 条目 平台
target_for() {
  jq -r --arg p "$2" '
    if (.path | type) == "string" then .path
    elif (.path | type) == "object" then (.path[$p] // .path.default // "")
    else "" end
    | if type == "string" then . else "" end' <<< "$1"
}

# merge 条目未声明 format 时由 remote 的后缀推断：.json→json，.jsonc→jsonc，.yaml/.yml→yaml，.toml→toml。
# 推断不出时输出空串。声明的 format 优先，本函数只在未声明时调用。
infer_format() {
  case "$1" in
    *.json) printf '%s' json ;;
    *.jsonc) printf '%s' jsonc ;;
    *.yaml | *.yml) printf '%s' yaml ;;
    *.toml) printf '%s' toml ;;
    *) printf '%s' '' ;;
  esac
}

# 向 validate_manifest 的 errors 追加一行，参数同 msg
add_error() {
  errors="${errors}cairn: $(msg "$@")"$'\n'
}

# 写入前校验整个清单：所有问题逐条输出到标准错误，有任何问题则返回 1，不产生写入
validate_manifest() {
  local manifest_json="$1" platform="$2"
  local errors="" n i=0 entry name remote target resolved strategy format key rule parent

  n="$(jq '.entries | length' <<< "$manifest_json")"
  while [ "$i" -lt "$n" ]; do
    # 条目名即 entries 对象的键（按插入顺序取第 i 个）；重复的键由 JSON 解析保留最后一个，不另行检测
    name="$(jq -r --argjson i "$i" '.entries | keys_unsorted[$i]' <<< "$manifest_json")"
    entry="$(jq -c --arg k "$name" '.entries[$k]' <<< "$manifest_json")"

    if [ "$(jq -r 'type' <<< "$entry")" != object ]; then
      add_error '条目 %s：不是对象' 'entry %s: not an object' "$name"
    else
      remote="$(str_field "$entry" remote)"
      [ -n "$remote" ] || add_error '条目 %s：缺少字段 %s' 'entry %s: missing field %s' "$name" remote

      # path 须为非空字符串，或值均为非空字符串的非空对象；写错时是清单错误，不能当作“不适用”跳过
      if [ "$(jq 'def ok: type == "string" and length > 0;
        if (.path | type) == "object" then (.path | length) > 0 and all(.path[]; ok) else .path | ok end' <<< "$entry")" != true ]; then
        add_error '条目 %s：字段 %s 缺失或取值不合法（%s）' 'entry %s: field %s is missing or invalid (%s)' \
          "$name" path 'string | {default, linux, macos, windows}'
      fi
      # 没有当前平台的路径时条目不适用于此平台，执行时跳过，不算清单错误
      target="$(target_for "$entry" "$platform")"
      # 越界检查在写入前完成：解析真实路径并对照黑名单，命中则报错（整个清单不写入）
      if [ -n "$target" ] && ! resolved="$(resolve_target "$target" "$remote" "$platform" 2>&1)"; then
        add_error '条目 %s：%s' 'entry %s: %s' "$name" "$resolved"
      fi

      strategy="$(str_field "$entry" strategy)"
      case "$strategy" in
        replace) ;;
        merge)
          format="$(str_field "$entry" format)"
          [ -n "$format" ] || format="$(infer_format "$remote")"
          if [ -z "$format" ]; then
            add_error '条目 %s：缺少字段 format，且无法从 remote 的后缀推断' \
              'entry %s: missing field format, and it cannot be inferred from the suffix of remote' "$name"
          elif ! supported_merge_format "$format"; then
            add_error '条目 %s：字段 %s 取值不合法（%s）' 'entry %s: field %s is invalid (%s)' "$name" format 'json | jsonc | yaml | toml'
          fi
          ;;
        '') add_error '条目 %s：缺少字段 %s' 'entry %s: missing field %s' "$name" strategy ;;
        *) add_error '条目 %s：字段 %s 取值不合法（%s）' 'entry %s: field %s is invalid (%s)' "$name" strategy 'replace | merge' ;;
      esac

      # rules 仅对 merge 有效；arrays 与 objects 各含 default 与 paths。
      # arrays 取 replace、override 或 append，objects 取 replace 或 override
      if [ "$strategy" != merge ] && [ "$(jq 'has("rules")' <<< "$entry")" = true ]; then
        add_error '条目 %s：字段 rules 仅对 merge 有效' 'entry %s: rules applies to merge entries only' "$name"
      fi
      if [ "$(jq -r 'def allowed($v; $ok): any($ok[]; . == $v);
        def bad($r; $ok): ($r | type) != "object" or (($r | keys) - ["default", "paths"] | length) > 0 or ($r | has("default") and (allowed($r.default; $ok) | not)) or ($r | has("paths") and (($r.paths | type) != "object" or any($r.paths[]?; allowed(.; $ok) | not)));
        if has("rules") and ((.rules | type) != "object" or ((.rules | keys) - ["arrays", "objects"] | length) > 0 or (.rules | has("arrays") and bad(.arrays; ["replace", "override", "append"])) or (.rules | has("objects") and bad(.objects; ["replace", "override"]))) then "bad" else "" end' <<< "$entry")" = bad ]; then
        add_error '条目 %s：字段 %s 取值不合法（%s）' 'entry %s: field %s is invalid (%s)' "$name" rules \
          'arrays: replace | override | append; objects: replace | override'
      elif [ "$strategy" = merge ]; then
        # paths 中保留本机内容的规则（数组的 override、append，对象的 override），若某一级上级对象的规则为 replace，
        # 上级整块替换后这条规则不会生效，视为冲突
        while IFS=$'\t' read -r key rule parent; do
          [ -n "$key" ] && add_error '条目 %s：rules 冲突：paths 中的 %s 为 %s，但上级对象 %s 的规则为 replace，整块替换后它不会生效' \
            'entry %s: rules conflict: %s is %s, but its parent object %s is replace, so the rule has no effect' \
            "$name" "$key" "$rule" "$parent"
        done <<< "$(jq -r '(.rules // {}) as $m
          | ($m.objects.default // "override") as $obj_default | ($m.objects.paths // {}) as $obj_paths
          | [(($m.arrays.paths // {}) | to_entries[] | select(.value == "override" or .value == "append")),
             ($obj_paths | to_entries[] | select(.value == "override"))
             | .key as $key | .value as $rule
             | ($key | split(".")) as $parts | range(1; $parts | length) as $i | ($parts[:$i] | join(".")) as $parent
             | select(($obj_paths[$parent] // $obj_default) == "replace")
             | "\($key)\t\($rule)\t\($parent)"]
          | unique[]' <<< "$entry")"
      fi
    fi
    i=$((i + 1))
  done

  if [ -n "$errors" ]; then
    printf '%s' "$errors" >&2
    return 1
  fi
}

# 覆盖前把原文件复制到 <状态目录>/cairn/backup/<原文件名>.<YYYYMMDD-HHMMSS>.bak。
# 状态目录取 XDG_STATE_HOME；未设置或不是绝对路径时（XDG 规范要求忽略相对路径）用 ~/.local/state。
# 同一秒内已有同名备份时追加 -2、-3……，避免覆盖
backup_file() {
  local src="$1" state="${XDG_STATE_HOME:-}" dir stamp dest n
  case "$state" in
    /*) ;;
    *) state="${HOME}/.local/state" ;;
  esac
  dir="${state}/cairn/backup"
  mkdir -p "$dir" || return 1
  stamp="$(basename "$src").$(date +%Y%m%d-%H%M%S)"
  dest="${dir}/${stamp}.bak"
  n=1
  while [ -e "$dest" ]; do
    n=$((n + 1))
    dest="${dir}/${stamp}-${n}.bak"
  done
  cp -p "$src" "$dest"
}

# 词法规范化绝对路径：去掉 . 与空段，.. 退回上一段，不解析符号链接
normalize_path() {
  local rest="$1" stack="" comp
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$comp" in
      '' | .) ;;
      ..) stack="${stack%/*}" ;;
      *) stack="${stack}/${comp}" ;;
    esac
  done
  printf '%s' "${stack:-/}"
}

# 解析为真实路径（输入须为规范化后的绝对路径）：找到最长的已存在前缀，逐级解析其中的符号链接，
# 其后尚不存在的部分原样接在后面。hops 为已解析的符号链接数，超过 40 视为循环。
# 注意：本文件中不要用 path 作局部变量名，zsh 中 path 与 PATH 绑定，会清空命令搜索路径。
real_path() {
  local p="$1" hops="${2:-0}" base rest="" link parent real_base dir
  if [ "$hops" -gt 40 ]; then
    printf 'cairn: %s\n' "$(msg '符号链接层数过多（可能存在循环）：%s' 'too many levels of symbolic links (possible loop): %s' "$1")" >&2
    return 1
  fi
  base="$p"
  while [ "$base" != / ] && [ ! -e "$base" ] && [ ! -L "$base" ]; do
    rest="/${base##*/}${rest}"
    base="${base%/*}"
    [ -n "$base" ] || base=/
  done
  if [ -L "$base" ]; then
    link="$(readlink "$base")" || return 1
    case "$link" in
      /*) ;;
      *)
        parent="${base%/*}"
        [ -n "$parent" ] || parent=/
        link="$(real_path "$parent" $((hops + 1)))/${link}" || return 1
        ;;
    esac
    real_path "$(normalize_path "${link}${rest}")" $((hops + 1))
    return
  fi
  if [ -d "$base" ]; then
    real_base="$(cd -P "$base" && pwd -P)" || return 1
  else
    dir="${base%/*}"
    [ -n "$dir" ] || dir=/
    real_base="$(cd -P "$dir" && pwd -P)" || return 1
    real_base="${real_base%/}/${base##*/}"
  fi
  if [ -z "$rest" ]; then
    printf '%s' "$real_base"
  else
    printf '%s' "${real_base%/}${rest}"
  fi
}

# 平台黑名单（仅列出不可写入的系统路径，不做白名单）。macOS 上 /etc、/var 为指向 /private 的符号链接，
# 因此按真实路径检查 /private/etc 等条目。Windows 运行时不支持，不在此列。
platform_blacklist() {
  case "$1" in
    linux) printf '%s\n' /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /opt /proc /root /run /sbin /srv /sys /usr /var ;;
    macos) printf '%s\n' /System /Library /usr /bin /sbin /dev /cores /Applications /private/etc /private/var/db /private/var/root ;;
  esac
}

# 解析条目的写入目标：$1 清单中的路径，$2 远程文件名，$3 平台（linux 或 macos）。
# 路径以 / 结尾，或仅为 ~ 或 .，表示目录，文件名取远程文件名。先按前缀规则得到绝对路径并规范化 .、..，
# 再解析为真实路径，最后检查黑名单（路径相等或位于条目之下）。
# 成功时输出真实路径；越界时输出说明并返回 1。
resolve_target() {
  local raw="$1" remote="$2" platform="$3" p is_dir=0 real real_home entry
  case "$raw" in
    '~') p="$HOME"; is_dir=1 ;;
    \~/*) p="${HOME}/${raw#\~/}" ;;
    '.') p="$PWD"; is_dir=1 ;;
    './'*) p="${PWD}/${raw#./}" ;;
    /*) p="$raw" ;;
    *) p="${PWD}/${raw}" ;;
  esac
  case "$raw" in
    */) is_dir=1 ;;
  esac
  if [ "$is_dir" -eq 1 ]; then
    p="${p%/}/${remote##*/}"
  fi
  p="$(normalize_path "$p")"
  real="$(real_path "$p")" || return 1
  # HOME 之内的路径永远允许，不做黑名单检查（使 macOS 的 /Users/<你> 可用）。
  # HOME 解析为 / 时不适用，否则整个文件系统都会被豁免。
  real_home="$(real_path "$(normalize_path "$HOME")")" || return 1
  if [ "$real_home" != / ]; then
    case "$real" in
      "$real_home" | "$real_home"/*) printf '%s' "$real"; return 0 ;;
    esac
  fi
  while IFS= read -r entry; do
    case "$real" in
      "$entry" | "$entry"/*)
        msg '路径 %s（真实路径 %s）位于平台黑名单条目 %s 之下，拒绝写入' \
          'path %s (real path %s) is under the blacklisted %s; refusing to write' "$raw" "$real" "$entry"
        return 1
        ;;
    esac
  done < <(platform_blacklist "$platform")
  printf '%s' "$real"
}

# 原子写入：从标准输入读取内容，先写入目标同目录的临时文件，再 mv 覆盖目标，避免中途失败留下半写入的文件。
# 已有目标时先 cp -p 复制以保留权限；失败时删除临时文件并返回非零，目标保持原样。
# 目标须为 resolve_target 得到的真实路径：符号链接已解析，mv 只替换链接指向的文件，链接本身保持不变。
# 用法：内容 | write_atomic 目标路径
write_atomic() {
  local dest="$1" tmp
  tmp="${dest}.cairn-tmp.$$"
  if [ -e "$dest" ] && ! cp -p "$dest" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! cat >"$tmp" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

# 合并规则的 jq 定义（JSON 与 YAML 共用）。需要 --argjson rules（见 merge_content 的规则对象）。
# array_rule / object_rule：某路径的数组或对象规则，paths 按完整点号路径精确匹配，未命中用 default；
# uniq：按整个 JSON 值去重，保留首次出现的项；
# patches：遍历远程片段，输出 [路径, 应写入的值]，供调用方在按整体替换合并的结果上逐条 setpath。
#          对象在本地也是对象且规则为 replace 时整体输出（不再深入，其中 override 数组只对远程去重）；
#          规则为 override 的数组输出并集（本地数组与远程数组合并去重，本地无此数组则只对远程去重）；
#          规则为 append 的数组输出本地数组后接远程数组，不比较值、不去重（本地无此数组则为远程数组本身）。
# 下面的 jq 定义刻意用单引号包住，让 jq 看到字面量 $（$p、$rules 等由 jq 解析，不由 shell 展开），故抑制 SC2016。
# shellcheck disable=SC2016
JQ_MERGE_DEFS='
def array_rule($p): ($rules.arrays.paths[$p | join(".")] // $rules.arrays.default);
def object_rule($p): ($rules.objects.paths[$p | join(".")] // $rules.objects.default);
def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def patches($p; $l; $r):
  if ($r | type) == "object" then
    if ($p | length) > 0 and ($l | type) == "object" and object_rule($p) == "replace" then
      [$p, (reduce patches($p; null; $r) as $f ($r; setpath($f[0][($p | length):]; $f[1])))]
    else
      $r | keys_unsorted[] as $k
      | patches($p + [$k]; (if ($l | type) == "object" then $l[$k] else null end); $r[$k])
    end
  elif ($r | type) == "array" and array_rule($p) == "override" then
    [$p, (if ($l | type) == "array" then ($l + $r) else $r end | uniq)]
  elif ($r | type) == "array" and array_rule($p) == "append" and ($l | type) == "array" then
    [$p, ($l + $r)]
  else empty end;
'

# 目标文件存在且含非空白内容时返回 0。只含空白的文件按不存在处理，合并结果即远程片段本身（与把空文件视为空对象等价）
has_content() {
  [ -e "$1" ] && grep -q '[^[:space:]]' "$1"
}

# 把远程 JSON 片段（$2）按规则对象（$3）深度合并进目标文件（$1），结果输出到标准输出。
# 先按 jq 的 * 合并（远程键覆盖同名键，本地独有键保留，数组整体替换），再把 patches 算出的值写回对应路径。
# 目标不存在或为空时输出远程片段本身（同样套用 override 去重）。输出统一为 2 空格缩进并以换行结尾。
merge_json() {
  if has_content "$1"; then
    jq -s --indent 2 --argjson rules "$3" "$JQ_MERGE_DEFS"'
      .[0] as $l | .[1] as $r
      | reduce patches([]; $l; $r) as $f (($l * $r); setpath($f[0]; $f[1]))' "$1" <(printf '%s' "$2")
  else
    jq --indent 2 --argjson rules "$3" "$JQ_MERGE_DEFS"'
      . as $r | reduce patches([]; null; $r) as $f ($r; setpath($f[0]; $f[1]))' <<< "$2"
  fi
}

# 把远程 JSONC 片段（$2）按规则对象（$3）深度合并进目标 JSONC 文件（$1），结果输出到标准输出，并尽量保留目标中的注释。
# 语义与 merge_json 相同。实现：对每个需要写入的键，用 jsonc-parser 的 modify 把远程值改写到原文中，
# 未改动的部分（含注释与格式）原样保留。目标不存在或为空时输出远程片段（保留其注释）；目标或远程的根不是对象时失败，
# 与 merge_json 一致，由调用方报错且不写入。
# 依赖 node 与 jsonc-parser（由 require_format_tool 检查）。
merge_jsonc() {
  local js
  read -r -d '' js <<'JS' || true
const fs = require("fs");
const jp = require("jsonc-parser");
const parseOpts = { allowTrailingComma: true, disallowComments: false };
const fmt = { insertSpaces: true, tabSize: 2, eol: "\n" };
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const parse = (text) => {
  const errs = [];
  const value = jp.parse(text, errs, parseOpts);
  if (errs.length > 0) {
    process.exit(1);
  }
  return value;
};
const formatted = (text) => jp.applyEdits(text, jp.format(text, undefined, fmt));
const remoteText = fs.readFileSync(0, "utf8");
const remote = parse(remoteText);
const target = process.argv[1];
const rules = JSON.parse(process.argv[2]);
const ruleAt = (kind, p) => {
  const key = p.join(".");
  return Object.prototype.hasOwnProperty.call(rules[kind].paths, key) ? rules[kind].paths[key] : rules[kind].default;
};
const arrayRule = (p) => ruleAt("arrays", p);
const objectRule = (p) => ruleAt("objects", p);
const canon = (v) =>
  JSON.stringify(v, (k, x) => (isObj(x) ? Object.fromEntries(Object.keys(x).sort().map((key) => [key, x[key]])) : x));
const uniq = (items) => {
  const seen = new Set();
  const out = [];
  for (const item of items) {
    const key = canon(item);
    if (!seen.has(key)) {
      seen.add(key);
      out.push(item);
    }
  }
  return out;
};
// 远程独有的值：其中规则为 override 的数组去重（与 jq 的 patches 一致）
const remoteOnly = (path, v) => {
  if (isObj(v)) {
    const out = {};
    for (const key of Object.keys(v)) out[key] = remoteOnly(path.concat([key]), v[key]);
    return out;
  }
  if (Array.isArray(v) && arrayRule(path) === "override") return uniq(v);
  return v;
};
const collect = (path, rem, out) => {
  for (const key of Object.keys(rem)) {
    const p = path.concat([key]);
    if (isObj(rem[key])) collect(p, rem[key], out);
    else if (Array.isArray(rem[key]) && arrayRule(p) === "override") out.push([p, uniq(rem[key])]);
  }
  return out;
};
if (!fs.existsSync(target) || fs.readFileSync(target, "utf8").trim() === "") {
  let created = formatted(remoteText);
  for (const [p, v] of collect([], remote, [])) {
    created = jp.applyEdits(created, jp.modify(created, p, v, { formattingOptions: fmt }));
  }
  process.stdout.write(created);
  process.exit(0);
}
let text = fs.readFileSync(target, "utf8");
const local = parse(text);
if (!isObj(local) || !isObj(remote)) {
  process.exit(1);
}
const merge = (path, loc, rem) => {
  for (const key of Object.keys(rem)) {
    const p = path.concat([key]);
    const r = rem[key];
    const l = loc[key];
    if (isObj(l) && isObj(r)) {
      if (objectRule(p) === "replace") {
        text = jp.applyEdits(text, jp.modify(text, p, remoteOnly(p, r), { formattingOptions: fmt }));
      } else {
        merge(p, l, r);
      }
      continue;
    }
    let value = remoteOnly(p, r);
    if (Array.isArray(r) && arrayRule(p) === "override") value = uniq(Array.isArray(l) ? l.concat(r) : r);
    else if (Array.isArray(r) && arrayRule(p) === "append" && Array.isArray(l)) value = l.concat(r);
    text = jp.applyEdits(text, jp.modify(text, p, value, { formattingOptions: fmt }));
  }
};
merge([], local, remote);
process.stdout.write(text);
JS
  printf '%s' "$2" | node -e "$js" "$1" "$3"
}

# 把远程 YAML 片段（$2）按规则对象（$3）深度合并进目标 YAML 文件（$1），结果输出到标准输出，并保留注释（mikefarah yq）。
# 先按 yq 的 * 合并（远程键覆盖同名键，本地独有键保留，数组整体替换），再把 JQ_MERGE_DEFS 的 patches 算出的值
# 逐条用 setpath 写回。目标为空时按空对象处理；目标不存在时输出远程片段。
merge_yaml() {
  local stage local_json remote_json p v
  remote_json="$(yq -o=json '.' <(printf '%s\n' "$2"))" || return 1
  if [ -e "$1" ]; then
    stage="$(yq eval-all '(select(fileIndex == 0) // {}) * select(fileIndex == 1)' "$1" <(printf '%s\n' "$2"))" || return 1
    local_json="$(yq -o=json '. // {}' "$1")" || return 1
  else
    stage="$(yq '.' <(printf '%s\n' "$2"))" || return 1
    local_json="null"
  fi
  # patches 每项输出两行：路径与值（紧凑 JSON）
  local patch_lines
  patch_lines="$(jq -c -s --argjson rules "$3" "$JQ_MERGE_DEFS"'
    patches([]; .[0]; .[1]) | .[0], .[1]' <(printf '%s' "$local_json") <(printf '%s' "$remote_json"))" || return 1
  while IFS= read -r p && IFS= read -r v; do
    stage="$(printf '%s\n' "$stage" | P="$p" V="$v" yq eval 'setpath(strenv(P) | from_json; strenv(V) | from_json)' -)" || return 1
  done <<< "$patch_lines"
  printf '%s\n' "$stage"
}

# 当前支持合并的格式。合并函数按 merge_<格式> 命名，由 merge_content 据此分派
supported_merge_format() {
  case "$1" in
    json | jsonc | yaml | toml) return 0 ;;
    *) return 1 ;;
  esac
}

# 把远程 TOML 片段（$2）按规则对象（$3）深度合并进目标文件（$1），结果输出到标准输出，语义与 merge_json 相同。
# 使用 tomlkit：解析与输出都保留注释与排版；目标不存在时输出远程片段本身（override 数组同样去重）。
merge_toml() {
  python3 -c '
import json
import os
import sys

import tomlkit

RULES = json.loads(sys.argv[2])


def rule(kind, path):
    return RULES[kind]["paths"].get(".".join(path), RULES[kind]["default"])


def array_rule(path):
    return rule("arrays", path)


def object_rule(path):
    return rule("objects", path)


def plain(value):
    # 递归去掉 tomlkit 包装，得到普通的 Python 值（dict、list、str、int、float、bool）
    if hasattr(value, "unwrap"):
        return plain(value.unwrap())
    if isinstance(value, dict):
        return {key: plain(item) for key, item in value.items()}
    if isinstance(value, list):
        return [plain(item) for item in value]
    return value


def canon(value):
    # 去重键：按 JSON 序列化（键排序）。Python 中 True == 1、False == 0，直接比较会误判，序列化后类型保留
    return json.dumps(plain(value), sort_keys=True)


def array_of(items):
    arr = tomlkit.array()
    arr.extend(items)
    return arr


def overlay(local_items, remote_items):
    result, seen = [], set()
    for item in list(local_items) + list(remote_items):
        key = canon(item)
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def remote_only(path, value):
    # 远程独有的值：其中规则为 override 的数组去重（与 jq 的 patches 一致）
    if isinstance(value, dict):
        for key in list(value.keys()):
            new = remote_only(path + [key], value[key])
            if new is not value[key]:
                value[key] = new
        return value
    if isinstance(value, list) and array_rule(path) == "override":
        return array_of(overlay([], value))
    return value


def merge(local, remote, path):
    for key, value in remote.items():
        here = path + [key]
        if key in local and isinstance(local[key], dict) and isinstance(value, dict):
            if object_rule(here) == "replace":
                local[key] = remote_only(here, value)
            else:
                merge(local[key], value, here)
        elif isinstance(value, list) and array_rule(here) == "override":
            base = local[key] if key in local and isinstance(local[key], list) else []
            local[key] = array_of(overlay(base, value))
        elif isinstance(value, list) and array_rule(here) == "append" and key in local and isinstance(local[key], list):
            # append：本地数组后接远程数组，不比较值、不去重
            local[key] = array_of(list(local[key]) + list(value))
        else:
            local[key] = remote_only(here, value)
    return local


remote = tomlkit.parse(sys.stdin.buffer.read().decode("utf-8"))
target = sys.argv[1]
if os.path.exists(target):
    with open(target, encoding="utf-8") as f:
        doc = merge(tomlkit.parse(f.read()), remote, [])
else:
    doc = remote_only([], remote)
sys.stdout.buffer.write(tomlkit.dumps(doc).encode("utf-8"))
' "$1" "$3" <<< "$2"
}

# 缺少工具时的提示：$1 工具名，$2 安装方式（命令或地址）
missing_tool() {
  msg '缺少 %s，请先安装：%s' 'missing %s; install it: %s' "$1" "$2"
}

# 检查某格式的 merge 所需工具：缺失时把安装提示输出到标准输出并返回 1。
# 只在 merge 条目用到该格式时调用；replace 条目不检查任何格式工具。jq 另由启动时检查。
require_format_tool() {
  case "$1" in
    toml)
      command -v python3 >/dev/null 2>&1 || {
        missing_tool python3 'https://www.python.org'
        return 1
      }
      python3 -c 'import tomlkit' >/dev/null 2>&1 || {
        missing_tool tomlkit 'pip3 install tomlkit'
        return 1
      }
      ;;
    jsonc)
      command -v node >/dev/null 2>&1 || {
        missing_tool node 'https://nodejs.org'
        return 1
      }
      node -e 'require("jsonc-parser")' >/dev/null 2>&1 || {
        missing_tool jsonc-parser 'npm install -g jsonc-parser (NODE_PATH: npm root -g)'
        return 1
      }
      ;;
    yaml)
      command -v yq >/dev/null 2>&1 || {
        missing_tool yq 'https://github.com/mikefarah/yq'
        return 1
      }
      yq --version 2>/dev/null | grep -q mikefarah || {
        missing_tool 'yq (mikefarah)' 'https://github.com/mikefarah/yq'
        return 1
      }
      ;;
  esac
}

# 按格式分派合并：$1 格式（须已通过 supported_merge_format），$2 目标文件，$3 远程片段，
# $4 规则对象：{"arrays": {"default", "paths"}, "objects": {"default", "paths"}}，缺省值已填好
merge_content() {
  "merge_$1" "$2" "$3" "$4"
}

# 条目的 rules 补齐缺省值后的规则对象（紧凑 JSON）：arrays.default 缺省 replace，objects.default 缺省 override
merge_rules_of() {
  jq -c '{
    arrays: {default: (.rules.arrays.default // "replace"), paths: (.rules.arrays.paths // {})},
    objects: {default: (.rules.objects.default // "override"), paths: (.rules.objects.paths // {})}
  }' <<< "$1"
}

usage() {
  if [ "$UI_LANG" = zh-CN ]; then
    cat <<'EOF'
用法：cairn.sh pull [选项] [条目名…]
      cairn.sh install

命令：
  pull              从私有 Gist 拉取清单与配置文件，并写入本机对应位置。
                    指定条目名时只处理这些条目，不指定时处理全部条目
  install           把脚本复制到 ~/.local/bin/cairn（不修改 shell 配置）

pull 选项：
  --gist ID         Gist ID，覆盖 CAIRN_GIST_ID
  --manifest NAME   Gist 中的清单文件名（缺省 cairn-manifest.json），覆盖 CAIRN_MANIFEST
  --dry-run         只打印执行清单（策略与目标路径），不写入任何文件
  --yes             执行全部条目，不显示清单（没有终端时写入必须指定）
  -h, --help        显示本帮助

环境变量：
  CAIRN_GIST_ID       Gist ID（可被 --gist 覆盖）
  CAIRN_MANIFEST      清单文件名（缺省 cairn-manifest.json，可被 --manifest 覆盖）
  CAIRN_GITHUB_TOKEN  GitHub token，只能通过环境变量提供
  CAIRN_LANG          界面语言，BCP 47 标签：en 或 zh-CN（缺省按系统语言）
EOF
  else
    cat <<'EOF'
Usage: cairn.sh pull [options] [name ...]
       cairn.sh install

Commands:
  pull              Fetch the manifest and files from a private Gist and write them to this machine.
                    With names, only those entries are processed; without, every entry is
  install           Copy the script to ~/.local/bin/cairn (shell configuration is not changed)

pull options:
  --gist ID         Gist ID; overrides CAIRN_GIST_ID
  --manifest NAME   Manifest file name in the Gist (default cairn-manifest.json); overrides CAIRN_MANIFEST
  --dry-run         Print the plan (strategy and target path) without writing anything
  --yes             Run every entry without the checklist (required to write without a terminal)
  -h, --help        Show this help

Environment variables:
  CAIRN_GIST_ID       Gist ID (overridden by --gist)
  CAIRN_MANIFEST      Manifest file name (default cairn-manifest.json; overridden by --manifest)
  CAIRN_GITHUB_TOKEN  GitHub token; read only from the environment
  CAIRN_LANG          Output language as a BCP 47 tag: en or zh-CN (default: from the system locale)
EOF
  fi
}

# 把单个条目的失败原因输出到标准错误：$1 条目名，$2 原因
entry_error() {
  printf 'cairn: %s\n' "$(msg '条目 %s：%s' 'entry %s: %s' "$1" "$2")" >&2
}

# 解析并校验单个条目（只读，不写入；清单已通过 validate_manifest）。成功时设置 PLAN_TARGET、PLAN_STRATEGY、
# PLAN_REMOTE、PLAN_MERGED 并返回 0；条目不适用于此平台（没有可用的 path）时返回 2；失败时打印原因并返回 1
prepare_entry() {
  local name="$1" manifest_json="$2" gist="$3" platform="$4"
  local entry remote target resolved strategy format hint
  entry="$(jq -c --arg k "$name" '.entries[$k]' <<< "$manifest_json")"
  remote="$(jq -r '.remote' <<< "$entry")"
  target="$(target_for "$entry" "$platform")"
  [ -n "$target" ] || return 2
  strategy="$(jq -r '.strategy' <<< "$entry")"
  format="$(jq -r '.format // empty' <<< "$entry")"
  [ -n "$format" ] || format="$(infer_format "$remote")"
  if [ "$strategy" = merge ] && ! hint="$(require_format_tool "$format")"; then
    entry_error "$name" "$hint"
    return 1
  fi

  if ! resolved="$(resolve_target "$target" "$remote" "$platform")"; then
    entry_error "$name" "$resolved"
    return 1
  fi

  if ! jq -e --arg r "$remote" '.files[$r].content != null' <<< "$gist" >/dev/null; then
    entry_error "$name" "$(msg 'Gist 中不存在远程文件 %s' 'remote file %s is not in the Gist' "$remote")"
    return 1
  fi

  # merge 的结果在确认与备份之前算好：本地文件不合法时直接失败，不备份也不写入
  PLAN_MERGED=""
  if [ "$strategy" = merge ]; then
    if ! PLAN_MERGED="$(merge_content "$format" "$resolved" "$(jq -r --arg r "$remote" '.files[$r].content' <<< "$gist")" \
      "$(merge_rules_of "$entry")")"; then
      entry_error "$name" "$(msg '无法合并到 %s（目标不是有效的 %s？）' 'cannot merge into %s (is it valid %s?)' "$resolved" "$format")"
      return 1
    fi
  fi
  PLAN_TARGET="$resolved"
  PLAN_STRATEGY="$strategy"
  PLAN_REMOTE="$remote"
  return 0
}

# 输出 $2 个 $1（0 或 1）组成的勾选位串
fill_flags() {
  local s="" i
  for ((i = 0; i < $2; i++)); do s="${s}$1"; done
  printf '%s' "$s"
}

# 各行第一列（名字）的最大字符数，用于对齐 -> 之前的列。输入为以制表符分列的多行文本
plan_name_width() {
  local w=0 n
  while IFS=$'\t' read -r n _ _; do
    if [ "${#n}" -gt "$w" ]; then w=${#n}; fi
  done <<< "$1"
  printf '%s' "$w"
}

# 清单与结果行的标签：策略（replace、merge）与结果（written、skipped、failed）。
# 中文都是两个字；英文补齐到同样的 7 个字符。两种语言内部各自等宽，使 [ ] 与 -> 两列在清单与结果行之间对齐
ui_label() {
  case "$1" in
    replace) msg '替换' 'replace' ;;
    merge) msg '合并' 'merge  ' ;;
    written) msg '写入' 'written' ;;
    skipped) msg '跳过' 'skipped' ;;
    failed) msg '失败' 'failed ' ;;
  esac
}

# 交互清单的按键说明：按键为加粗青色，说明文字为终端默认色，便于区分。
# 设置了 NO_COLOR 时不输出颜色（https://no-color.org）
key_help() {
  local k="" r=""
  if [ -z "${NO_COLOR:-}" ]; then
    k=$'\033[1;36m'
    r=$'\033[0m'
  fi
  msg "${k}↑↓/jk${r} 移动  ${k}空格${r} 切换  ${k}a${r} 全选  ${k}n${r} 全不选  ${k}回车${r} 确认  ${k}q/Esc${r} 取消" \
    "${k}↑↓/jk${r} move  ${k}Space${r} toggle  ${k}a${r} all  ${k}n${r} none  ${k}Enter${r} confirm  ${k}q/Esc${r} cancel"
}

# 输出一行结果：$1 标记（如 "  [x]"），$2 结果（written、skipped、failed），$3 名字，
# $4 目标路径（为空时不输出 -> 列），$5 名字列宽（与清单相同）
print_result_row() {
  if [ -n "${4:-}" ]; then
    printf '%s %s  %-*s -> %s\n' "$1" "$(ui_label "$2")" "$5" "$3" "$4"
  else
    printf '%s %s  %s\n' "$1" "$(ui_label "$2")" "$3"
  fi
}

# 绘制执行清单。参数：清单（每行 名字<TAB>策略<TAB>目标路径）、勾选位串、条目数、光标位置（-1 为无光标）、
# 页眉的按键说明（空串为无）、是否交互（1 时每行先清除原内容，便于原地重绘）
draw_checklist() {
  local plan="$1" flags="$2" count="$3" cursor="$4" help="$5" interactive="$6"
  local name strategy target label mark prefix clear="" idx=0 selected=0 i name_width
  name_width="$(plan_name_width "$plan")"
  for ((i = 0; i < count; i++)); do
    if [ "${flags:$i:1}" = 1 ]; then selected=$((selected + 1)); fi
  done
  if [ "$interactive" -eq 1 ]; then clear=$'\033[2K'; fi
  printf '%s' "$clear"
  msg '清单：已选 %d/%d 项' 'Checklist: %d/%d selected' "$selected" "$count"
  if [ -n "$help" ]; then printf '  %s' "$help"; fi
  printf '\n'
  while IFS=$'\t' read -r name strategy target; do
    if [ "$cursor" -lt 0 ]; then
      prefix=""
    elif [ "$idx" -eq "$cursor" ]; then
      prefix="> "
    else
      prefix="  "
    fi
    if [ "${flags:$idx:1}" = 1 ]; then mark=x; else mark=" "; fi
    label="$(ui_label "$strategy")"
    printf '%s%s[%s] %s  %-*s -> %s\n' "$clear" "$prefix" "$mark" "$label" "$name_width" "$name" "$target"
    idx=$((idx + 1))
  done <<< "$plan"
}

# 读取一个按键到全局变量 KEY：up/down/esc/enter/space，其余为字符本身或 other；输入结束时返回 1
# bash 与 zsh 的单字符读取语法不同，各用一条路径
read_key() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    IFS= read -rsk1 KEY || return 1
  else
    IFS= read -rsn1 KEY || return 1
  fi
  case "$KEY" in
    '' | $'\n' | $'\r') KEY=enter ;;
    ' ') KEY=space ;;
    $'\004') KEY=q ;;
    $'\033') read_escape_tail ;;
  esac
  return 0
}

# ESC 之后再读取至多两个字节（方向键为 ESC [ A/B 或 ESC O A/B）。终端在非规范模式下，
# VMIN=0、VTIME=1 让读取最多等待约 0.1 秒：没有后续字节时即为单独的 Esc，不会长时间阻塞
read_escape_tail() {
  local tail=""
  stty min 0 time 1 2>/dev/null
  tail="$(dd bs=2 count=1 2>/dev/null | tr -d '\000')"
  stty min 1 time 0 2>/dev/null
  case "$tail" in
    '[A' | 'OA') KEY=up ;;
    '[B' | 'OB') KEY=down ;;
    '') KEY=esc ;;
    *) KEY=other ;;
  esac
}

# 恢复终端：还原 stty 设置并显示光标（由 INT/TERM/EXIT 陷阱调用）
pick_restore_tty() {
  if [ -n "${PICK_OLD_TTY:-}" ]; then stty "$PICK_OLD_TTY" 2>/dev/null; fi
  printf '\033[?25h'
}

# 交互选择：参数为清单、条目数、页眉说明。确认时设置 PICK_FLAGS 并返回 0；取消返回 1；按键输入结束返回 2
pick_entries() {
  local plan="$1" count="$2" help="$3" cursor=0 result=0 new
  PICK_FLAGS="$(fill_flags 0 "$count")"
  PICK_OLD_TTY="$(stty -g 2>/dev/null)" || PICK_OLD_TTY=""
  stty -echo -icanon min 1 time 0 2>/dev/null
  printf '\033[?25l'
  trap 'pick_restore_tty; exit 130' INT TERM HUP
  trap pick_restore_tty EXIT

  draw_checklist "$plan" "$PICK_FLAGS" "$count" "$cursor" "$help" 1
  while :; do
    if ! read_key; then
      result=2
      break
    fi
    case "$KEY" in
      up | k) if [ "$cursor" -gt 0 ]; then cursor=$((cursor - 1)); fi ;;
      down | j) if [ "$cursor" -lt $((count - 1)) ]; then cursor=$((cursor + 1)); fi ;;
      space)
        if [ "${PICK_FLAGS:$cursor:1}" = 1 ]; then new=0; else new=1; fi
        PICK_FLAGS="${PICK_FLAGS:0:$cursor}${new}${PICK_FLAGS:$((cursor + 1))}"
        ;;
      a) PICK_FLAGS="$(fill_flags 1 "$count")" ;;
      n) PICK_FLAGS="$(fill_flags 0 "$count")" ;;
      enter) result=0; break ;;
      q | esc) result=1; break ;;
    esac
    printf '\033[%dA' "$((count + 1))"
    draw_checklist "$plan" "$PICK_FLAGS" "$count" "$cursor" "$help" 1
  done

  pick_restore_tty
  trap - INT TERM HUP EXIT
  return "$result"
}

cmd_pull() {
  local gist_id="${CAIRN_GIST_ID:-}"
  local manifest="${CAIRN_MANIFEST:-cairn-manifest.json}"
  local token="${CAIRN_GITHUB_TOKEN:-}"
  # CAIRN_API_BASE 把 GitHub API 地址指向本地服务，仅供测试使用 Mock Gist
  local api="${CAIRN_API_BASE:-https://api.github.com}"
  local yes=0 dry_run=0 platform
  local names=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --gist | --manifest)
        [ $# -ge 2 ] || die "$(msg '选项 %s 缺少参数' 'option %s requires a value' "$1")"
        if [ "$1" = --gist ]; then gist_id="$2"; else manifest="$2"; fi
        shift 2
        ;;
      --yes) yes=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -h | --help) usage; return 0 ;;
      -*) die "$(msg '未知参数：%s' 'unknown argument: %s' "$1")" ;;
      *) names+=("$1"); shift ;;
    esac
  done

  [ -n "$gist_id" ] || die "$(msg '缺少 %s' 'missing %s' 'CAIRN_GIST_ID / --gist')"
  [ -n "$token" ] || die "$(msg '缺少 %s' 'missing %s' CAIRN_GITHUB_TOKEN)"
  [ -n "$manifest" ] || die "$(msg '缺少 %s' 'missing %s' 'CAIRN_MANIFEST / --manifest')"
  command -v jq >/dev/null 2>&1 || die "$(missing_tool jq 'https://jqlang.org')"
  # CAIRN_UNAME 覆盖 uname -s，仅供测试模拟其他系统
  local os="${CAIRN_UNAME:-$(uname -s)}"
  case "$os" in
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *) die "$(msg '不支持的平台：%s（目前仅支持 Linux 与 macOS）' 'unsupported platform: %s (only Linux and macOS are supported)' "$os")" ;;
  esac

  [ "$yes" -eq 1 ] || [ "$dry_run" -eq 1 ] || [ -t 0 ] || die "$(msg '没有终端时写入需要 --yes' 'writing without a terminal requires --yes')"

  # token 经进程替换以文件形式交给 curl，不出现在 curl 的命令行参数中（ps 可见）
  local gist
  gist="$(curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$token") \
    -H 'Accept: application/vnd.github+json' \
    "${api}/gists/${gist_id}")" || die "$(msg '无法获取 Gist %s，请检查 ID 与 token' 'cannot fetch Gist %s; check the ID and the token' "$gist_id")"

  local manifest_json
  manifest_json="$(jq -r --arg n "$manifest" '.files[$n].content // empty' <<< "$gist")"
  [ -n "$manifest_json" ] || die "$(msg 'Gist 中不存在清单文件 %s' 'manifest %s is not in the Gist' "$manifest")"
  jq -e '.entries | type == "object"' <<< "$manifest_json" >/dev/null 2>&1 ||
    die "$(msg '清单 %s 不合法：须为含 entries 对象的 JSON' 'manifest %s is invalid: it must be JSON with an entries object' "$manifest")"

  # 清单全部校验通过后才开始写入
  validate_manifest "$manifest_json" "$platform" || exit 1

  # 指定的名字必须全部存在于清单中；在任何写入前检查
  local requested available
  if [ ${#names[@]} -gt 0 ]; then
    available="$(jq -r '.entries | keys_unsorted | join(", ")' <<< "$manifest_json")"
    for requested in "${names[@]}"; do
      jq -e --arg n "$requested" '.entries | has($n)' <<< "$manifest_json" >/dev/null ||
        die "$(msg '清单中不存在条目 %s，可用条目：%s' 'no entry named %s; available entries: %s' "$requested" "$available")"
    done
  fi

  # 空 entries 是合法的无操作：不进入循环，否则空输入会被当作一个失败条目
  if [ "$(jq '.entries | length' <<< "$manifest_json")" -eq 0 ]; then
    msg '清单中没有条目\n' 'The manifest has no entries.\n'
    return 0
  fi

  # 第一阶段：逐个解析校验（只读，不写入）。通过的条目进入清单；不适用于此平台的条目与失败的条目不进入清单。
  # 单个条目失败只记录并继续处理其余条目。rows 按清单顺序记录每个条目：名字<TAB>类别（plan/na/fail）<TAB>目标路径
  local name selected plan="" plan_count=0 rows="" flags="" idx=0 pick_rc=0 prep_rc
  local row_name row_kind row_target name_width
  local fail_names="" ok_count=0 fail_count=0 skip_count=0 na_count=0 na_note
  na_note="$(msg '（不适用于此平台）' ' (not for this platform)')"
  while IFS= read -r name; do
    if [ ${#names[@]} -gt 0 ]; then
      selected=0
      for requested in "${names[@]}"; do
        [ "$requested" = "$name" ] && selected=1
      done
      [ "$selected" -eq 1 ] || continue
    fi
    prep_rc=0
    prepare_entry "$name" "$manifest_json" "$gist" "$platform" || prep_rc=$?
    case "$prep_rc" in
      0)
        plan="${plan}${name}"$'\t'"${PLAN_STRATEGY}"$'\t'"${PLAN_TARGET}"$'\n'
        plan_count=$((plan_count + 1))
        rows="${rows}${name}"$'\t'plan$'\t'"${PLAN_TARGET}"$'\n'
        ;;
      2) rows="${rows}${name}"$'\t'na$'\n'; na_count=$((na_count + 1)) ;;
      *) rows="${rows}${name}"$'\t'fail$'\n'; fail_names="${fail_names} ${name}"; fail_count=$((fail_count + 1)) ;;
    esac
  done <<< "$(jq -r '.entries | keys_unsorted[]' <<< "$manifest_json")"
  plan="${plan%$'\n'}"
  rows="${rows%$'\n'}"

  # 第二阶段：确认。--dry-run 只打印清单；交互终端显示清单并等待按键；非交互（--yes）直接执行全部条目
  if [ "$dry_run" -eq 1 ]; then
    if [ "$plan_count" -gt 0 ]; then
      draw_checklist "$plan" "$(fill_flags 1 "$plan_count")" "$plan_count" -1 "" 0
    fi
    while IFS=$'\t' read -r row_name row_kind _; do
      case "$row_kind" in
        na) print_result_row '[-]' skipped "${row_name}${na_note}" ;;
        fail) print_result_row '[!]' failed "$row_name" ;;
      esac
    done <<< "$rows"
    msg '预览：可执行 %d 项，不适用 %d 项，失败 %d 项\n' 'Preview: %d to run, %d not applicable, %d failed\n' \
      "$plan_count" "$na_count" "$fail_count"
    [ "$fail_count" -eq 0 ] || msg '  失败：%s\n' '  Failed: %s\n' "${fail_names# }"
    [ "$fail_count" -eq 0 ]
    return
  fi
  if [ "$plan_count" -gt 0 ]; then
    if [ "$yes" -eq 0 ] && [ -t 0 ]; then
      pick_entries "$plan" "$plan_count" "$(key_help)" || pick_rc=$?
      case "$pick_rc" in
        0) ;;
        1) msg '已取消，未写入任何文件\n' 'Cancelled. Nothing was written.\n'; return 0 ;;
        *) printf 'cairn: %s\n' "$(msg '无法读取按键输入，未写入任何文件' 'cannot read key input; nothing was written')" >&2; return 1 ;;
      esac
      flags="$PICK_FLAGS"
    else
      flags="$(fill_flags 1 "$plan_count")"
    fi
  fi

  # 第三阶段：按清单顺序逐项输出一行结果。选中的条目执行写入；未选中、不适用与第一阶段已失败的条目也各输出一行，使结果完整。
  # 失败原因已在标准错误中给出，结果行只标明失败
  if [ -n "$rows" ]; then
    msg '执行中…\n' 'Running…\n'
    name_width="$(plan_name_width "$plan")"
    while IFS=$'\t' read -r row_name row_kind row_target; do
      case "$row_kind" in
        na)
          print_result_row '  [-]' skipped "${row_name}${na_note}"
          skip_count=$((skip_count + 1))
          ;;
        fail) print_result_row '  [!]' failed "$row_name" ;;
        plan)
          if [ "${flags:$idx:1}" != 1 ]; then
            print_result_row '  [ ]' skipped "$row_name" "$row_target" "$name_width"
            skip_count=$((skip_count + 1))
          elif ! prepare_entry "$row_name" "$manifest_json" "$gist" "$platform"; then
            print_result_row '  [!]' failed "$row_name" "$row_target" "$name_width"
            fail_names="${fail_names} ${row_name}"; fail_count=$((fail_count + 1))
          elif ! { mkdir -p "$(dirname "$PLAN_TARGET")" &&
            { [ ! -e "$PLAN_TARGET" ] || backup_file "$PLAN_TARGET"; } &&
            if [ "$PLAN_STRATEGY" = merge ]; then printf '%s\n' "$PLAN_MERGED"; else jq -j --arg r "$PLAN_REMOTE" '.files[$r].content' <<< "$gist"; fi | write_atomic "$PLAN_TARGET"; }; then
            entry_error "$row_name" "$(msg '写入 %s 失败' 'cannot write %s' "$PLAN_TARGET")"
            print_result_row '  [!]' failed "$row_name" "$PLAN_TARGET" "$name_width"
            fail_names="${fail_names} ${row_name}"; fail_count=$((fail_count + 1))
          else
            print_result_row '  [x]' written "$row_name" "$PLAN_TARGET" "$name_width"
            ok_count=$((ok_count + 1))
          fi
          idx=$((idx + 1))
          ;;
      esac
    done <<< "$rows"
  fi

  msg '汇总：成功 %d 项，跳过 %d 项，失败 %d 项\n' 'Summary: %d written, %d skipped, %d failed\n' "$ok_count" "$skip_count" "$fail_count"
  [ "$fail_count" -eq 0 ] || msg '  失败：%s\n' '  Failed: %s\n' "${fail_names# }"
  [ "$fail_count" -eq 0 ]
}

# 把本脚本复制到用户的本地可执行目录；不修改任何 shell 配置，只提示 PATH 设置方式
cmd_install() {
  local dir="${HOME}/.local/bin"
  local target="${dir}/cairn"

  [ -f "$SCRIPT_SELF" ] || die "$(msg '无法确定脚本路径，请先把 cairn.sh 保存为文件再安装' 'cannot locate the script; save cairn.sh to a file before installing')"
  mkdir -p "$dir"
  if [ ! "$SCRIPT_SELF" -ef "$target" ]; then
    cp "$SCRIPT_SELF" "$target" || die "$(msg '无法写入 %s' 'cannot write %s' "$target")"
  fi
  chmod 755 "$target"
  msg '已安装 %s\n' 'Installed %s\n' "$target"

  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *)
      msg '提示：%s 不在 PATH 中。请自行在 shell 配置中添加：\n' 'Note: %s is not on your PATH. Add this line to your shell configuration:\n' "$dir"
      # 提示中的 $PATH 需保持字面量，由用户自己的 shell 展开
      # shellcheck disable=SC2016
      printf '  export PATH="%s:$PATH"\n' "$dir"
      ;;
  esac
}

main() {
  if [ $# -eq 0 ]; then
    usage >&2
    exit 1
  fi
  case "$1" in
    -h | --help) usage ;;
    pull) shift; cmd_pull "$@" ;;
    install) shift; cmd_install "$@" ;;
    *) die "$(msg '未知命令：%s' 'unknown command: %s' "$1")" ;;
  esac
}

# 在函数外记录脚本路径：zsh 中函数内的 $0 是函数名
SCRIPT_SELF="$0"
UI_LANG="$(ui_lang)"
main "$@"
