# uv-offline-tool

在**联网的机器**上用 GitHub Actions 把 Python 包的 wheel / sdist 全部下载好，再在**离线机器**上一条命令装完 —— 不需要 PyPI，不需要内网镜像源。

```
GitHub Actions (联网)                                离线机器
┌───────────────────────────┐                      ┌────────────────────────────┐
│ uv-offline-tool.yml       │      artifact        │ 解压后 ./install.sh -- <包>  │
│ pip download → wheels/    │ ───zip（内含───────▶ │ 或 -w <zip|tar.gz|wheels>  │
│ → install.sh + *.tar.gz   │   install.sh+压缩包） │ uv/pip install --no-index  │
└───────────────────────────┘                      └────────────────────────────┘
```

## 仓库结构

```
.github/workflows/uv-offline-tool.yml   下载 + 打包 artifact 的 workflow（手动触发）
install.sh                              离线安装脚本（通用，任意包；artifact 里也带一份）
```

## 快速开始

### 1. 在 Actions 里下载产物

Actions → **Download uv tool wheels** → *Run workflow*，填两个输入：

| 输入 | 说明 | 默认 |
| --- | --- | --- |
| `python_version` | 目标机上的 Python 版本，如 `3.12` | `3.12` |
| `packages` | 包名，空格分隔；可带版本/extras，如 `qwenpaw[hub] ruff==0.6.9` | `ruff` |

跑完后在该次 run 页面底部下载 artifact，名字由**包名 + Python 版本**拼成（保留 30 天）：

| `packages` 输入 | artifact 名 |
| --- | --- |
| `ruff` | `ruff-py3.12` |
| `qwenpaw[hub]` | `qwenpaw-hub-py3.12` |
| `black mypy` | `black-mypy-py3.12` |
| `ruff==0.6.9` | `ruff-0.6.9-py3.12` |

文件名里不允许的字符（`: < > | " / \ * ?`、空格等）会统一换成 `-`，下载下来的 zip 就是 `<artifact 名>.zip`。

每个 artifact 里只有两个文件：

```
qwenpaw-hub-py3.12.zip          # 从 Actions 下载的 artifact
├── install.sh                  # 离线安装脚本
└── qwenpaw-hub-py3.12-wheels.tar.gz   # 所有 wheel / sdist 的压缩包
```

> 例：`python_version=3.12`、`packages=qwenpaw[hub]` 会得到约 240 MB 的产物。

### 2. 在离线机器上安装

把 artifact zip 拷过去，解压后目录里就有 `install.sh`，直接跑即可（脚本会自动找到旁边的 wheels 压缩包）：

```bash
unzip qwenpaw-hub-py3.12.zip
./install.sh -- 'qwenpaw[hub]'
```

也可以不手动解压，把 zip / 压缩包直接交给脚本：

```bash
./install.sh -w qwenpaw-hub-py3.12.zip -- 'qwenpaw[hub]'          # artifact zip
./install.sh -w qwenpaw-hub-py3.12-wheels.tar.gz -- 'qwenpaw[hub]' # 只给 wheels 压缩包
./install.sh -w ./wheels -- 'qwenpaw[hub]'                         # 已解压的 wheels 目录
```

脚本会新建虚拟环境 `./.uv-offline-venv`，并用 `--no-index` 从产物里完成安装。

常用变体：

```bash
# 装成全局命令行工具（如 ruff/black，需要机器上有 uv）
./install.sh -w ./wheels -m tool -- ruff

# 装进已存在的解释器
./install.sh -w ./wheels -m pip -p /usr/bin/python3.12 -- black mypy

# 只看产物内容与预检查（不安装）
./install.sh -w ./wheels --list

# 只打印将要执行的命令
./install.sh -w ./wheels -N -- oss2
```

## install.sh 用法

```
用法: ./install.sh [选项] -- 包名 [包名...]
```

