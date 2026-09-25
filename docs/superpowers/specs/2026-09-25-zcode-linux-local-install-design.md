# ZCode Linux 本地构建与用户级安装设计

## 目标

为 ZCode 的 CLI / TUI / Web 统一发行包提供 Linux 当前实机架构上的本地构建、用户级安装、运行验证、发行归档和独立卸载能力。

本设计不包含 Electron Linux 安装包，也不把 SEA native binary 作为本次安装产物。

## 用户入口

仓库根目录提供两个用户可见脚本：

```text
zcode-linux
uninstall-linux.sh
```

`zcode-linux` 负责：

- 无参数时显示终端交互菜单。
- `build`：编译当前 Linux 平台和架构。
- `install`：从本地可运行构建目录或显式 tar.gz 安装。
- `verify`：验证已安装命令、Web、WebSocket 和退出链路。
- `package`：生成根目录 `release/` 下的 tar.gz 和 MD5。
- `path`：检查或配置用户 Shell 的命令路径。
- `uninstall` / `purge`：调用当前源码中的卸载逻辑。
- `-h`、`--h`、`--help`：输出命令和参数说明。

`uninstall-linux.sh` 是安装时复制到 `~/.zcode/uninstall.sh` 的独立脚本。复制后的脚本不依赖源码、Node、pnpm、build 或 release 目录。

## 本地目录

所有新建的构建临时内容留在仓库内，不使用 `/tmp`、`/var/tmp` 或用户缓存目录。

```text
build/zcode-linux/<version>/
  zcode/          # 完整可运行目录
  manifest.json
  smoke/          # 验证过程临时内容

release/
  zcode-<version>-linux-<arch>.tar.gz
  zcode-<version>-linux-<arch>.tar.gz.md5
```

`build/` 是本地可运行构建目录；`release/` 只保存可选发行归档。默认本地安装直接使用 `build/`，不强制经过 tar.gz。

## 平台和架构

构建必须在 Linux 上运行，并根据执行时的 `process.platform`、`process.arch` 选择当前平台和架构：

- `linux + x64` → `linux-x64`
- `linux + arm64` → `linux-arm64`

非 Linux、未知架构或不支持架构时立即失败。不允许用参数伪造目标架构或进行跨架构编译。

## 安装位置

固定使用当前用户目录，不提供安装目录参数：

```text
程序：$HOME/.zcode/runtime
命令：$HOME/.local/bin/zcode
卸载：$HOME/.zcode/uninstall.sh
```

安装过程不使用 sudo，不写入 `/usr/bin`、`/usr/local/bin`、`/opt` 或 `/etc`。

安装后的命令包装器使用安装时解析到的 Node 路径作为优先路径，并在路径失效时回退到 `command -v node`。运行发行包需要 Node，不依赖 pnpm。

## 安装验证

安装不是单纯复制文件。安装脚本在更新 `current` 前后必须验证：

1. `zcode --version` 返回构建版本。
2. `zcode --web --help` 可执行。
3. Web server 可以启动并输出本地 URL。
4. `/api/server-info` 返回成功。
5. WebSocket 可以连接。
6. Web server 可以正常退出。

验证失败时返回非零状态，不报告安装成功，不更新 `current`，并保留既有可用版本。

## PATH 配置

安装默认配置用户 PATH；只有显式传入 `--no-path` 才跳过。

Bash 的核心配置是通用语句，不加入 ZCode 专属注释：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

该语句放在 `~/.bashrc` 顶层，并尽量位于 Bash 的非交互提前 `return` 之前。已经存在相同配置时不重复写入。

如果 Bash 登录入口不会加载 `~/.bashrc`，在实际生效的 `~/.bash_profile`、`~/.bash_login` 或 `~/.profile` 中确保存在：

```bash
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
```

安装程序不在 Shell 配置中写入 ZCode 专属注释；自身的修改记录写入 `~/.zcode/install-state.json`，权限为 `0600`。卸载时只撤销安装程序实际新增的行，不删除用户原有相同配置。

当前已运行的父 Shell 无法被子进程直接修改；安装完成后提示 `source ~/.bashrc`，新终端自动生效。

非 Bash 环境不写 Bash 语法：Zsh 使用 `~/.zshrc`，Fish 使用 `fish_add_path`，未知 Shell 不盲目修改。

## 权限

```text
~/.zcode                  0700
~/.zcode/runtime          0755
~/.zcode/runtime/releases 0755
~/.local                  0755
~/.local/bin              0755
~/.local/bin/zcode        0755
~/.zcode/uninstall.sh     0700
~/.zcode/install-state.json 0600
用户数据目录               0700
```

已有 Shell 配置文件保留原权限和 owner；新建 `~/.bashrc` / `~/.profile` 使用 `0644`。安装必须检查目标目录 owner、危险符号链接和写权限。

## 卸载

默认：

```bash
~/.zcode/uninstall.sh
```

删除程序 runtime、`current` 和 `~/.local/bin/zcode`，保留会话、工作区和配置数据。

完全卸载：

```bash
~/.zcode/uninstall.sh --purge
~/.zcode/uninstall.sh --purge --yes
```

`--purge` 删除 ZCode 用户数据，撤销安装程序自己新增的 PATH / Bash 登录配置，最后删除自身。

## 交互菜单

无参数执行 `./zcode-linux` 时显示 ANSI 终端菜单，展示平台、架构、构建状态、安装状态和 PATH 状态。菜单操作包含 build、install、verify、package、path、uninstall、purge 和 exit。无外部 TUI 依赖，颜色不可用时回退纯文本。
