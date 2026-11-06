# Docker и фаервол

> Дата: 2026-11-02
> Проверено на prod-сервере NYX Panel.

## 1. Почему UFW сам по себе не защищает Docker

UFW пишет правила фильтрации входящих соединений в цепочку `INPUT` таблицы `filter`. Туда попадают только пакеты, адресованные самому хосту. Docker меняет схему:

1. Включает `net.ipv4.ip_forward = 1` и поднимает мосты `docker0` / `br-xxxx`.
2. Для проброса портов добавляет DNAT-правила в `nat/PREROUTING`.
3. Пакет снаружи на опубликованный порт попадает в `PREROUTING` → цепочку `DOCKER` → **DNAT**, где адрес назначения на лету меняется с публичного IP на адрес контейнера (`172.x.x.x`).
4. После DNAT пакет уже не «локальный» — он идёт транзитом и уходит в `FORWARD`, а не в `INPUT`.
5. В `FORWARD` Docker ставит `DOCKER-USER` и `DOCKER-FORWARD` **выше** цепочек UFW, поэтому правила UFW до такого пакета не доходят.

Отсюда правило: `ufw status` может выглядеть идеально, а база в контейнере — быть открыта в интернет.

Дополнительные ловушки:

- **IPv6.** С Docker 27 `ip6tables` управляется по умолчанию, DNAT дублируется и в IPv6. Правила, добавленные только в `iptables`, IPv6 не закрывают.
- **`docker-proxy` слушает `[::]`.** Если IPv6 в UFW выключен, пакет по IPv6 может зайти в userspace-сокет `docker-proxy` и оттуда — в IPv4-контейнер.
- **Опасный совет `"iptables": false`.** Docker перестаёт трогать netfilter, но заодно не создаёт `MASQUERADE` — контейнеры теряют выход в интернет, `docker build` падает на `apt-get update`. На рабочих серверах так делать нельзя.

## 2. Как проверить сервер

```bash
# что и куда опубликовано
docker ps --format '{{.Names}}\t{{.Ports}}'
ss -tulpn | grep docker-proxy

# DNAT (что реально проброшено)
iptables -t nat -S DOCKER
ip6tables -t nat -S DOCKER

# защита транзита
iptables -t filter -S DOCKER-USER
ip6tables -t filter -S DOCKER-USER

# проверка с внешней машины
nmap -Pn -T4 --open -p 1-65535 <YOUR_SERVER_IP>
```

Признаки здоровой конфигурации:

- все опубликованные порты имеют вид `127.0.0.1:PORT->PORT`, а не `0.0.0.0:PORT->PORT`;
- в `iptables -t nat -S DOCKER` DNAT стоит только на `127.0.0.1`;
- в `ip6tables -t nat -S DOCKER` либо пусто, либо тоже только loopback;
- `DOCKER-USER` не пуст и содержит `DROP` для новых входящих пакетов с внешнего интерфейса.

Если в `nmap` появились `3306`, `5432`, `6379`, `27017`, `9200` или `2375` — порты нужно немедленно закрывать и проверять контейнеры на компрометацию.

## 3. Предохранитель DOCKER-USER

Чтобы даже случайная публикация порта на `0.0.0.0` не стала доступна снаружи, на сервере стоит идемпотентный предохранитель.

| Путь | Назначение |
| --- | --- |
| `/usr/local/sbin/docker-fw-guard.sh` | скрипт установки правил |
| `/etc/systemd/system/docker-fw-guard.service` | oneshot-юнит, `After=docker.service`, `PartOf=docker.service`, `enabled` |

Скрипт сам определяет внешний интерфейс по `ip route show default`, поэтому не привязан к имени интерфейса жёстко. Правила переустанавливаются после рестарта Docker благодаря `PartOf`.

Содержимое цепочки `DOCKER-USER` (одинаково для IPv4 и IPv6):

