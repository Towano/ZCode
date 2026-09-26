# ZCode Linux 本地构建、安装与卸载交互设计

## 目标

为 Linux 当前执行机器提供 CLI / TUI / Web 统一发行包的本地构建、用户级安装、运行验证和卸载流程。普通用户只需要执行仓库根目录中的：

```bash
./zcode-linux
```

本设计不包含 Electron Linux 安装包，也不包含 SEA native binary。

## 普通用户界面

主菜单只显示三个操作：

```text
ZCODE / LINUX CONTROL CONSOLE

[1] Build       编译
[2] Install     安装
[3] Uninstall   卸载
[0] Exit        退出
```

普通用户不需要了解或选择 `check`、`verify`、`package`、`path`、`purge`。这些是内部步骤或维护能力，不出现在主菜单中。

`zcode-linux` 是无扩展名的 Bash 可执行脚本，依靠执行权限和 shebang 运行；`./` 表示执行当前目录中的脚本。用户从仓库根目录运行它，也可以使用绝对路径运行。

## 统一键盘交互

所有会产生副作用的操作统一使用：

- `Enter`：确认当前选择或执行。
- `Esc`：取消、返回上一级或不执行。
- `Ctrl-C`：等同 `Esc`，不得删除已有安装或数据。

任何初始界面都不预选破坏性操作。没有选择时直接按 `Enter` 等同取消。

### 编译确认

编译前显示当前 Linux 平台、架构、版本和输出目录；只有按 `Enter` 才开始。`Esc` / `Ctrl-C` 返回主菜单。

### 安装确认

安装绝不自动选择“最新”或任意构建产物。安装前枚举：

```text
build/zcode-linux/<version>/manifest.json
```

只显示平台为 Linux、架构与当前机器一致且运行目录完整的构建。用户先选择一个构建，再进入确认页；初始没有默认构建。直接 `Enter` 或 `Esc` 不安装。

如果没有可用构建，只提示先执行“编译”，不自动编译。

### 卸载确认

卸载第一屏：

```text
[0] 返回 / 不操作
[1] 卸载程序，保留用户数据
[2] 卸载程序和全部用户数据
```

初始无选择，`Enter` / `Esc` / `Ctrl-C` 均不执行删除。选择后显示将删除的精确路径，再按 `Enter` 执行，`Esc` / `Ctrl-C` 取消。

## 自动环境前置检查

`check` 可以作为主动诊断命令存在，但不是任何流程的前置要求。以下操作必须自动调用环境检查：

- Build：检查构建工具链。
- Install：检查运行时工具链。
- Verify：内部调用时检查运行时工具链。
- Package：内部调用时检查归档工具。

环境检查发生在实际编译、复制、切换安装版本之前；用户不可能因为忘记手动执行 `check` 而进入半失败流程。

### 缺失依赖交互

一次性列出全部缺失依赖，不逐个询问：

```text
ENVIRONMENT CHECK

Distribution: Ubuntu 24.04
Package manager: apt
Architecture: x86_64

Missing dependencies:
  python3
  make
  g++
  pkg-config

Install all missing dependencies? [Y/n]
```

`Enter` 默认同意；`Esc` / `Ctrl-C` 取消并返回，不执行后续操作。确认后只执行一次包管理器安装流程，例如：

```bash
sudo apt update
sudo apt install python3 make g++ pkg-config
```

安装结束后重新检查，仍然缺失则停止并给出明确错误。

### 发行版支持

根据 `/etc/os-release` 识别：

| 发行版族 | 用户可见包管理器 | 构建包名 |
| --- | --- | --- |
| Debian / Ubuntu | `apt` | `python3 make g++ pkg-config` |
| Arch / Manjaro / CachyOS | `pacman` | `python make gcc pkgconf` |
| Alpine | `apk` | `python3 make g++ pkgconf` |

`curl` 仅在需要 bootstrap 缺失的 `mise` 时按需安装：apt 使用 `curl` 包，pacman 使用 `curl` 包，apk 使用 `curl` 包。用户界面显示 `apt`，不显示 `apt-get`。未知发行版只报告缺少的命令和建议手动安装方式，不猜测包管理器。

### Node 和 pnpm

构建工具链要求：

```text
Node.js 24.14.0
pnpm 10.33.2
```

