# homeproxy-dscp

Update-safe DSCP routing addon for HomeProxy on OpenWrt/ImmortalWrt.

## Official HomeProxy dependency

This addon requires the official ImmortalWrt HomeProxy package:

- Source code: [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy)
- ImmortalWrt package feed, 24.10 aarch64_cortex-a53: [luci packages](https://downloads.immortalwrt.org/releases/packages-24.10/aarch64_cortex-a53/luci/)
- ImmortalWrt release packages, 24.10.4 root: [release package index](https://downloads.immortalwrt.org/releases/24.10.4/)

Install dependency on the router:

```sh
opkg update
opkg install luci-app-homeproxy
```

## Local IPv4 bypass

By default the addon does not proxy local destination IPv4 addresses. The generated nftables table creates a `bypass4`
set and returns before TCP redirect / UDP TProxy for:

- private and reserved IPv4 ranges, for example `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`;
- IPv4 subnets detected from `/etc/config/network`, including non-RFC1918 local LANs;
- extra IPv4/CIDR entries configured in LuCI, including explicit WAN IPv4/CIDR exclusions.

This keeps router/LAN access working even when the Windows application is DSCP-marked.

Languages: [Русский](#русский) | [English](#english) | [中文](#中文)

---

## Русский

`homeproxy-dscp` нужен, когда HomeProxy/sing-box работает на роутере, а
маршрутизировать нужно трафик **конкретного процесса Windows**.

Роутер не видит имя процесса Windows (`msedge.exe`, `game.exe`, `telegram.exe`),
поэтому поля `process_name` в HomeProxy на роутере для этого не подходят. Этот
addon решает задачу через штатный Windows Policy-based QoS:

1. Windows помечает трафик выбранного приложения DSCP-меткой, обычно `46`.
2. OpenWrt ловит такие TCP/UDP пакеты через nftables.
3. TCP идет в `redirect`, UDP идет в `TProxy`.
4. Отдельный маленький `sing-box` instance отправляет этот трафик в выбранный
   HomeProxy routing node.

Обычный HomeProxy продолжает работать как раньше. Файлы `luci-app-homeproxy`
не изменяются, поэтому обновления HomeProxy не должны затирать addon.

### Когда использовать

Используйте addon, если нужно:

- проксировать только отдельные Windows-приложения через конкретную ноду;
- сохранить основной HomeProxy в режиме TUN/mixed;
- поддерживать и TCP, и UDP;
- не ставить полноценный proxy-клиент на Windows;
- не патчить HomeProxy напрямую.

Не используйте addon, если достаточно маршрутизации по доменам/IP/портам или
если весь Windows-хост должен идти через одну ноду. Это можно сделать штатными
правилами HomeProxy.

### Схема

```text
Windows App.exe
  -> Windows QoS ставит DSCP 46
  -> OpenWrt nftables match: source IPv4 + DSCP + TCP/UDP
  -> TCP redirect / UDP TProxy
  -> homeproxy-dscp sing-box
  -> выбранный HomeProxy routing node
```

### Установка

Из папки проекта на Windows:

```powershell
.\scripts\install-router.ps1 -Router 192.168.1.1 -User root
```

### Ручная установка на роутере

Скопируйте `homeproxy-dscp.tar.gz` на роутер любым удобным способом, например
через WinSCP, FileBrowser или `scp -O`.

На роутере:

```sh
opkg update
opkg install firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci luci-app-homeproxy
tar -xzf /tmp/homeproxy-dscp.tar.gz -C /
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Если архив опубликован в GitHub Releases, можно установить прямо с роутера:

```sh
cd /tmp
wget -O homeproxy-dscp.tar.gz 'https://github.com/LuckerCracker/homeproxy-dscp/releases/latest/download/homeproxy-dscp.tar.gz'
tar -xzf homeproxy-dscp.tar.gz -C /
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Для первой установки на чистом роутере:

```powershell
.\scripts\install-router.ps1 -Router 192.168.1.1 -User root -InstallDeps
```

Страница LuCI:

```text
Services -> HomeProxy DSCP
```

Если страница не обновилась, нажмите `Ctrl+F5` или перезапустите LuCI:

```sh
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### Добавление Windows-приложения

PowerShell нужно запускать от администратора.

Запустите интерактивный manager и вводите параметры в меню:

```powershell
.\scripts\dscp-app-manager.ps1
```

В меню можно:

- посмотреть приложения с DSCP policy;
- добавить или обновить приложение;
- удалить Windows QoS policy;
- вывести команды проверки.

Если запустить manager без `-Router`, он настроит только Windows и выведет
параметры, которые нужно вручную вставить в LuCI.

### Проверка

На роутере:

```sh
nft list table inet homeproxy_dscp
```

Должны расти счетчики:

```text
tcp counter packets ...
udp counter packets ...
```

Проверить DSCP от Windows:

```sh
tcpdump -i br-lan -vv host 192.168.1.248
```

Ищите `tos 0xb8` или `DSCP EF`.

Логи:

```text
Services -> HomeProxy DSCP -> Service Status
```

или:

```sh
tail -f /var/run/homeproxy-dscp/sing-box.log
```

На уровне `Warning` лог может быть пустым, если все работает нормально.

### Откат

```sh
/etc/init.d/homeproxy-dscp stop
/etc/init.d/homeproxy-dscp disable
uci set homeproxy_dscp.main.enabled='0'
uci commit homeproxy_dscp
```

---

## English

`homeproxy-dscp` is useful when HomeProxy/sing-box runs on the router, but you
need to route traffic from a **specific Windows process**.

The router cannot see Windows process names such as `msedge.exe`, `game.exe` or
`telegram.exe`, so HomeProxy `process_name` rules on the router cannot solve
this case. This addon uses standard Windows Policy-based QoS instead:

1. Windows marks selected application traffic with a DSCP value, usually `46`.
2. OpenWrt matches those TCP/UDP packets with nftables.
3. TCP is redirected, UDP is handled with TProxy.
4. A separate small `sing-box` instance routes the traffic to a selected
   HomeProxy routing node.

The main HomeProxy service continues to work normally. `luci-app-homeproxy`
files are not modified, so HomeProxy upgrades should not overwrite this addon.

### When To Use It

Use this addon if you need to:

- proxy only selected Windows applications through a specific node;
- keep the main HomeProxy TUN/mixed setup;
- support both TCP and UDP;
- avoid running a full proxy client on Windows;
- avoid patching HomeProxy directly.

Do not use it if domain/IP/port routing is enough, or if the entire Windows
host should use one node. HomeProxy can already handle those cases directly.

### Flow

```text
Windows App.exe
  -> Windows QoS sets DSCP 46
  -> OpenWrt nftables matches source IPv4 + DSCP + TCP/UDP
  -> TCP redirect / UDP TProxy
  -> homeproxy-dscp sing-box
  -> selected HomeProxy routing node
```

### Install

From the project directory on Windows:

```powershell
.\scripts\install-router.ps1 -Router 192.168.1.1 -User root
```

### Manual Router Install

Copy `homeproxy-dscp.tar.gz` to the router using any method, for example
WinSCP, FileBrowser or `scp -O`.

On the router:

```sh
opkg update
opkg install firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci luci-app-homeproxy
tar -xzf /tmp/homeproxy-dscp.tar.gz -C /
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

If the archive is published in GitHub Releases, install directly on the router:

```sh
cd /tmp
wget -O homeproxy-dscp.tar.gz 'https://github.com/LuckerCracker/homeproxy-dscp/releases/latest/download/homeproxy-dscp.tar.gz'
tar -xzf homeproxy-dscp.tar.gz -C /
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

For a clean first install:

```powershell
.\scripts\install-router.ps1 -Router 192.168.1.1 -User root -InstallDeps
```

LuCI page:

```text
Services -> HomeProxy DSCP
```

If the page does not refresh, press `Ctrl+F5` or restart LuCI:

```sh
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### Add A Windows Application

Run PowerShell as Administrator.

Start the interactive manager and enter values in the menu:

```powershell
.\scripts\dscp-app-manager.ps1
```

The menu can:

- list DSCP applications;
- add or update an application;
- remove a Windows QoS policy;
- show verification commands.

If `-Router` is omitted, the manager only configures Windows and prints the
values to enter manually in LuCI.

### Verify

On the router:

```sh
nft list table inet homeproxy_dscp
```

Counters should increase:

```text
tcp counter packets ...
udp counter packets ...
```

Check DSCP packets from Windows:

```sh
tcpdump -i br-lan -vv host 192.168.1.248
```

Look for `tos 0xb8` or `DSCP EF`.

Logs:

```text
Services -> HomeProxy DSCP -> Service Status
```

or:

```sh
tail -f /var/run/homeproxy-dscp/sing-box.log
```

At `Warning` level, the log can remain empty when everything is working.

### Rollback

```sh
/etc/init.d/homeproxy-dscp stop
/etc/init.d/homeproxy-dscp disable
uci set homeproxy_dscp.main.enabled='0'
uci commit homeproxy_dscp
```

---

## 中文

`homeproxy-dscp` 适用于这种场景：HomeProxy/sing-box 运行在路由器上，但你想按
**Windows 上的某个进程** 来选择代理节点。

路由器看不到 Windows 进程名，比如 `msedge.exe`、`game.exe`、`telegram.exe`。
因此，在路由器上的 HomeProxy `process_name` 规则不能解决这个问题。本插件使用
Windows 自带的 Policy-based QoS：

1. Windows 给指定应用的流量打上 DSCP 标记，通常使用 `46`。
2. OpenWrt 使用 nftables 匹配这些 TCP/UDP 数据包。
3. TCP 使用 redirect，UDP 使用 TProxy。
4. 一个独立的小型 `sing-box` 实例把流量转发到指定的 HomeProxy routing node。

主 HomeProxy 服务保持原样运行。本插件不修改 `luci-app-homeproxy` 文件，因此更新
HomeProxy 时不应该覆盖本插件。

### 适用场景

适合：

- 只让某些 Windows 应用走指定代理节点；
- 保留 HomeProxy 的 TUN/mixed 模式；
- 同时支持 TCP 和 UDP；
- 不想在 Windows 上运行完整代理客户端；
- 不想直接修改 HomeProxy。

如果只需要按域名、IP、端口分流，或者整台 Windows 主机都走同一个节点，直接使用
HomeProxy 自带规则即可。

### 工作流程

```text
Windows App.exe
  -> Windows QoS 设置 DSCP 46
  -> OpenWrt nftables 匹配 source IPv4 + DSCP + TCP/UDP
  -> TCP redirect / UDP TProxy
  -> homeproxy-dscp sing-box
  -> 指定 HomeProxy routing node
```

### 安装

在 Windows 的项目目录中运行：

```powershell
.\scripts\install-router.ps1 -Router 192.168.1.1 -User root
```

### 在路由器上手动安装

使用任意方式把 `homeproxy-dscp.tar.gz` 复制到路由器，例如 WinSCP、
FileBrowser 或 `scp -O`。

在路由器上运行：

```sh
opkg update
opkg install firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci luci-app-homeproxy
tar -xzf /tmp/homeproxy-dscp.tar.gz -C /
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

如果压缩包发布在 GitHub Releases，可以直接在路由器上安装：

```sh
cd /tmp
wget -O homeproxy-dscp.tar.gz 'https://github.com/LuckerCracker/homeproxy-dscp/releases/latest/download/homeproxy-dscp.tar.gz'
tar -xzf homeproxy-dscp.tar.gz -C /
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

首次在干净系统安装依赖：

```powershell
.\scripts\install-router.ps1 -Router 192.168.1.1 -User root -InstallDeps
```

LuCI 页面：

```text
Services -> HomeProxy DSCP
```

如果页面没有刷新，请按 `Ctrl+F5`，或重启 LuCI：

```sh
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### 添加 Windows 应用

请以管理员身份运行 PowerShell。

启动交互式管理器，并在菜单中输入参数：

```powershell
.\scripts\dscp-app-manager.ps1
```

菜单可以：

- 查看 DSCP 应用；
- 添加或更新应用；
- 删除 Windows QoS policy；
- 显示验证命令。

如果不指定 `-Router`，管理器只配置 Windows，并输出需要手动填入 LuCI 的参数。

### 验证

在路由器上：

```sh
nft list table inet homeproxy_dscp
```

计数器应该增加：

```text
tcp counter packets ...
udp counter packets ...
```

检查 Windows 发出的 DSCP 包：

```sh
tcpdump -i br-lan -vv host 192.168.1.248
```

查找 `tos 0xb8` 或 `DSCP EF`。

日志位置：

```text
Services -> HomeProxy DSCP -> Service Status
```

或：

```sh
tail -f /var/run/homeproxy-dscp/sing-box.log
```

日志级别为 `Warning` 时，如果一切正常，日志可能为空。

### 回滚

```sh
/etc/init.d/homeproxy-dscp stop
/etc/init.d/homeproxy-dscp disable
uci set homeproxy_dscp.main.enabled='0'
uci commit homeproxy_dscp
```