```text
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i <PUBLIC_IFACE> -o docker0 -j DROP
-A DOCKER-USER -i <PUBLIC_IFACE> -o br-+ -j DROP
-A DOCKER-USER -j RETURN
```

Почему именно так:

- `RELATED,ESTABLISHED` пропускается первым — контейнеры продолжают ходить в интернет и получать ответы.
- `DROP` ограничен парой `-i <PUBLIC_IFACE> -o br-+` / `-o docker0`, то есть только новыми входящими пакетами с публичного интерфейса **в Docker-мосты**. VPN-маршрутизация не затрагивается.
- Трафик из контейнеров наружу идёт как `-i br-+ -o <PUBLIC_IFACE>` и под правило не попадает.
- Опубликованные на `127.0.0.1` порты обрабатываются через `INPUT`/`docker-proxy` и тоже не затрагиваются.

Если в будущем понадобится открыть контейнер наружу осознанно, правило разрешения нужно ставить **до** `DROP` и матчить оригинальный порт через `--ctorigdstport` (порт до DNAT):

```bash
# пример: разрешить 195.88.54.10 -> контейнерный порт 5432
iptables -I DOCKER-USER 3 -i <PUBLIC_IFACE> -s 195.88.54.10/32 -p tcp \
  -m conntrack --ctorigdstport 5432 -j RETURN
```

Но приоритетный способ — не публиковать порт на `0.0.0.0` вообще: `127.0.0.1:5432:5432`, доступ через SSH-туннель, либо `internal: true` для сети с БД.

## 4. Чек-лист

- [ ] Все порты БД и очередей опубликованы только на `127.0.0.1` или не опубликованы вовсе.
- [ ] DNAT в `iptables`/`ip6tables` не содержит публичных адресов.
- [ ] `DOCKER-USER` не пуст, `DROP` стоит для новых входящих пакетов с внешнего интерфейса.
- [ ] Предохранитель включён: `systemctl is-enabled docker-fw-guard.service`.
- [ ] Внешний `nmap` не показывает портов БД/кэша/`2375`.
- [ ] В `daemon.json` нет `"iptables": false`.

## 5. Что сознательно не менялось

- **`DEFAULT_FORWARD_POLICY` в UFW.** Ужесточение до `DROP` может задеть VPN-маршрутизацию, поэтому без отдельного окна и тестов не трогается. Docker-трафик уже закрыт предохранителем.
- **Нативный nftables backend Docker 29+.** Помечен как experimental; legacy-iptables + `DOCKER-USER` работает и проверен.
- **Внешний фаервол хостера.** Если панель провайдера даёт Cloud Firewall / Security Groups, его стоит включить как первый рубеж — пакеты будут отсекаться ещё до сетевого стека виртуалки.

## 6. FreeBSD: pf, ipfw, ipfilter

> Раздел справочный: прод NYX Panel работает на Debian. Материал — на случай FreeBSD-хостов, jails и смешанной инфраструктуры.

### 6.1 Почему сценарий «Docker + UFW» не воспроизводится

- **Docker Engine нативно на FreeBSD не работает.** `dockerd`, `containerd` и `runc` завязаны на Linux namespaces, cgroups и netfilter. «Docker на FreeBSD» — это либо Linux VM (bhyve), либо Linux-эмуляция, либо podman/ocijail поверх jails.
- **Нет демона, который вставляет свои цепочки выше фаервола.** В Linux `dockerd` сам добавляет `DOCKER-USER`/`DOCKER-FORWARD` в `FORWARD` и DNAT в `nat/PREROUTING` — отсюда обход UFW. На FreeBSD нет ни iptables, ни UFW, ни такого демона.
- **`pf`, `ipfw`, `ipfilter` — единый упорядоченный набор правил в ядре.** Нет «обёртки», которая владеет только частью пути пакета, пока второй демон владеет другой.

### 6.2 Где аналоги всё же есть