系统包管理器的 Node 版本不能直接视为满足要求。版本缺失或不匹配时，先展示解决方案及完整命令。若未安装 `mise`，批准后通过官方 Linux 安装器将 mise 二进制安装到 `$HOME/.local/bin/mise`；主安装器不修改 shell 配置。若 `curl` 也缺失，先按识别出的支持发行版展示并安装提供 `curl` 的系统包。之后在项目目录将 `mise.toml` 标记为可信，再运行 `mise install`，使用 `mise exec` 校验 Node.js 24.14.0 与 pnpm 10.33.2，再自动继续构建。该授权记录保存在 mise 用户状态中，不会改写仓库配置。不得覆盖系统 Node；取消或任一步安装/版本校验失败时停止，不继续构建。

安装已构建运行包只需要 Node.js，不需要 pnpm、Python 或编译器。

## 构建

### 诊断与批准的自动修复

Build 在执行任何构建或系统安装命令前，只读检查平台、架构、Node/pnpm 版本、发行版构建依赖和已知 workspace 产物。对每个可自动修复的问题展示：问题与原因、解决方案、完整命令行、命令写入/影响路径。用户确认后，按顺序执行已展示的修复命令，重新检查缺失项，再自动继续完整构建；取消不执行命令。

apt、pacman、apk 的预览必须展示将实际执行的全部命令。例如 apt：

```bash
sudo apt update
sudo apt install -y coreutils grep python3 make g++ pkg-config
```

实际执行仍使用参数数组，不把展示文本交给 shell 解释。安装后必须重检命令是否可用；仍缺失则停止并输出剩余项。

TUI runtime staging 要求 `packages/shared/dist/index.js`。`@zcode/shared` 是 TypeScript workspace 包，Build 必须先展示并执行对应的 workspace 构建命令；该命令由用户在 Build 计划中一次批准，随后自动完成，不要求使用者手动补跑 `pnpm build`。

只允许执行代码中明确注册、可审计且在批准计划中列出的修复命令。已知修复执行失败时保留原始错误并停止；未知构建错误不得从日志中猜测或执行命令，必须报告失败步骤、原始命令、日志位置及可安全执行的诊断命令。

### 构建流水线

Build 内部执行：

1. 自动环境前置检查。
2. 构建 `@zcode/shared`，生成 TUI runtime staging 所需的入口文件。
3. 构建 CLI/TUI/Agent workspace。
4. 构建 Server。
5. 构建 Web。
6. 收集 TUI native、worker、Web、Server、Agent 和递归运行时依赖。
7. 生成：

```text
build/zcode-linux/<version>/zcode/
build/zcode-linux/<version>/manifest.json
```

8. 自动完成本地构建 smoke 验证。

构建根据当前 `process.platform` / `process.arch` 工作，只支持 Linux x64 和 Linux arm64，不允许参数伪造架构或跨架构编译。

## 安装

Install 内部执行：

1. 自动环境前置检查。
2. 枚举并要求用户选择构建目录。
3. 复制到：

```text
$HOME/.zcode/runtime/releases/<version>
```

4. 验证版本、TUI、Web、HTTP、WebSocket 和退出链路。
5. 验证通过后才切换 `current`。
6. 创建：

```text
$HOME/.local/bin/zcode
$HOME/.zcode/uninstall.sh
```

7. 自动配置用户 PATH，不要求用户手动输入 `export PATH=...`。

安装失败不得替换已有可用版本，也不得留下指向不存在 runtime 的 wrapper。

## PATH

PATH 配置是安装内部步骤，不是普通菜单选项。Bash 使用通用配置：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

安装默认配置；用户选择跳过时使用内部 `--no-path` 维护参数。配置必须幂等、保留 owner 和权限，并记录安装器实际新增内容到：

```text
$HOME/.zcode/install-state.json
```

## 卸载

默认卸载删除程序并保留：

```text
$HOME/.zcode/v2
$HOME/.zcode/workspace
$HOME/.zcode/cli
```

完全卸载由卸载界面的第二个选项触发，删除程序和用户数据。执行前必须显示精确路径并等待 `Enter`；`Esc` / `Ctrl-C` 取消。

独立卸载脚本不依赖源码、Node、pnpm、build 或 release。

## 权限和安全

- 用户级安装不调用 sudo。
- 依赖安装可以在明确确认后使用系统包管理器的 sudo。
- 检查外部符号链接、路径 owner 和空变量，拒绝危险删除。
- 构建临时内容位于仓库 `build/zcode-linux/`，不使用系统 `/tmp`。
- 发行归档位于仓库根目录 `release/`。
- 本地运行包仍需要 Node.js，不需要 pnpm。
