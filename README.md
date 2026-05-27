# homeproxy-dscp

Update-safe DSCP routing addon for HomeProxy on OpenWrt/ImmortalWrt.

## Official HomeProxy dependency

This addon requires the official ImmortalWrt HomeProxy package:

- Source code: [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy)
- ImmortalWrt package feed, 24.10 aarch64_cortex-a53: [luci packages](https://downloads.immortalwrt.org/releases/packages-24.10/aarch64_cortex-a53/luci/)
- ImmortalWrt release packages, 24.10.4 root: [release package index](https://downloads.immortalwrt.org/releases/24.10.4/)

On stock OpenWrt, `luci-app-homeproxy` is not part of the official OpenWrt package feeds. Install HomeProxy separately
from the HomeProxy/ImmortalWrt package source first, then install this addon.

If you use stock OpenWrt with ImmortalWrt package feeds added manually, `opkg install luci-app-homeproxy` may work too.
Use feeds that match your OpenWrt release, target and ABI as closely as possible. Mixing package feeds can upgrade shared
packages such as `sing-box`, `ucode` or LuCI components, so keep a backup before installing.

Install HomeProxy on ImmortalWrt or on a router with a HomeProxy package feed:

```sh
opkg update
opkg install luci-app-homeproxy
```

For stock OpenWrt, install HomeProxy separately first. Then install only the generic dependencies listed below.

## Local IPv4 bypass

By default the addon does not proxy local destination IPv4 addresses. The generated nftables table creates a `bypass4`
set and adds `ip daddr != @bypass4` to every TCP redirect / UDP TProxy rule for:

- private and reserved IPv4 ranges, for example `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`;
- IPv4 subnets detected from `/etc/config/network`, including non-RFC1918 local LANs;
- extra IPv4/CIDR entries configured in LuCI, including explicit WAN IPv4/CIDR exclusions.

This keeps router/LAN access working even when the Windows application is DSCP-marked.

The match is strict: a packet is proxied only when an enabled router rule matches the Windows source IPv4, DSCP value,
protocol and non-bypassed destination. If Windows marks an application with DSCP `46`, but the router only has a rule for
DSCP `47`, that traffic is not proxied by this addon.

For UDP games and QUIC traffic, UDP sniffing is disabled by default. TCP can still use sniffing, but UDP/QUIC should
usually keep the original destination unchanged.

The UDP TProxy hook runs after HomeProxy's mangle hook by default (`mangle + 1`, numeric priority `-149`). This is
intentional: HomeProxy may mark LAN traffic for its own TUN path at priority `mangle`, and the DSCP addon must set its
own UDP fwmark after that.

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

### Строгое совпадение DSCP

Роутер не знает имя Windows-процесса. Он проксирует пакет только если есть
включенное правило с тем же `Windows source IPv4`, `DSCP value`, протоколом и
destination не входит в bypass. Если Windows помечает приложение DSCP `46`, а
на роутере есть только правило для DSCP `47`, этот трафик не будет
перехвачен addon.

В PowerShell manager есть пункт `Check Windows/router matches`: он показывает,
для каких Windows QoS policies найдено соответствующее правило на роутере.

### UDP и QUIC

Для игр и QUIC важно не менять original destination UDP-пакета. Поэтому addon
по умолчанию использует `Sniff TCP traffic = enabled`, но
`Sniff UDP/QUIC traffic = disabled`. Если включить UDP sniff/override, sing-box
может заменить IP назначения на sniffed domain, и некоторые QUIC-игры перестают
нормально работать.

Для игровых правил обычно оставляйте:

```text
Sniff TCP traffic: enabled
Sniff UDP/QUIC traffic: disabled
UDP compatibility mode: enabled
UDP nft hook priority: -149
```

`UDP nft hook priority` по умолчанию стоит после HomeProxy mangle hook. Это
нужно, чтобы HomeProxy не перезаписывал UDP fwmark addon своим mark для TUN.

### Установка

На обычном OpenWrt пакет `luci-app-homeproxy` обычно отсутствует в официальных feeds OpenWrt. Если вы добавили feeds от
ImmortalWrt вручную, установка `opkg install luci-app-homeproxy` может работать, но это смешивание feeds. Используйте
feeds, максимально совпадающие с вашей версией OpenWrt, target и ABI, и сделайте backup перед установкой.

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
opkg install firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci
tar -xzf /tmp/homeproxy-dscp.tar.gz -C /
sed -i 's/\r$//' /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Если архив опубликован в GitHub Releases, можно установить прямо с роутера:

```sh
cd /tmp
wget -O homeproxy-dscp.tar.gz 'https://github.com/LuckerCracker/homeproxy-dscp/releases/latest/download/homeproxy-dscp.tar.gz'
tar -xzf homeproxy-dscp.tar.gz -C /
sed -i 's/\r$//' /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
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

Если кнопки сервиса в LuCI пишут `Object not found`, проверьте RPC backend:

```sh
ls -l /usr/libexec/rpcd/homeproxy-dscp
head -1 /usr/libexec/rpcd/homeproxy-dscp | od -An -tx1
/usr/libexec/rpcd/homeproxy-dscp list
/etc/init.d/rpcd restart
ubus -S list homeproxy-dscp
logread -e rpcd
```

Первая строка через `od` должна начинаться с `23 21 2f 62 69 6e 2f 73 68 0a`, без `0d` перед `0a`.

### Добавление Windows-приложения

PowerShell нужно запускать от администратора.

Запустите интерактивный manager и вводите параметры в меню:

```powershell
.\scripts\dscp-app-manager.ps1
```

При запуске без параметров manager предложит выбрать режим:

- `Router sync`: создать Windows QoS policy и сразу обновить правило на роутере;
- `Windows-only`: создать только Windows QoS policy и вывести значения, которые
  нужно вручную вставить в LuCI.

Чтобы сразу открыть Windows-only режим:

```powershell
.\scripts\dscp-app-manager.ps1 -WindowsOnly
```

В меню можно:

- посмотреть приложения с DSCP policy;
- добавить или обновить приложение;
- удалить Windows QoS policy;
- проверить совпадение Windows policies с router rules;
- вывести значения для ручного правила LuCI в Windows-only режиме;
- вывести команды проверки.

Если запустить manager без `-Router`, он настроит только Windows и выведет
параметры, которые нужно вручную вставить в LuCI.

По умолчанию manager сохраняет Windows QoS policies в persistent local computer
store (`$env:COMPUTERNAME`). Проверяйте их через PowerShell:

```powershell
Get-NetQosPolicy -PolicyStore $env:COMPUTERNAME
Get-NetQosPolicy -PolicyStore ActiveStore
```

`gpedit.msc` может не показывать все правила, созданные PowerShell/WMI, или
показывать ошибку чтения GPO. Для этого проекта используйте PowerShell manager
как основной интерфейс Windows-правил.

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

### Strict DSCP Matching

The router does not know the Windows process name. A packet is proxied only
when an enabled rule matches the same `Windows source IPv4`, `DSCP value`,
protocol and a destination outside the bypass set. If Windows marks an
application with DSCP `46`, but the router only has a rule for DSCP `47`, this
traffic is not captured by the addon.

The PowerShell manager includes `Check Windows/router matches`, which shows
which Windows QoS policies have a matching router rule.

### UDP And QUIC

Games and QUIC traffic are sensitive to original UDP destination handling.
For that reason, the addon uses `Sniff TCP traffic = enabled`, but
`Sniff UDP/QUIC traffic = disabled` by default. If UDP sniff/override is
enabled, sing-box may replace the destination IP with a sniffed domain, and
some QUIC games may stop working correctly.

For game rules, usually keep:

```text
Sniff TCP traffic: enabled
Sniff UDP/QUIC traffic: disabled
UDP compatibility mode: enabled
UDP nft hook priority: -149
```

`UDP nft hook priority` intentionally runs after the HomeProxy mangle hook, so
HomeProxy cannot overwrite the addon's UDP fwmark with its own TUN mark.

### Install

On stock OpenWrt, `luci-app-homeproxy` is usually unavailable in official OpenWrt feeds. If you manually added
ImmortalWrt feeds, `opkg install luci-app-homeproxy` may work, but this mixes package feeds. Use feeds matching your
OpenWrt release, target and ABI as closely as possible, and make a backup first.

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
opkg install firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci
tar -xzf /tmp/homeproxy-dscp.tar.gz -C /
sed -i 's/\r$//' /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

If the archive is published in GitHub Releases, install directly on the router:

```sh
cd /tmp
wget -O homeproxy-dscp.tar.gz 'https://github.com/LuckerCracker/homeproxy-dscp/releases/latest/download/homeproxy-dscp.tar.gz'
tar -xzf homeproxy-dscp.tar.gz -C /
sed -i 's/\r$//' /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
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

When started without parameters, the manager asks which mode to use:

- `Router sync`: create the Windows QoS policy and update the router rule;
- `Windows-only`: create only the Windows QoS policy and print the values to
  enter manually in LuCI.

To start directly in Windows-only mode:

```powershell
.\scripts\dscp-app-manager.ps1 -WindowsOnly
```

The menu can:

- list DSCP applications;
- add or update an application;
- remove a Windows QoS policy;
- check Windows policies against router rules;
- print manual LuCI rule values in Windows-only mode;
- show verification commands.

If `-Router` is omitted, the manager only configures Windows and prints the
values to enter manually in LuCI.

By default, the manager stores Windows QoS policies in the persistent local
computer store (`$env:COMPUTERNAME`). Check them with PowerShell:

```powershell
Get-NetQosPolicy -PolicyStore $env:COMPUTERNAME
Get-NetQosPolicy -PolicyStore ActiveStore
```

`gpedit.msc` may not display every policy created through PowerShell/WMI, or may
show a GPO read warning. For this project, use the PowerShell manager as the
main Windows policy UI.

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

### 严格 DSCP 匹配

路由器不知道 Windows 进程名。只有当启用的规则同时匹配 `Windows source
IPv4`、`DSCP value`、协议，并且目标地址不在 bypass 集合中时，数据包才会被代理。
如果 Windows 给应用设置的是 DSCP `46`，但路由器上只有 DSCP `47` 的规则，这些流量
不会被本插件捕获。

PowerShell 管理器中有 `Check Windows/router matches` 菜单项，可显示哪些 Windows
QoS policies 在路由器上有对应规则。

### UDP 和 QUIC

游戏和 QUIC 流量通常需要保持 UDP 原始目标地址不变。因此本插件默认启用
`Sniff TCP traffic`，但禁用 `Sniff UDP/QUIC traffic`。如果启用 UDP sniff/override，
sing-box 可能会把目标 IP 替换为 sniff 到的域名，某些 QUIC 游戏会因此无法正常工作。

游戏规则通常建议保持：

```text
Sniff TCP traffic: enabled
Sniff UDP/QUIC traffic: disabled
UDP compatibility mode: enabled
UDP nft hook priority: -149
```

`UDP nft hook priority` 默认在 HomeProxy mangle hook 之后运行，这样 HomeProxy
不会把插件设置的 UDP fwmark 覆盖成自己的 TUN mark。

### 安装

在原版 OpenWrt 上，`luci-app-homeproxy` 通常不在官方 OpenWrt feeds 中。如果你手动添加了 ImmortalWrt feeds，
`opkg install luci-app-homeproxy` 也可能可用，但这属于混用 feeds。请尽量使用与 OpenWrt 版本、target 和 ABI 匹配的
feeds，并在安装前备份配置。

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
opkg install firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci
tar -xzf /tmp/homeproxy-dscp.tar.gz -C /
sed -i 's/\r$//' /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

如果压缩包发布在 GitHub Releases，可以直接在路由器上安装：

```sh
cd /tmp
wget -O homeproxy-dscp.tar.gz 'https://github.com/LuckerCracker/homeproxy-dscp/releases/latest/download/homeproxy-dscp.tar.gz'
tar -xzf homeproxy-dscp.tar.gz -C /
sed -i 's/\r$//' /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
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

不带参数启动时，管理器会询问使用哪种模式：

- `Router sync`：创建 Windows QoS policy，并自动更新路由器规则；
- `Windows-only`：只创建 Windows QoS policy，并输出需要手动填入 LuCI 的值。

也可以直接进入 Windows-only 模式：

```powershell
.\scripts\dscp-app-manager.ps1 -WindowsOnly
```

菜单可以：

- 查看 DSCP 应用；
- 添加或更新应用；
- 删除 Windows QoS policy；
- 检查 Windows policies 与路由器规则是否匹配；
- 在 Windows-only 模式下输出手动 LuCI 规则参数；
- 显示验证命令。

如果不指定 `-Router`，管理器只配置 Windows，并输出需要手动填入 LuCI 的参数。

默认情况下，管理器会把 Windows QoS policies 保存到持久化的本地计算机 store
（`$env:COMPUTERNAME`）。可以用 PowerShell 检查：

```powershell
Get-NetQosPolicy -PolicyStore $env:COMPUTERNAME
Get-NetQosPolicy -PolicyStore ActiveStore
```

`gpedit.msc` 可能无法显示所有通过 PowerShell/WMI 创建的规则，或者显示 GPO 读取警告。
本项目建议使用 PowerShell manager 作为 Windows 规则的主要管理界面。

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