| 选项 | 说明 |
| --- | --- |
| `-w, --wheels PATH` | 产物位置，可以是：wheels 目录、artifact `*.zip`、`*wheels.tar.gz`。留空时自动探测 `./wheels`、`./*/wheels`（解压后的 artifact）、当前目录下的压缩包 |
| `-m, --mode MODE` | `venv`（默认，新建/复用虚拟环境）、`tool`（`uv tool install`）、`pip`（直接装进 `--python` 解释器） |
| `-p, --python PATH` | 解释器，默认 `python3`；也是 venv 的基础解释器 |
| `-e, --env DIR` | `mode=venv` 的虚拟环境目录，默认 `./.uv-offline-venv` |
| `-n, --no-build-isolation` | 构建 sdist 时不做构建隔离 |
| `--build-isolation` | 强制开启构建隔离（覆盖 `-n` 与自动判断） |
| `-l, --list` | 只列出产物内容 + 预检查结果 |
| `-N, --dry-run` | 只打印命令，不执行 |
| `-q, --quiet` | 少打印脚本自己的日志 |

包名后面必须写 `--`，否则形如 `-x` 的参数会被当成选项。

### 离线是怎么保证的

- pip：`--no-index --find-links <产物目录>`，禁用 PyPI，只用本地目录。
- uv：再加 `--offline`，彻底禁止网络访问。
- sdist 的构建依赖（`setuptools`/`wheel`）也走同一个本地目录解析，所以构建过程同样不联网。

## Workflow 的下载逻辑

1. **第一轮：只要 wheel** —— `pip download --dest wheels --only-binary=:all: <packages>`。
   产物最干净，离线安装无需任何构建。
2. **第二轮：放宽** —— 只要有包没有 wheel（如 `oss2`、`crcmod`、`alibabacloud-tea` 只发布 sdist），自动改为「优先 wheel，缺 wheel 时用 sdist」重试，并在日志里 `::warning::` 指出是哪些包。
3. **附带构建依赖** —— 若产物里出现 `.tar.gz`，再补下载 `setuptools`、`wheel`，保证离线机器能构建这些 sdist。
4. 若两轮都失败，报错并提示原因（如 Python 版本不满足包的 `requires-python`，例如 `qwenpaw` 只支持 `3.11 ≤ x < 3.14`）。
5. **打包** —— 把 `wheels/` 压成 `<artifact 名>-wheels.tar.gz`，连同仓库里的 `install.sh` 一起上传；下载下来只用一份 artifact 就能离线安装。

## 常见问题

**Q: 以前失败过，报 `Could not find a version that satisfies the requirement oss2>=2.19.1`？**
`oss2` 上游只发布 sdist，而原来写死了 `--only-binary=:all:`，pip 认为「没有任何可用版本」。现在会自动放宽，见上文第 2 步。

**Q: 报 `No matching distribution found for qwenpaw[hub] (from versions: none)`？**
Python 版本不符合包的 `requires-python`。`qwenpaw` 只支持 3.11~3.13，用 3.14 必然失败，改用 `python_version=3.12` 重跑。

**Q: 离线机上装不上，提示 wheel 与平台不匹配？**
产物是在 CI 的 `ubuntu-latest` 上按指定 Python 版本下载的（例如 `cp312-manylinux_2_17_x86_64`）。离线机需与之匹配：同架构（x86_64/aarch64）、同 Python 次版本。`install.sh --list` 会做一次预检查和告警。若目标机不是 Linux x86_64，请调整 workflow 的 `runs-on`。

**Q: 提示 `目标环境缺少 setuptools，离线状态下无法构建 sdist`？**
旧产物里没带构建依赖。两个办法：重新跑一次 workflow（新版会自动附带 `setuptools wheel`，推荐），或在 CI 的 `packages` 里显式写上 `setuptools wheel`。

**Q: `-m tool` 装完命令找不到？**
`uv tool install` 的可执行文件默认落在 `~/.local/bin`（`uv tool dir --bin` 可查），确认它在 `PATH` 里。

**Q: 想严格固定版本？**
在 `packages` 里写 `==`，例如 `qwenpaw==2.2.1`。否则下载到的是当时的最新版本，离线安装时的解析结果可能与联网环境不同。