**Podman/ocijail + CNI — ближайший аналог.** На FreeBSD 14.3/15 podman (experimental) для `-p 8080:80` использует pf и CNI-плагин `portmap`, который создаёт в pf anchor `cni-rdr/*` правила вида:

```text
rdr pass inet proto tcp from any to <host> port 8080 -> 10.88.0.11 port 80
```

`rdr pass` — это redirect **и** pass одновременно. Если `rdr-anchor "cni-rdr/*"` стоит в `/etc/pf.conf` выше `block`, опубликованный порт может пройти мимо основного ruleset. Официальный sample `pf.conf` эти anchors содержит, но в своём конфиге их легко не заметить.

```bash
pfctl -a 'cni-rdr/*' -sn
```

**vnet-jails.** У vnet-jail свой сетевой стек и свой экземпляр pf; правила хоста внутри не действуют. Сервис в vnet-jail может быть открыт, хотя на хосте «всё закрыто».

**bhyve / VM за bridge(4).** Хостовый фаервол покрывает не всё. Проверять:

```bash
sysctl net.link.bridge.pfil_bridge net.link.bridge.pfil_member
```

По умолчанию мост как отдельный интерфейс не фильтруется (`pfil_bridge=0`), фильтрация идёт по member-интерфейсам (`pfil_member=1`).

**Классические ошибки.** `set skip on <iface>` в pf, `rdr pass` без отдельного фильтра, широкий `pass`, первый match в ipfw, `natd`/divert — тот же эффект «дырка есть, а конфиг выглядит красиво».

### 6.3 Три фаерволла

| Фаервол | Модель | Где ловушка |
| --- | --- | --- |
| **pf** | трансляция (`nat`/`rdr`) до фильтрации; фильтр видит уже транслированные адреса | `rdr pass` в anchor выше `block`; `set skip on`; `block` после anchor |
| **ipfw** | нумерованные правила, first match | порядок до/после `nat`; ранний `allow all` перед `65535 deny`; `natd`/divert и `net.inet.ip.fw.one_pass` |
| **ipfilter** | отдельные списки NAT и filter, NAT обрабатывается раньше | широкий `pass`; порядок `map`/`rdr`/`bimap` |

Нюанс pf: фильтр видит **translated** адрес, поэтому `pass in on egress to port 80` может сработать не так, как ожидается, если `rdr` уже переписал адрес и порт.

### 6.4 Что не зависит от ОС

- **Сканеры.** Диапазоны облаков чешут независимо от ОС; открытый Redis/Postgres на FreeBSD найдут так же быстро.
- **Постэксплуатация.** Слабые пароли, `COPY ... FROM PROGRAM`, Redis `CONFIG SET`/`REPLICAOF`, запись в cron. В FreeBSD другие пути (`/var/cron/tabs`), принцип тот же.
- **Принцип.** Не публиковать БД/кэш наружу: bind на loopback, SSH-туннель, отдельная внутренняя сеть.

### 6.5 Чек-лист аудита FreeBSD

```bash
# слушающие сокеты (аналог ss)
sockstat -4 -6 -l

# pf: фильтр, NAT и ВСЕ anchors
pfctl -sr
pfctl -sn
pfctl -a '*' -sr          # показывает то, чего не видно в pfctl -sr

# ipfw
ipfw list
ipfw nat show config

# ipfilter
ipfstat -io
ipfstat -sn

# jails и bridge
jls
sysctl net.link.bridge.pfil_bridge net.link.bridge.pfil_member

# снаружи
nmap -Pn -T4 --open -p 1-65535 <IP>
```

### 6.6 Итог

FreeBSD не «иммунна» — она устроена иначе. Точной иллюзии «UFW говорит deny, а Docker открыл» там нет, зато есть podman/CNI с `rdr pass` в pf-anchor, vnet-jails и bridge-VM, где хостовый фаервол может не покрывать трафик, и классические ошибки порядка/ширины правил в pf/ipfw/ipfilter.
