# 示例与合并规则

本文用小例子说明清单的写法，以及每种合并规则的结果。规则的完整定义见 [README.zh-CN.md](README.zh-CN.md)。

## 清单的形态

清单是一个 JSON 对象，`entries` 的键是条目名，值是条目对象。

```json
{
  "entries": {
    "shell-profile": {
      "remote": "shell-profile.sh",
      "path": "~/.shell-profile",
      "strategy": "replace"
    },
    "app-settings": {
      "remote": "app-settings.json",
      "path": { "default": "~/.config/example/settings.json", "macos": "~/Library/Example/settings.json" },
      "strategy": "merge",
      "rules": {
        "arrays": { "default": "replace" },
        "objects": { "default": "override" }
      }
    }
  }
}
```

条目对象的字段：

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `remote` | 是 | Gist 中的文件名 |
| `path` | 是 | 字符串，或带 `default` 与平台键的对象 |
| `strategy` | 是 | `replace` 或 `merge` |
| `format` | 否 | `merge` 时使用，缺省时由 `remote` 的后缀推断 |
| `rules` | 否 | 仅对 `merge` 有效 |
| `description` | 否 | 备注，供自己查阅 |

## path 的写法

- 字符串：所有平台都使用这一个路径。
- 对象：`default` 为默认值，`linux`、`macos`、`windows` 为平台覆盖。当前平台的键优先，没有则用 `default`，两者都没有则该条目不适用于此平台，执行时跳过。
- `~` 表示用户 Home，`./` 表示运行脚本时的当前目录，没有前缀的相对路径也相对于当前目录，绝对路径直接使用。
- 路径以 `/` 结尾，或者只写 `~` 或 `.`，表示目录。文件写入该目录，文件名取 `remote` 的文件名。

```json
"path": "~/"
```

上面的写法会把 `remote` 对应的文件写到用户 Home 下，文件名与 `remote` 相同。

## format 的推断

`merge` 条目未写 `format` 时，按 `remote` 的后缀推断：

| 后缀 | 格式 |
| --- | --- |
| `.json` | `json` |
| `.jsonc` | `jsonc` |
| `.yaml`、`.yml` | `yaml` |
| `.toml` | `toml` |

后缀与实际内容不一致时，自己声明 `format`。例如文件名是 `.json`，内容却是带注释的 JSONC，就写 `"format": "jsonc"`。声明的值优先于推断。推断不出时必须声明，否则在写入前报错。

## 策略：replace 与 merge

`replace` 整文件写入目标路径，本机原有内容被丢弃。

`merge` 把远程内容深度合并进已有文件。远程的内容是从顶层键开始的完整嵌套结构，合并只作用于远程内容中出现的路径，本机其它位置保持不变。

## rules

`rules` 分两部分，分别控制数组与对象。

| 设置 | 取值 | 含义 | 缺省 |
| --- | --- | --- | --- |
| `arrays.default` | `replace` | 本机数组整体替换为远程数组 | 是 |
| `arrays.default` | `override` | 保留本机项及顺序，追加远程新增的项，按整个值去重 | |
| `arrays.default` | `append` | 远程数组原样接在本机数组之后，不比较值，不去重 | |
| `objects.default` | `override` | 远程同名键覆盖本机的值，本机独有的键保留，递归进入子对象 | 是 |
| `objects.default` | `replace` | 本机该对象整体替换为远程对象，本机独有的键被删除 | |

`paths` 为完整点号路径到取值的映射，例如 `"servers.app": "replace"`。它只精确匹配该路径，不做通配符匹配，优先于 `default`。路径只在远程内容中出现时才生效。

键名不能包含 `.`，因为 `.` 用于分隔路径。

### 示例：数组 replace

本机：

```json
{ "tools": { "allow": ["a", "b"] } }
```

远程：

```json
{ "tools": { "allow": ["c"] } }
```

结果：

```json
{ "tools": { "allow": ["c"] } }
```

### 示例：数组 override

本机：

```json
{ "items": ["a", "b", "b"] }
```

远程：

```json
{ "items": ["b", "c"] }
```

