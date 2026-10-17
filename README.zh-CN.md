# Cairn

> Cairn（石堆）是用石头堆出的路径标记。

[English](README.md) | [简体中文](README.zh-CN.md)

把一组用户级配置文件保存在私有 GitHub Gist 中，在不同机器上把各个文件拉取到正确的位置。

## 为什么需要

Linux 与 macOS 机器上保存着同样的配置文件，但常常存在以下差异：

- **路径不同**：同一个文件在 Linux 上位于 `~/.config/...`，在 macOS 上可能位于 `~/Library/...`。
- **格式不同**：纯文本、JSON、JSONC、YAML 与 TOML 可能同时出现在同一套配置中。
- **有些文件只是片段**：某个设置文件里只有几项需要共享，其余部分留在本机。整文件覆盖会抹掉不想改动的内容。

Cairn 把文件保存在私有 Gist 中，并用清单（Manifest）描述每个文件。`cairn pull` 读取清单，按条目把文件写入本机的对应位置，写入方式可以是整文件替换，也可以是合并。

## 功能

- **以 Gist 为唯一来源**：清单与文件都保存在同一个私有 Gist 中，运行时获取，本机不保留副本。
- **按平台指定路径**：同一条目可以为 Linux 与 macOS 指定不同的目标路径。
- **两种写入策略**：`replace` 整文件写入；`merge` 把远程片段深度合并进已有文件。
- **按类型设置合并规则**：`rules` 分别设置数组与对象的合并方式，可以设缺省值，也可以按路径单独指定。
- **合并时保留注释**：JSONC、YAML 与 TOML 合并会保留目标文件中已有的注释。
- **默认安全**：写入前先在执行清单中选择条目；覆盖前备份原文件；`--dry-run` 只预览不写入；写入系统目录会被拒绝。
- **失败互不影响**：某个条目失败不会阻止其余条目，结束时输出汇总，有失败则以非零状态退出。
- **便于获取**：脚本是单个文件，可以用 curl 或 wget 下载后直接运行，也可以安装到 `~/.local/bin`。

## 依赖

| 工具 | 用途 |
| --- | --- |
| Bash 或 Zsh | 运行脚本 |
| `curl` | 获取 Gist |
| `jq` | 每次运行都需要（读取清单） |
| `yq`（mikefarah 版，v4） | YAML 合并 |
| `python3` 与 `tomlkit` | TOML 合并 |
| `node` 与 `jsonc-parser` | JSONC 合并（用 `NODE_PATH` 指向 `jsonc-parser` 的安装目录） |

只有用到某种格式的 `merge` 条目才需要对应的工具，缺少时报错中会给出安装方式。

Cairn 支持 Linux 与 macOS，暂不支持 Windows。

## 快速开始

