# ssh-connect — SSH 主机管理器 + 快捷连接

一条命令管理所有 SSH 主机，配好之后 `sshc <名字>` 直接开终端。自动接 tmux、mosh 弱网友好、Termux 桌面小部件一键连。单文件、免 sudo、幂等可重跑、Linux + Android/Termux 通用。

## 30 秒上手

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lggyx/ssh-connect/main/ssh-connect.sh)
```

菜单打开后：

1. 选 `1` 添加主机（比如你 frp 映射后的电脑：地址、端口、用户、tmux 会话名）
2. 选 `7` install（装命令 + 写 bashrc 托管块）
3. `source ~/.bashrc`，输入 `sshc 主机名` 开连

> 和 pi-install 一样是交互式菜单，所以要用 `bash <(curl …)` 而不是 `curl … | bash`。

## 配好之后

| 命令 | 作用 |
|---|---|
| `sshc pc` | SSH 连接 pc，配了 tmux 会话就自动 `tmux new -As` 接入 |
| `sshm pc` | mosh 连接——弱网、进电梯、WiFi 切流量，会话不断 |
| `sshx pc uptime` | 远程执行一条命令就退出 |
| `scpc pc ./大文件 ~/` | 传文件到 pc（scp -r） |
| `ssht pc` | 测连通性 + 显示握手延迟 ms |
| `sshl` | 列出所有主机 |
| `sshc pc<Tab>` | 主机名补全 |

`sshc`/`sshm`/`sshx`/`scpc`/`ssht` 都支持主机名 Tab 补全。

## 菜单详解

```
1) 添加 / 修改主机            6) 测试连通性
2) 删除主机                   7) 安装命令 + 快捷方式（install）
3) 查看所有主机                8) 生成 Termux 小部件
4) 连接主机（SSH，自动 tmux）   9) 导出 / 导入配置
5) Mosh 连接（弱网友好）        10) 卸载
```

- **`1` 添加/修改**：依次问主机名、登录用户、地址、端口、私钥路径、附加 ssh 选项、tmux 会话名。填已存在的名字 = 覆盖修改。**tmux 会话名是关键项**：填了，每次连接自动接入同一个 tmux 会话（断线重连回去接着干）；回车不填就是普通 shell
- **`4`/`5` 连接**：直接选主机连；`5` 走 mosh，弱网环境用
- **`6` 测试**：`BatchMode` 静默握手，输出延迟毫秒数，排查"连不上"第一步
- **`7` install**：脚本拷到 `~/.local/bin/ssh-connect`，bashrc 写托管块，生成 `~/.ssh/config` 的 Host 块和 `commands.sh`。幂等，重复跑=更新
- **`8` 小部件**：生成 `~/.shortcuts/sshc-<名字>.sh`，桌面加 Termux:Widget 小部件，点一下直接开终端
- **`9` 导出/导入**：导出成 TSV，换手机/换电脑 `import` 即恢复
- **`10` 卸载**：删托管块前自动留 `.ssh-connect.bak`；默认保留主机配置，`--purge` 才真删

## 数据放在哪

全部本地，**不进仓库**：

```
~/.ssh-connect/hosts.tsv      主机列表（chmod 600）
~/.ssh-connect/commands.sh    快捷命令函数 + 补全
~/.ssh/config                 生成 Host 块（# >>> ssh-connect >>> 标记之间）
~/.local/bin/ssh-connect      命令本体
~/.shortcuts/sshc-<名字>.sh   Termux:Widget 小部件
```

`hosts.tsv` 每行一个主机，Tab 分隔 7 列：

```
名字	用户	地址	端口	私钥	附加选项	tmux
pc	bob	frps.example.com	22222	~/.ssh/id_ed25519	ProxyJump=bastion	main
```

- **附加选项**：`Key=Value;Key=Value`，会同时写进 `~/.ssh/config` 和命令行 `-o`。常用 `ServerAliveInterval=30;ServerAliveCountMax=3`（保活，防 NAT 掐断）
- **私钥**：空 = 用 ssh 默认密钥
- 托管块之外的内容它一概不碰，卸载只删标记之间的部分

## 非交互用法（脚本里调用）

```bash
ssh-connect add pc          # 交互式添加
ssh-connect ls              # 列表
ssh-connect c pc            # 连接
ssh-connect m pc            # mosh
ssh-connect x pc "df -h"    # 远程命令
ssh-connect p pc ./a ~/a    # 传文件
ssh-connect t pc            # 测连通
ssh-connect widget pc       # 生成小部件
ssh-connect sync            # 改了 hosts.tsv 后重新生成
ssh-connect export pc.tsv   # 导出
ssh-connect import pc.tsv   # 导入
ssh-connect path            # 数据目录
SSH_CONNECT_DRYRUN=1 ssh-connect c pc   # 只打印命令不执行（调试用）
```

## 弱网三件套

手机连电脑，网络说断就断。三层防护：

1. **tmux**（必配）：连接时自动 `tmux new -As <会话名>`，断了重连回到原来的会话，跑着的命令不丢
2. **mosh**：`sshm pc`，UDP 传输，IP 变了自动重连（roaming），本地回显不受网络影响。注意 frp 那边除了 TCP 端口，还要映射一段 UDP（mosh 默认 60000-61000）
3. **保活**：附加选项加 `ServerAliveInterval=30;ServerAliveCountMax=3`，防 NAT 空闲掐断

传大文件别用 scp（断了从头来），在 pc 上开个 tmux 会话用 rsync `--partial` 断点续传。

## 安全

- `hosts.tsv` 权限 600，只存主机信息不存密钥
- **不要把 hosts.tsv 提交到公开仓库**——地址+端口+用户名也是信息暴露。换设备同步用 `export` 到加密渠道或私有仓库
- 建议电脑端 sshd 关掉密码登录（`PasswordAuthentication no`），只用密钥；22 端口改掉或只放通 frp 映射端口

## 卸载

```bash
ssh-connect uninstall          # 删命令和托管块，保留主机配置
ssh-connect uninstall --purge  # 连配置一起删
```

## License

MIT
