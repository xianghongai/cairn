# 测试

被测脚本 `cairn.sh` 只在一次性 Docker 容器内运行，容器没有网络。仓库以只读方式挂载到容器的 `/workspace`，测试产生的文件全部写在临时目录，容器退出即丢弃。宿主机不执行被测脚本，下面所有命令都在容器内完成。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `compose.yaml` | 测试环境定义：镜像、挂载、无网络、运行命令 |
| `cairn/tests.sh` | 全部非交互测试，经命令行调用 `cairn.sh pull`，同时跑 Bash 与 Zsh |
| `cairn/fake_gist.py` | Mock Gist 服务，`GET /gists/<id>` 返回 `<目录>/<id>.json`，token 不对返回 401 |
| `cairn/validate_manifest.py` | 清单 Schema 的校验辅助，仅用标准库 |

测试只从命令行黑盒验证：检查目标文件的字节内容、备份、退出码和输出，不断言内部函数。

## 一键运行

在仓库根目录执行：

```sh
docker compose -f test/compose.yaml run --build --rm test
```

该命令依次执行以下检查：`bash -n` 与 `zsh -n` 语法检查，`shellcheck` 静态检查，然后分别用 `bash` 与 `zsh` 跑全量测试。每个测试文件结尾输出 `通过 N，失败 M`，有失败项时以非零状态退出。

`--build` 不能省略。镜像一旦构建过就会被复用，修改 `compose.yaml` 后若不加 `--build`，运行的仍是旧镜像，新增的包（例如 `wget`）可能缺失，测试会报 `前提不满足`。

## 进入容器手动调试

进入容器的交互终端，不运行测试：

```sh
docker compose -f test/compose.yaml run --rm test bash
```

进入后当前目录是 `/workspace`，即仓库本身，只读挂载。输入 `exit` 退出，容器随即删除。

## 只跑一种 Shell

容器内的测试文件一次同时跑 Bash 与 Zsh。只想跑其中一种时，在容器里指定 `TEST_SHELL`：

```sh
docker compose -f test/compose.yaml run --rm test bash -c 'TEST_SHELL=zsh bash test/cairn/tests.sh'
```

输出较长时只看失败项和汇总：

```sh
docker compose -f test/compose.yaml run --rm test bash -c "TEST_SHELL=bash bash test/cairn/tests.sh | grep -E 'FAIL|通过'"
```

测试文件不支持只跑单个用例。需要聚焦时，在容器内把 `tests.sh` 复制到 `/tmp`，删去无关段落后再运行（`/workspace` 是只读挂载，不能直接改）。

## 测试端口

Mock Gist 服务默认监听 `18080`，可用 `CAIRN_TEST_PORT` 改端口。容器内网络已关闭，多个容器同时运行互不干扰。

## 手动试用 cairn

在容器内用 Mock Gist 服务跑一次真实的拉取，不碰真实配置。先进入容器：

```sh
docker compose -f test/compose.yaml run --rm test bash
```

然后在容器内执行：

```sh
M="$(mktemp -d)"; G="$M/gists"; H="$M/home"; mkdir -p "$G" "$H"

# 造一个 Gist：清单 + 一个 replace 条目的远程文件
jq -n '{id:"abc123",files:{
  "cairn-manifest.json":{content:"{\"entries\":{\"example\":{\"remote\":\"example-config.txt\",\"path\":\"~/example-config\",\"strategy\":\"replace\"}}}"},
  "example-config.txt":{content:"example = true\n"}}}' > "$G/abc123.json"

# 启动 Mock 服务（后台并记下 PID），然后拉取到临时 HOME；--dry-run 只看计划
python3 test/cairn/fake_gist.py "$G" 18300 tok &
SRV=$!
sleep 1
env -i PATH="$PATH" HOME="$H" CAIRN_API_BASE=http://127.0.0.1:18300 \
  CAIRN_GITHUB_TOKEN=tok CAIRN_GIST_ID=abc123 CAIRN_MANIFEST=cairn-manifest.json \
  bash cairn.sh pull --yes --dry-run
```

去掉 `--dry-run` 即真正写入 `$H/example-config`。试完后 `kill "$SRV"`，容器退出时临时文件一并丢弃。

`cairn.sh --help` 列出命令、选项和主要环境变量（测试用的 `CAIRN_API_BASE` 等不在其中，见源码注释）。

## 编写测试的约定

- 只测业务行为：是否写入、写到哪里、合并结果、备份、退出码，以及校验是否在写入前拦下。不为输出的文案、版式、对齐和帮助文本写用例，这类断言收益低，改一次措辞就要改一批用例。
- 新用例放在对应的 `head_` 段下，沿用 `ok` / `bad` 输出。
- 用 `new_home` 给每个用例独立的 HOME，用 `put_gist` 造 Mock Gist（清单之后可跟任意多组文件名与内容），用 `run_pull` 运行完整配置下的拉取，用 `run_as` 模拟其他平台。
- 需要附加或覆盖环境变量时用 `cairn_env VAR=值 ... 命令`；只有验证缺少某项配置时，才直接写 `env -i ...`。不要修改全局变量。
- 运行被测脚本一律用 `"$SHELL_BIN"`，保证 Bash 与 Zsh 都覆盖到。
- `cairn_env` 把界面语言固定为 `CAIRN_LANG=zh-CN`；需要验证其他语言时在调用处覆盖。
- 交互路径用 `script -qec` 包一层伪终端，并给 stdin 指定 `/dev/null` 作为非交互对照。
- 任何会让进程挂起的用例都要加 `timeout`，超时即视为失败（参见参数缺值与符号链接循环的回归用例）。
- 期望值从真实文件的字节内容或输出中取，不要在断言里重算被测代码的逻辑。

## 已知的边界

- 结论只代表容器内的 Linux 环境。macOS 的分支通过 `CAIRN_UNAME` 环境变量模拟，没有在真实 macOS 上验证。
- TOML 合并只用 `tomlkit`，没有用 `taplo`（`taplo` 不提供深度合并）。
- 下载路径不走真实网络：`curl` 与 `wget` 的端到端用例从本地 HTTP 服务获取脚本。
