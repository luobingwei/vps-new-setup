# vps-setup

一键为**新买的 VPS** 初始化环境。内置常用 VPS 部署的 5 步操作。支持 Debian/Ubuntu、CentOS/Rocky/Alma/Fedora。

## 🚀 一键执行（在 VPS 上以 root / sudo 运行）

```bash
curl -fsSL https://raw.githubusercontent.com/luobingwei/vps-new-setup/main/setup.sh | sudo bash
```

- 默认弹出**勾选式菜单**，只装你勾选的模块；
- 会自动**预检环境**，缺 git/curl 等自动补装，保证全新 VPS 可直接跑；
- 想要**全自动**（跳过菜单，按配置文件默认值执行）：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/luobingwei/vps-new-setup/main/setup.sh | sudo bash -s -- --auto
  ```

## 核心 5 步

| 模块 | 作用 | 说明 |
|------|------|------|
| swap | 自动创建交换分区 | 原生实现，也可切 zhucaidan/swap.sh |
| bbr | 原生启用 BBR+FQ（内核≥6.8 即 BBRv3），默认不装第三方内核 | 安全原生实现 |
| reboot | 每天凌晨 4 点自动重启 | 写入 crontab，幂等 |
| ssh | 从 GitHub 拉公钥 + 改端口 + 仅密钥登录 | 用户名交互输入，默认端口 2222 |
| zsh | Zsh + Oh My Zsh + powerlevel10k，应用配置、跳过向导 | 默认通用配置，可放自己的 |

## 使用方法

```bash
# 1. 上传到服务器（任选）
scp -r vps-setup root@你的IP:/opt/
# 或
git clone https://github.com/你的用户名/vps-setup.git && cd vps-setup

# 2.（可选）改配置
vim conf/setup.conf

# 3. 运行
bash setup.sh                     # 默认：环境预检 + 终端勾选式菜单（推荐）
bash setup.sh --auto              # 全自动，跳过菜单与交互（用配置里的值）
bash setup.sh -m swap,ssh,zsh     # 只跑指定模块
bash setup.sh --dry-run           # 预览将要执行的操作
```

**运行前自动预检环境**：工具会先检查必需工具（curl/wget/git/sysctl/crontab 等），**缺失的会自动用包管理器安装好**（比如 git、curl），装不上才报错停止；同时检查磁盘空间能否支撑 swap——保证一台全新 VPS 能顺利跑起来。

**交互式勾选菜单（默认）**：直接 `bash setup.sh` 会弹出模块清单（默认按配置勾选），用**空格**勾选/取消、**Tab** 切换、**回车**确认，只安装你勾选的部分。系统有 `whiptail` 时用图形勾选界面，没有则自动降级为纯文字菜单。

> **终端渲染异常（网页/VNC 控制台出现 `^[[B` 等乱码）**：脚本会自动兜底设置 `TERM`；若仍异常，可强制用纯文字菜单：
> ```bash
> VPS_SETUP_MENU=plain bash setup.sh     # 纯文字菜单：输入序号切换，a 全选，n 全不选，q 确认
> ```

**SSH 公钥用户名**：默认不带任何用户名。交互运行时会提示输入 GitHub 用户名（拉取 `https://github.com/<用户名>.keys`）；**未输入、或用户名拉不到公钥时，自动跳过 SSH 配置**（不改端口、不禁密码），不阻塞其他模块。

日志写入 `/var/log/vps-setup.log`。

## 配置说明

所有开关集中在 [`conf/setup.conf`](conf/setup.conf)：

```bash
# swap 方式：native(自动) 或 script(调用 zhucaidan/swap.sh)
SWAP_METHOD="native"

# SSH：默认不填；交互时提示输入，未输入/拉不到公钥则跳过 SSH 配置
SSH_GITHUB_USER=""
SSH_PORT="2222"

# p10k 配置：默认用内置通用配置；想用自己的就填 URL，或放到 conf/p10k.zsh（已被 gitignore）
P10K_CONFIG_URL=""

# 启用的 zsh 插件（空格分隔）。zsh-* 会自动额外安装；其余为 oh-my-zsh 内置
ZSH_PLUGINS="git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search"
```

> **已启用插件**：`git` + `zsh-autosuggestions`（cd 时灰色路径提示）+ `zsh-syntax-highlighting` + `zsh-history-substring-search`（↑↓模糊搜历史）。想加 `sudo`/`extract`/`systemd`/`docker`/`command-not-found` 等，直接写进 `ZSH_PLUGINS` 即可。

## 安全说明

**默认不执行任何第三方远程脚本**（swap / SSH / BBR 均为自写原生实现），降低被投毒的风险。

> 已对原用的三个第三方脚本做了完整源码审查：
> - swap.sh（zhucaidan）✅ 安全，纯本地操作
> - key.sh（P3TERX 开源项目）✅ 安全，仅拉公钥/改端口/禁密码
> - BBR3（byJoey）⚠️ 脚本代码无木马，但会**下载并安装未审计的自定义内核**，存在供应链风险；故默认改为原生 `sysctl` 方式（内核≥6.8 自带 bbr 即 BBRv3），第三方内核方式需在配置中手动开启。

其他提示：
- **SSH 模块**会改端口并禁用密码登录。运行前请确认：
  - 你的 GitHub 账号的 `https://github.com/<用户名>.keys` 已配置 SSH 公钥；
  - 脚本执行后，**保持当前连接，另开终端用新端口测试成功再断开**。
- 端口 2222 需在系统防火墙（云服务商安全组 / 本机 UFW/firewalld）中自行放行。

## 兼容性

- ✅ Debian / Ubuntu
- ✅ CentOS 7+ / Rocky / Alma / Fedora / Amazon Linux
- ✅ BBR 原生方式：任意内核 ≥4.9 的发行版均可用；仅"第三方内核脚本"方式限 Debian/Ubuntu
- ❌ Alpine 暂不支持

## 常见问题

**Q: 重跑会重复安装吗？**
不会。每个模块都有幂等检查（swap 已有则跳过、cron 已存在则跳过、SSH 端口重复设置不重复追加等）。

**Q: 只装自己需要的？**
`bash setup.sh -m swap,ssh,zsh` 即可。

**Q: 如何新增模块？**
在 `setup.sh` 里加一个函数，并把模块名加入 `FULL_MODULES` 和主流程 `main()` 即可。