结果：

```json
{ "items": ["a", "b", "c"] }
```

本机已有的项保持原有顺序，远程新增的 `c` 追加在末尾。重复的值只保留一份，本机内部的重复也会被去掉。去重只比较整个值，不判断内容层面的冲突。

### 示例：数组 append

本机：

```json
{ "items": ["a", "b", "a"] }
```

远程：

```json
{ "items": ["b", "c"] }
```

结果：

```json
{ "items": ["a", "b", "a", "b", "c"] }
```

相同的值不做判断，可以作为不同的项并存。再拉取一次会再追加一遍 `b`、`c`，因此只适合每次执行都应追加的场景。

### 示例：对象 override（缺省）

本机：

```json
{ "editor": { "font_size": 12, "tab_size": 2 }, "theme": "dark" }
```

远程：

```json
{ "editor": { "font_size": 14 } }
```

结果：

```json
{ "editor": { "font_size": 14, "tab_size": 2 }, "theme": "dark" }
```

远程的 `font_size` 覆盖本机的值，本机独有的 `tab_size` 和 `theme` 保留。

### 示例：对象 replace

规则：

```json
"rules": {
  "objects": { "paths": { "servers.app": "replace" } }
}
```

本机：

```json
{ "servers": { "app": { "args": ["x"], "env": { "X": "1" }, "kind": "local" }, "other": { "kind": "local" } } }
```

远程：

```json
{ "servers": { "app": { "args": ["y"], "kind": "local" } } }
```

结果：

```json
{ "servers": { "app": { "args": ["y"], "kind": "local" }, "other": { "kind": "local" } } }
```

`servers.app` 整块替换为远程的内容，本机的 `env` 被删除。`servers.other` 不在远程内容中，保持不变。

### 示例：逐层决定合并还是替换

每一层都可以单独决定：远程只提供一部分内容时用合并，远程内容完整时用整块替换。下面三种写法用的是同一份本机内容：

```json
{ "settings": { "access": { "read": ["r1", "r-local"], "write": ["w1"], "review": ["v-local"] }, "enabled": true, "local_only": 1 } }
```

远程只提供 `review`，其余列表保留本机的，规则为 `"arrays": { "default": "override" }`：

```text
远程：{ "settings": { "access": { "review": ["v1"] }, "enabled": false } }
结果：{ "settings": { "access": { "read": ["r1", "r-local"], "write": ["w1"], "review": ["v-local", "v1"] }, "enabled": false, "local_only": 1 } }
```

同样的远程内容，但 `review` 以远程为准，在上面的规则中加上 `"paths": { "settings.access.review": "replace" }`，结果中 `review` 为 `["v1"]`，其余不变。

远程提供完整的 `access`，整块替换本机的 `access`，规则为 `"objects": { "paths": { "settings.access": "replace" } }`：

```text
远程：{ "settings": { "access": { "read": ["r1", "r2"], "write": ["w1"], "review": ["v1"] }, "enabled": false } }
结果：{ "settings": { "access": { "read": ["r1", "r2"], "write": ["w1"], "review": ["v1"] }, "enabled": false, "local_only": 1 } }
```

`access` 与远程完全一致，本机独有的 `r-local` 与 `v-local` 被删除；`settings` 这一层仍按合并处理，`local_only` 保留。

### 示例：路径精确匹配

`"servers.app": "replace"` 只精确匹配 `servers.app`，不影响它的父级 `servers` 本身。`servers.app` 之下的键（例如 `servers.app.env`）随整块一起被替换。要替换 `servers` 整块，需要在 `paths` 中单独写 `"servers": "replace"`。

### 示例：规则冲突

上级对象整块替换后，其下取 `override` 的规则不会生效，Cairn 在写入前把它报告为冲突：

```json
"rules": {
  "objects": { "default": "replace", "paths": { "servers.app": "override" } }
}
```

`servers` 按 `default` 整块替换，`servers.app` 的 `override` 无从生效。要让它生效，把沿途的上级也设为 `override`：`"paths": { "servers": "override", "servers.app": "override" }`。