1. 创建一个私有 Gist，放入清单与清单所描述的文件。清单格式见下文。
2. [创建 GitHub token](https://github.com/settings/tokens/new?scopes=gist&description=Cairn)。链接已预选读取 Gist 所需的 `gist` 权限。
3. 运行 Cairn：

```sh
export CAIRN_GIST_ID=<gist-id>
export CAIRN_GITHUB_TOKEN=<token>

curl -fsSL https://raw.githubusercontent.com/xianghongai/cairn/main/cairn.sh -o cairn.sh
# 或：wget -qO cairn.sh https://raw.githubusercontent.com/xianghongai/cairn/main/cairn.sh

bash cairn.sh pull --dry-run    # 预览，不写入
bash cairn.sh pull              # 在执行清单中选择条目，然后写入
```

运行 `bash cairn.sh install` 可以把脚本安装为 `~/.local/bin/cairn` 命令。

## 清单（Manifest）

清单是保存在 Gist 中的 JSON 文件，缺省文件名为 `cairn-manifest.json`。顶层为 `entries` 对象，键是条目名，值是描述单个文件的条目。JSON Schema 位于 [cairn-manifest.schema.json](cairn-manifest.schema.json)，编辑器指向该文件后即可校验。

```json
{
  "entries": {
    "app-settings": {
      "remote": "example-config.json",
      "path": "~/.config/example/settings.json",
      "strategy": "merge",
      "rules": {
        "arrays": { "default": "override" }
      }
    },
    "app-keys": {
      "remote": "app-keys.conf",
      "path": {
        "default": "~/.config/example/",
        "macos": "~/Library/Application Support/Example/"
      },
      "strategy": "merge",
      "format": "toml",
      "description": "按键设置，合并进本地文件"
    }
  }
}
```

| 字段 | 必需 | 含义 |
| --- | --- | --- |
| `remote` | 是 | Gist 中的文件名。 |
| `path` | 是 | 目标路径，写法见下文。 |
| `strategy` | 是 | `replace` 或 `merge`。 |
| `format` | 否 | `json`、`jsonc`、`yaml` 或 `toml`。`merge` 省略时按 `remote` 的后缀推断（`.json`、`.jsonc`、`.yaml`/`.yml`、`.toml`）。 |
| `rules` | 否 | 合并规则，只用于 `merge` 条目，见下文。 |
| `description` | 否 | 备注。 |

`path` 的写法：

- 字符串适用于所有平台；对象中 `default` 为缺省值，`linux`、`macos`、`windows` 为平台覆盖。当前平台的键优先，其次 `default`，两者都没有时该条目在此平台跳过。
- `~` 与 `~/...` 相对于用户 Home；`.`、`./...` 与没有前缀的相对路径相对于当前目录；绝对路径原样使用。
- 以 `/` 结尾，或只写 `~`、`.`，表示目录，文件以 `remote` 的文件名写入其中。
- 解析 `..` 与符号链接后落在 `/etc`、`/System` 等系统目录内的路径，写入前即被拒绝；用户 Home 之内的路径始终允许。

## 合并规则

`rules` 有两类规则：

- `arrays`：数组的合并方式，缺省 `replace`。
- `objects`：对象的合并方式，缺省 `override`。

每类都可以设置：

- `default`：作用于片段中该类型的所有位置，不论嵌套多深。
- `paths`：按完整点号路径为某一个位置单独指定，优先于 `default`。

可选的取值：

- **`replace`**：以远程为准，本机该位置整体替换。
  - 对象：本机独有的键被删除。
  - 数组：本机的项全部被远程数组取代。
- **`override`**：保留本机内容，再叠加远程内容。
  - 对象：远程同名键覆盖本机的值，本机独有的键保留，逐层递归。
  - 数组：保留本机项及其顺序，追加远程新增的项，按整个值去重。
- **`append`**（仅数组）：远程数组原样接在本机数组之后。
  - 不比较值，也不去重，相同的值可以作为不同的项并存。
  - 每次拉取都会再追加一遍，只适合每次执行都应追加的场景。

```json
"rules": {
  "arrays": {
    "default": "override",
    "paths": { "permissions.deny": "replace" }
  },
  "objects": {
    "paths": { "servers.example": "replace" }
  }
}
```

这个例子的效果：

- `permissions.deny` 数组整体替换为远程的数组。
- 其余数组按 `override` 合并。
- `servers.example` 对象整体替换为远程的对象，其下本机独有的键被删除。

规则细节：

- `paths` 只精确匹配完整路径，不支持通配符，只作用于远程片段中出现的路径。
- 取 `override` 或 `append` 的路径，如果位于规则为 `replace` 的上级对象之下，规则不会生效，写入前报冲突。要保留它，需要把沿途的上级对象都设为 `override`。
- 目标文件为空时按空对象合并。
- 各格式的规则一致。

更多示例见 [EXAMPLE.md](EXAMPLE.md)。

## 命令

```text
cairn.sh pull [选项] [名字 ...]
cairn.sh install
cairn.sh --help
```

| 选项 | 含义 |
| --- | --- |
| `--gist ID` | Gist ID，覆盖 `CAIRN_GIST_ID`。 |
| `--manifest NAME` | Gist 中的清单文件名，缺省为 `cairn-manifest.json`，覆盖 `CAIRN_MANIFEST`。 |
| `--dry-run` | 预览每个条目的策略与真实目标路径，不写入任何文件。 |
| `--yes` | 不显示执行清单，直接写入全部条目。没有终端时必须指定。 |

指定名字时只处理对应的条目，例如 `cairn.sh pull app-keys`；不带名字时处理全部条目。

| 环境变量 | 含义 |
| --- | --- |
| `CAIRN_GIST_ID` | Gist ID。 |
| `CAIRN_MANIFEST` | Gist 中的清单文件名，缺省为 `cairn-manifest.json`。 |
| `CAIRN_GITHUB_TOKEN` | GitHub token，只从环境变量读取，不会出现在 shell 历史或进程列表中。 |
| `CAIRN_LANG` | 输出语言，取 BCP 47 标签 `en` 或 `zh-CN`。未设置时按 `LC_ALL`、`LC_MESSAGES`、`LANG` 选择，以 `zh` 开头时输出简体中文，其余输出英文。 |
| `NO_COLOR` | 设为非空值时，按键提示不使用颜色（[no-color.org](https://no-color.org)）。 |

命令行选项优先于环境变量。

## 安全

- **执行清单**：在终端中，写入前列出每个条目的策略与目标路径，默认全部不勾选。`↑`/`↓` 或 `j`/`k` 移动，空格切换，`a` 全选，`n` 全不选，回车写入，`q` 或 Esc 取消。没有终端时，必须指定 `--yes` 才会写入。
- **备份**：覆盖或合并前，原文件复制到 `$XDG_STATE_HOME/cairn/backup/`（未设置或不是绝对路径时为 `~/.local/state/cairn/backup/`），文件名带时间戳。
- **原子写入**：先写临时文件再替换目标，写入失败时原文件保持不变。
- **符号链接**：目标为符号链接时写入其指向的文件，链接本身保持不变。
- **先校验后写入**：清单有误时，在任何写入之前停止。

## 已知限制

- 只包含注释的 YAML 目标，合并后会丢失这些注释。
- TOML 合并只使用 `tomlkit`；`taplo` 无法做深度合并，因此不使用。
- `rules` 的路径无法指定键名本身含点号的键（如 `"a.b"`），点号会被当作路径分隔符。

## 开发

测试在 Docker 中运行，详见 [test/README.md](test/README.md)：

```sh
docker compose -f test/compose.yaml run --build --rm test
```

## License

[MIT](LICENSE)
