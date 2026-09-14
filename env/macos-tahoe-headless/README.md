# macOS Tahoe Headless

Отдельная, независимая от остального репозитория Terraform-среда: macOS Tahoe
26.2 (или последняя стабильная Tahoe на момент установки) как
**headless-хакинтош-VM** на ноде `pve-rog` — другой ноде кластера, чем
`bare-pve`.

**Не имеет отношения к `env/windows` / `env/ubuntu` / `mod/vm` / `mod/ct` /
`scripts/gpu-arbiter.sh`.** Никакого GPU passthrough, никакого разделяемого
железа, никакого арбитра — этот VM не участвует в GPU-мьютексе `bare-pve`
вообще, потому что на `pve-rog` нет физического GPU (интегрированной Iris Pro
5200 хватает на std VGA framebuffer, которого достаточно для CLI/SSH и
изредка VNC/Screen Sharing; никакого Metal/GPU-acceleration нет и не будет).

Назначение — **backend для сборок под свежий Xcode** (CLI/SSH), не десктоп.

## Содержание

- [Стек](#стек)
- [Архитектура](#архитектура)
- [Структура](#структура)
- [Требования](#требования)
- [Переменные](#переменные)
- [Установка macOS Tahoe с нуля](#установка-macos-tahoe-с-нуля)
- [Что реально сработало](#что-реально-сработало)
- [Доступ](#доступ)
- [Известные ограничения](#известные-ограничения)
- [Источники](#источники)

## Стек

```
Нода:             pve-rog (Proxmox VE 9.2.2)
CPU ноды:         Intel i7-4700HQ, 8 потоков (Haswell, AVX2)
RAM ноды:         23.38 GiB всего, ~4 GiB занято другими гостями
Диск ноды:        thin-pool 337.9G (LVM-thin), ~30G занято другими VM/CT
Terraform:        >= 1.16.1
Provider:         bpg/proxmox >= 0.112.0 (нужен kvm_arguments)
State backend:    S3-совместимое (MinIO), тот же бакет, отдельный ключ
Guest:            macOS Tahoe 26.x, OpenCore bootloader, без GPU-driver
```

## Архитектура

Новый модуль **`mod/vm-headless`** — сознательно НЕ `mod/vm` с опциональным
passthrough. `mod/vm` целиком построен вокруг
`proxmox_hardware_mapping_pci` / `hostpci` для *whole-workstation*
GPU-передачи одному из двух взаимоисключающих гостей на `bare-pve`; здесь
этой темы нет вообще, а нужный набор атрибутов (`kvm_arguments`, `vga`,
второй опциональный `disk` для install-media) — свой.
Смешивать это в один модуль с флагом-переключателем усложнило бы оба случая
ради несуществующей переиспользуемости — GPU-workstation и headless-VM без
GPU не разделяют почти ничего в конфигурации ресурса, кроме `machine`/`bios`.

Ключевое отличие от `env/windows`: OpenCore, а не встроенный в Proxmox
Windows-путь. OpenCore — это и есть загрузчик (attach'ится как `cdrom` **на
каждый** boot, не только на установку) + отдельный опциональный `disk` для
recovery/BaseSystem media на время установки (импортируется один раз при
create, не live-mount — см. `mod/vm-headless/variables.tf`).

Никакого `hardware_mapping_pci`, никакого `hostpci`, никакого `usb`-passthrough
блока — Terraform-ресурс здесь строго проще, чем в `mod/vm`.

## Структура

```
env/macos-tahoe-headless/
├── backend.tf        # S3 (MinIO), ключ macos-tahoe-headless/terraform.tfstate
├── main.tf            # вызов mod/vm-headless
├── providers.tf        # провайдер: API token, endpoint pve-rog
├── variables.tf
└── README.md           # этот файл
mod/vm-headless/
├── main.tf             # ресурс: VM, без passthrough
├── outputs.tf
├── variables.tf
└── versions.tf
```

## Требования

- Terraform >= 1.16.1
- Доступ к Proxmox VE API по токену (тот же `terraform@pve`, что и у
  остальных env — правами на `pve-rog` управляет тот же ACL/роль)
- HashiCorp Vault + `scripts/apply-wrapper.sh` (см. корневой README —
  переиспользуются как есть, ничего нового не заводилось)
- S3-совместимое хранилище для state (MinIO, тот же инстанс)
- На `pve-rog`: storage с включённым content-type `iso` (обычно уже есть,
  `local`) **и** `import` (новее, может потребоваться
  `pvesm set local --content iso,vztmpl,backup,import` — без него
  `import_from` для recovery-диска откажет)
- Собранный и загруженный на ноду OpenCore ISO — см.
  [Установка macOS Tahoe с нуля](#установка-macos-tahoe-с-нуля). Terraform
  его не собирает и не хранит в себе — это ручной, итеративный артефакт.

## Переменные

### `env/macos-tahoe-headless`

| Переменная                | Тип         | По умолчанию                | Описание                                    |
|----------------------------|-------------|-------------------------------|-----------------------------------------------|
| `proxmox_node`              | string      | `pve-rog`                      | Целевая нода                                   |
| `proxmox_endpoints`         | map(string) | —                              | Карта `нода → endpoint API`                    |
| `proxmox_insecure`          | bool        | `true`                         | Пропускать проверку TLS                        |
| `proxmox_api_token`         | string      | — (sensitive)                  | API-токен `terraform@pve`                      |
| `vm_name`                   | string      | `macos-tahoe-headless`         | Имя VM                                         |
| `cores`                     | number      | `2`                             | Ядра **на сокет** — не путать с общим числом (см. ниже) |
| `sockets`                   | number      | `3`                             | 2×3 = 6 vCPU. macOS хочет степень двойки на сокет, не любое число ядер плашмя — см. `mod/vm-headless.cores` |
| `memory`                    | number      | `16288`                        | RAM, МиБ (hard reservation, без balloon)       |
| `disk_size`                 | number      | `100`                          | Главный диск macOS, ГиБ (thin-provisioned)     |
| `opencore_iso_file_id`      | string      | — (обязательна)                | Volume ID загруженного OpenCore ISO            |
| `installer_image_file_id`   | string      | `null`                          | Volume ID recovery/BaseSystem-образа (install) |
| `mac`                       | string      | `BC:24:11:7A:04:0E`             | MAC (отличается от windows/ubuntu)             |
| `network_model`              | string      | `virtio`                        | Актуальная рекомендация LongQT-sea для macOS 11-26 (не `vmxnet3`) |

### `mod/vm-headless`

| Переменная                 | Тип     | По умолчанию | Описание                                                        |
|-------------------------------|---------|---------------|------------------------------------------------------------------|
| `name` / `node_name`           | string  | —             | Имя VM / нода                                                     |
| `cores`                         | number  | `1`           | Ядра **на сокет** — держать степень двойки (1/2/4/8…), остальное добирать `sockets` |
| `sockets`                       | number  | `1`           | Общее число vCPU = `cores * sockets`                               |
| `memory`                        | number  | `512`         | RAM, МиБ. Нет `floating` — balloon-устройство не поднимается вовсе |
| `cpu_type`                      | string  | `host`        | Косметический — реальный `-cpu` идёт через `kvm_arguments`         |
| `agent_enabled`                 | bool    | `false`       | QEMU guest agent — стоковый macOS его не понимает без стороннего порта |
| `on_boot`                       | bool    | `false`       | Автостарт на буте ноды                                             |
| `datastore_id_disk`             | string  | `local-lvm`   | Datastore                                                          |
| `disk_interface`                | string  | `sata0`       | Интерфейс главного диска macOS                                    |
| `disk_size`                     | number  | `100`         | ГиБ, thin-provisioned потолок                                     |
| `cdrom_interface`               | string  | `ide0`        | Интерфейс OpenCore ISO (грузится **каждый** boot)                 |
| `opencore_iso_file_id`          | string  | — (обязательна) | Volume ID OpenCore ISO                                          |
| `installer_interface`           | string  | `sata1`       | Интерфейс recovery/BaseSystem-диска                                |
| `installer_image_file_id`       | string  | `null`        | Volume ID recovery-образа; `null` = диск не создаётся               |
| `network_bridge` / `mac`         | string  | `vmbr0` / —   | Сеть                                                               |
| `network_model`                 | string  | `virtio`      | Актуальная рекомендация LongQT-sea для macOS 11-26                 |
| `os_type`                       | string  | `l26`         | У Proxmox нет `ostype` для macOS; `l26` ("Linux") — явная рекомендация LongQT-sea, не `other` |
| `vga_type`                      | string  | `std`         | Программный framebuffer, без ускорения                            |
| `kvm_arguments`                 | string  | см. код       | **Не применяется ресурсом** (Proxmox: `args:` только `root@pam`, см. [Что реально сработало](#что-реально-сработало)) — доступно через output модуля, применить вручную `qm set <vmid> --args '...'` |
| `efi_pre_enrolled_keys`         | bool    | `false`       | Secure Boot должен быть выключен — OpenCore не подписан            |

`tablet_device = false` прописан в ресурсе фиксированно, не переменной —
Proxmox сам включает `tablet: 1`, когда атрибут не задан вовсе, что вместе
с `virtio-tablet` из `kvm_arguments` дало бы дублирующийся указатель (см.
[Что реально сработало](#что-реально-сработало)).

## Установка macOS Tahoe с нуля

> **Статус на 2026-09-14: сделано, end-to-end, реально работает.** VM 102
> на `pve-rog` — установленная, загружающаяся сама (без ручного
> вмешательства в OpenCore picker), доступная по SSH **настоящая macOS
> Tahoe 26.6.2** (build 25G83, Darwin 25.6.0). Установщик Apple
> отработал на `Macintosh HD` (107 ГБ, APFS), через Setup Assistant
> прошли (локальный аккаунт, без миграции откуда-либо), `Remote Login`
> включён — `ssh <user>@192.168.100.11` реально принимает соединения
> снаружи. Проверено: `hw.ncpu` = 6, `hw.memsize` ≈ 16 ГиБ (совпадает с
> `cores × sockets` и `memory`), исходящий HTTPS до `github.com` (`HTTP/2
> 200` — то, что нужно для `xcodes`/Xcode CLI). Установка + Setup Assistant
> вели совместно: автоматизированная часть (сборка/патч ISO, recovery,
> `terraform apply`, диалоги инсталлятора, отслеживание reboot-циклов)
> через собственный in-memory RFB/VNC-клиент поверх Proxmox
> `vncwebsocket`-прокси (скриншоты + клавиатура/мышь, без записи
> credentials на диск), шаги, требующие пароль пользователя (создание
> аккаунта, `sudo`, Full Disk Access) — вручную через тот же
> Proxmox-консольный экран.
>
> По пути нашлось и исправлено **пять** реальных проблем, ни одна не
> была задокументирована ни в одном источнике заранее — см.
> [Что реально сработало](#что-реально-сработало): (1) `fetch-macOS-v2.py
> -s tahoe` тихо скачивает Sequoia, не Tahoe; (2) `import_from` на
> существующем `disk`-блоке не триггерит повторный импорт; (3) `args:`
> (`kvm_arguments`) жёстко `root@pam`, Terraform норовит занулить его
> обратно без `ignore_changes`; (4) `tablet_device` без явного `false` не
> выключается сам; (5) `systemsetup -setremotelogin` требует Full Disk
> Access у `Terminal.app`, простого `sudo` недостаточно.

Ниже — фактически выполненные команды (не гипотетический план), см.
[Что реально сработало](#что-реально-сработало) для деталей по каждому шагу
и того, что пришлось поправить по ходу дела.

1. **Собрать OpenCore ISO** на базе
   [`LongQT-sea/OpenCore-ISO`](https://github.com/LongQT-sea/OpenCore-ISO)
   (готовый релиз `v0.7`, явно заявляет поддержку до macOS 26, уже несёт
   `Lilu`/`VirtualSMC`/`VoodooPS2Controller`/`AppleMCEReporterDisabler` и
   SSDT-EC/SSDT-USBX):
   ```bash
   curl -sL -o LongQT-OpenCore.iso \
     https://github.com/LongQT-sea/OpenCore-ISO/releases/download/v0.7/LongQT-OpenCore-v0.7.iso
   xorriso -osirrox on -indev LongQT-OpenCore.iso -extract / extracted
   chmod -R u+w extracted
   ```
   Патч `extracted/EFI_RELEASE/EFI/OC/config.plist` (и `EFI_DEBUG` —
   пригодился для диагностики самого первого boot, см. ниже) через
   `plistlib`:
   - `PlatformInfo.Generic.SystemProductName` -> `MacPro7,1` (было
     `iMac19,1` — не в списке Tahoe-поддерживаемых, см. ниже).
   - `SystemSerialNumber`/`MLB` — сгенерированы **реальным** `macserial`
     (бинарник из `acidanthera/OpenCorePkg` релиза, `Utilities/macserial/
     macserial.linux` — работает нативно на Linux, GenSMBIOS оказался не
     нужен как GUI-обёртка):
     ```bash
     ./macserial.linux --model MacPro7,1 --generate --num 5
     ```
   - `SystemUUID` — `uuid.uuid4()`, `ROM` — 6 случайных байт с реальным
     Apple OUI-префиксом (список префиксов лежит прямо в поставке
     GenSMBIOS, `Scripts/prefix.json`).
   - `Kernel.Add`: убран `WhateverGreen.kext` — GPU нет, а Dortania прямо
     документирует конфликт WhateverGreen с AMD-connector-патчами
     конкретно на macOS 26 (panic); нам он в любом случае не нужен.
   - `csr-active-config` уже был `00000000` (SIP on) — не трогали.

   Пересборка ISO с сохранением El Torito boot record (xorriso по
   умолчанию **отбрасывает** boot-каталог при простом `-map`/`-commit` —
   нужен явный `-boot_image any replay`):
   ```bash
   xorriso -indev LongQT-OpenCore.iso -outdev OpenCore-Tahoe.iso \
     -map extracted/EFI_RELEASE/EFI/OC/config.plist /EFI_RELEASE/EFI/OC/config.plist \
     -map extracted/EFI_DEBUG/EFI/OC/config.plist   /EFI_DEBUG/EFI/OC/config.plist \
     -boot_image any replay \
     -commit
   ```
2. Загрузить на `pve-rog`:
   ```bash
   scp OpenCore-Tahoe.iso pve-rog:/var/lib/vz/template/iso/OpenCore-Tahoe.iso
   ```
   → volume id `local:iso/OpenCore-Tahoe.iso`.
3. Достать recovery/BaseSystem-образ под Tahoe — прямого Apple-ISO не
   существует. `macrecovery.py` в свежем OSX-KVM переименован в
   **`fetch-macOS-v2.py`**. **Не используйте `-s`/`--shortname`** — оно
   разбирается argparse, но `--action download` его тихо игнорирует
   (см. [Что реально сработало](#что-реально-сработало)); нужны явные
   `-b`/`-os`:
   ```bash
   git clone --depth 1 https://github.com/kholia/OSX-KVM.git
   python3 OSX-KVM/fetch-macOS-v2.py --action download \
     -b Mac-CFF7D910A743CAAF -os latest -o recovery
   ```
   Даёт `BaseSystem.dmg` (compressed UDIF) + `.chunklist`. Конвертация в
   raw — **`qemu-img` умеет читать `dmg` нативно**, отдельный `dmg2img` не
   понадобился:
   ```bash
   qemu-img convert -f dmg -O raw recovery/BaseSystem.dmg BaseSystem.raw
   ```
4. Включить `import` на storage `local` (по умолчанию выключен) и
   загрузить raw-образ:
   ```bash
   ssh pve-rog 'pvesm set local --content iso,vztmpl,snippets,backup,import'
   scp BaseSystem.raw pve-rog:/var/lib/vz/import/BaseSystem.raw
   ```
   → volume id `local:import/BaseSystem.raw`.
5. Развернуть VM с обоими образами подключенными:
   ```bash
   source scripts/apply-wrapper.sh
   vault login -method=userpass username=<you>
   terraform -chdir=env/macos-tahoe-headless init
   terraform -chdir=env/macos-tahoe-headless apply \
     -var opencore_iso_file_id="local:iso/OpenCore-Tahoe.iso" \
     -var installer_image_file_id="local:import/BaseSystem.raw"
   ```
6. Стартовать VM и открыть VNC-консоль (Disk Utility, Recovery-инсталлятор
   и Setup Assistant — интерактивные GUI-этапы, автоматизации не
   поддаются): `qm start <vmid>` → в пикере OpenCore выбрать BaseSystem →
   Disk Utility: стереть основной диск (APFS, GUID) → запустить установку
   Tahoe из Recovery (тянет остаток системы у Apple по сети — `virtio` +
   DHCP) → несколько ребутов (OpenCore-пикер переживает их, это тот же
   примонтированный cdrom).
7. После первого входа (Setup Assistant, тоже разово через VNC) отключить
   install-диск — он больше не нужен, содержимое главного диска macOS не
   трогает. Просто не передавать `-var installer_image_file_id=...` при
   следующем apply (переменная вернётся к дефолту `null` — **не** передавать
   пустую строку, это не то же самое, что `null`, и провайдер откажет на
   пустом `import_from`):
   ```bash
   terraform -chdir=env/macos-tahoe-headless apply \
     -var opencore_iso_file_id="local:iso/OpenCore-Tahoe.iso"
   ```
8. Включить SSH из того же разового GUI-сеанса: `sudo systemsetup
   -setremotelogin on`. Дальше — только по SSH.

## Что реально сработало

Изначальный черновик этого README (и дефолты `mod/vm-headless`) был собран
по разрозненным гайдам (archy.net и т.п.) до того, как нашёлся
[`LongQT-sea/OpenCore-ISO`](https://github.com/LongQT-sea/OpenCore-ISO) —
специализированный, активно поддерживаемый (релиз v0.7, февраль 2026)
проект именно под Proxmox/QEMU-хакинтоши, явно закрывающий Tahoe. Его
README оказался авторитетнее и **разошёлся с первоначальными
предположениями** в нескольких местах — вот что изменилось и почему:

| Было (первый черновик) | Стало | Почему |
|---|---|---|
| `-cpu host,vendor=GenuineIntel,+invtsc,...` | `-cpu Skylake-Client-v4,vendor=GenuineIntel` | LongQT-sea прямо документирует `host`-passthrough как на 30-44% медленнее под macOS (ссылка на бенчмарк в их README) — весь проект начинался именно чтобы уйти от `host`. `-Client-` (не `-Server-`, без AVX-512) — потому что физический CPU ноды (Haswell i7-4700HQ) AVX-512 не имеет, а KVM не может подделать набор инструкций, которого нет в кремнии. |
| `network_model = vmxnet3` | `network_model = virtio` | Их таблица прямо называет `VirtIO` для macOS 11-26; `vmxnet3` — только для 10.11-10.15. |
| `os_type = other` | `os_type = l26` | Их пошаговая инструкция явно говорит оставить Guest OS Type на дефолте ("Linux") — это `l26` в Proxmox, не `other`. |
| `cores = 6` (плашмя) | `cores = 2`, `sockets = 3` | Их CPU-раздел прямо предупреждает: ядра должны быть степенью двойки, иначе используйте `sockets` (с готовой таблицей соответствий, включая ровно "6 -> 2×3"). Плоские 6 ядер на одном сокете — кандидат в boot failure по их же формулировке ("incorrect CPU configuration will cause boot failure"). |
| `-device usb-tablet` | `-device virtio-tablet` + `tablet_device = false` явно | На macOS 26 у tablet-указателя есть задокументированный баг подвисания курсора; их "better fix" — `virtio-tablet` вместо Proxmox-нативного tablet-режима. Просто убрать атрибут из ресурса — не то же самое, что выключить его (см. ниже, "Найдено уже при реальном `terraform apply`"). |
| SMBIOS `iMac19,1` (дефолт самого ISO) | `MacPro7,1` | `iMac19,1` не входит в официально поддерживаемый Tahoe список (см. шаг 1 выше) — дефолт ISO рассчитан на широкий диапазон версий (Tiger...Tahoe одним образом), не на Tahoe конкретно. |
| Серийники — предполагался GenSMBIOS (Python-GUI, менюшный) | Бинарник `macserial.linux` напрямую | GenSMBIOS — это просто интерактивная обёртка вокруг того же бинарника; `macserial.linux --model MacPro7,1 --generate` даёт то же самое без диалогового меню, полностью скриптуется. |
| `macrecovery.py` (по имени из старых гайдов) | `fetch-macOS-v2.py` | В текущем OSX-KVM файл переименован. **`-s`/`--shortname` при этом не работает с `--action download`** — см. ниже, "Найдено уже при реальном `terraform apply`". |
| Планировался `dmg2img` для конвертации BaseSystem | `qemu-img convert -f dmg -O raw` | `qemu-img` эту версии Debian/Ubuntu-сборки уже умеет читать `dmg` нативно — отдельная утилита не понадобилась. |
| `import` на storage `local` — предполагалось "может понадобиться включить" | Действительно было выключено, включили: `pvesm set local --content iso,vztmpl,snippets,backup,import` | Подтверждённый, не гипотетический шаг. |
| `xorriso -map ... -commit` для патча ISO | Тот же `-map`, но обязательно `+ -boot_image any replay` | Без этого флага xorriso молча выбрасывает El Torito boot record ("Discarded boot image from old session") — патченный ISO собирался бы, но не грузился. |

Не изменилось (подтверждено, не потребовало правок): `machine=q35`,
`bios=ovmf`, `pre_enrolled_keys=false`, `vga=std`, отсутствие `floating` у
memory (balloon), `AppleMCEReporterDisabler.kext` (уже был в поставке
LongQT-sea — совпало с изначальным расчётом на не-Xeon CPU под `MacPro7,1`),
`csr-active-config=00000000` (SIP on, дефолт ISO).

### Найдено уже при реальном `terraform apply` (не по гайдам)

Пять моментов, которые не всплыли ни в одном источнике выше — только на
живой ноде:

- **`kvm_arguments` (`args:`) — жёстко `root@pam`-only, безусловно.**
  `terraform apply` с этим полем в ресурсе падает с `HTTP 500: only root
  can set 'args' config` — токен тут не при чём, никакая роль/ACL это не
  чинит (в `pve-qemu-server` это `raise_perm_exc` без проверки прав, тот
  же паттерн, что и `dev[n]`/`hookscript` у LXC, см. корневой README).
  `mod/vm-headless` больше не пытается установить `kvm_arguments` в самом
  ресурсе — значение доступно через output `kvm_arguments` у модуля и у
  этого env, применяется **один раз вручную** от root на ноде:
  ```bash
  ssh <node> "qm set <vmid> --args '<значение из terraform output>'"
  ```
  Повторять только если `terraform apply` пересоздаёт VM (не после
  обычных in-place изменений).
- **Убрать `tablet_device` из ресурса ≠ отключить tablet.** Предыдущая
  правка (по итогам код-ревью) убрала атрибут из `mod/vm-headless`
  целиком, рассчитывая, что тогда tablet вообще не появится. На практике
  Proxmox сам подставляет `tablet: 1`, когда атрибут не задан вовсе —
  реальный `qm config` только что созданной VM это подтвердил. С
  `virtio-tablet` из `kvm_arguments` это дало бы ровно тот дубль
  usb-tablet + virtio-tablet, которого «better fix» LongQT-sea должен был
  избежать. Исправлено: `tablet_device = false` теперь явно прописан в
  `mod/vm-headless/main.tf` (не переменная — это фиксированное архитектурное
  решение, а не то, что имеет смысл включать пользователю).
- **После ручного `qm set --args` следующий `terraform plan` хочет это
  занулить.** `refresh` читает реальный `args:` с ноды в state; ресурс,
  который про `kvm_arguments` больше ничего не говорит, читается
  Terraform'ом как "должно быть `null`" — `apply` попытался бы стереть
  то, что вы только что вручную поставили (и, вероятно, упал бы с той же
  `root@pam`-ошибкой, пытаясь это сделать). Исправлено добавлением
  `lifecycle { ignore_changes = [kvm_arguments] }` в ресурс — тот же
  приём, которым `mod/ct` уже защищает `hook_script_file_id` от точно
  такой же ситуации.
- **`fetch-macOS-v2.py -s tahoe --action download` тихо скачивает не
  Tahoe.** `-s`/`--shortname` разбирается `argparse`, но `action_download`
  (единственный код-путь, который реально выполняется при
  `--action download`) его **не читает вообще** — использует только
  `--board-id`/`--mlb`/`-os`, с дефолтами `RECENT_MAC` +
  `os_type=default`. `-s tahoe` без явного action молча падает в
  demo-меню-код с отдельным списком `products`, который `action_download`
  не видит. Результат первой попытки — реальный macOS **15.4.1 Sequoia**
  под видом "тахо" (подтверждено `sw_vers`/`SystemVersion.plist` внутри
  самой Recovery уже на живой VM, не заранее). Рабочий вызов — явные
  флаги из того же `products`-списка:
  ```bash
  python3 fetch-macOS-v2.py --action download -b Mac-CFF7D910A743CAAF -os latest -o out
  ```
  (board-id `Mac-CFF7D910A743CAAF` — тот, что скрипт сам помечает как
  `"Tahoe (26)"` в неиспользуемом для download-пути каталоге; не имеет
  отношения к SMBIOS `MacPro7,1` в OpenCore — recovery board-id только
  выбирает, какой каталог/сборку у Apple качать, не то, чем система
  представится после установки).
- **Смена `import_from` на существующем `disk`-блоке не переимпортирует
  содержимое.** После первой ошибки выше попытка просто заменить
  `installer_image_file_id` на правильный volume id и переприменить дала
  `Modifications complete after 1s` — подозрительно быстро для 2.6 ГБ.
  Так и оказалось: `qm config` продолжал показывать старый размер диска
  (`8G`, как у неверного образа), реальные байты не переехали — провайдер
  просто обновил `import_from` в state, не вызвав повторный импорт (это
  атрибут "разово при создании", не то, что Proxmox умеет применять
  повторно к уже существующему диску). Рабочий путь — **удалить** диск
  (`installer_image_file_id = null`, apply) и **добавить заново**
  (вернуть верное значение, apply) — тогда это настоящий `+ disk` в
  плане, а не `~`, и происходит настоящий новый импорт (диск получил
  новый `path_in_datastore`, `vm-102-disk-3`, с честным размером `2548M`,
  совпадающим с виртуальным размером настоящего Tahoe `BaseSystem.dmg`).
  Дополнительно: если VM в этот момент запущена, сама попытка
  detach-then-attach диска валится отдельной ошибкой (`hotplug problem -
  can't unplug device 'sata1'`) — recoveryOS не подтверждает ACPI
  hot-unplug для SATA на лету так же охотно, как Linux-гости; надёжнее
  сначала штатно остановить VM, потом уже трогать диски.
- **Инсталлятор виснет на одном из промежуточных ребутов: `IOPlatformHalt
  RestartAction -> AppleSMC` / `SMCWDT::setWatchdogTimer ERROR:
  smcWriteKey failed (kSMCBadCommand)`, повторяется бесконечно, один
  поток CPU на 100%.** Это не баг нашего `config.plist` — QEMU'шный
  `isa-applesmc` (устройство из `kvm_arguments`) реализует только
  SMC-команду *read*; *write* и *get-key-type* не реализованы вовсе,
  поэтому XNU получает `kSMCBadCommand` на попытку взвести watchdog перед
  рестартом и уходит в ретраи. Апстримный QEMU-патч, который это чинит,
  на момент написания (сентябрь 2026) ещё не влит. Убедились, что это
  зависание именно на уровне QEMU/SMC, а не порча диска: жёсткий
  `stop`/`start` VM (сработает, если это тот самый ребут, а не первый
  boot-once после стирания диска — на такой стадии диск уже дописан,
  перезапуск безопасен) привёл к нормальной загрузке с progress-баром
  Apple-логотипа с целевого диска, установка продолжилась штатно. Если
  зависание повторится на будущих ребутах инсталлятора — тот же
  stop/start, дожидаясь по CPU-нагрузке VM через API
  (`status/current`.`cpu` ~1.0 = зависло, ~0 = ждёт/простаивает).
- **`systemsetup -setremotelogin on` падает с `requires Full Disk Access
  privileges`, даже под `sudo`.** В современном macOS (подтверждено на
  Tahoe 26.6.2) `sudo` для этой конкретной команды недостаточно — самому
  `Terminal.app` нужен грант Full Disk Access через TCC: System Settings
  → Privacy & Security → Full Disk Access → `+` → добавить
  `/System/Applications/Utilities/Terminal.app` → включить тумблер →
  **Quit & Reopen** (без перезапуска Terminal грант не подхватывается,
  сессия просто восстанавливается на том же месте). После этого та же
  команда с паролем отрабатывает без ошибок — `systemsetup -getremotelogin`
  показывает `On`, порт 22 реально слушает и принимает соединения снаружи.

## Доступ

- **SSH** — основной путь. `ssh <user>@<vm-ip>`.
- **Xcode** без повторного похода в GUI — через
  [`xcodes`](https://github.com/XcodesOrg/xcodes) (Apple ID auth прямо в
  терминале, без App Store).
- **VNC/Screen Sharing** — изредка, см. следующий раздел про честные
  ограничения.

## Известные ограничения

- **`terraform apply` требует распечатанный Vault.** `apply-wrapper.sh`
  тянет `proxmox_api_token` и MinIO-credentials из Vault
  (`192.168.100.200:8200` / `lxc-bare-pve.tail65829d.ts.net:8200` —
  адреса разошлись, см. `VAULT_ADDR` в окружении на момент работы).
  Распечатывание Vault — операция, требующая unseal-ключей у оператора;
  агент намеренно не пытается ни распечатать Vault, ни получить
  Proxmox-credentials в обход него (например прямыми `qm create`/`pveum
  token add` на ноде по root SSH) — это осознанно оставлено человеку.
- **Headless-only, без Metal/GPU-acceleration.** `vga = std` — программный
  framebuffer. Осознанный компромисс: это backend для сборок, не десктоп.
- ~~Screen Sharing/VNC не гарантирован~~ — **опровергнуто на практике.**
  Опасение было, что `WindowServer` без Apple-распознаваемого
  GPU-драйвера (`WhateverGreen` сюда намеренно не добавлен) не поднимет
  GUI-сессию вовсе. На деле `vga=std` (программный QEMU-framebuffer) от
  WindowServer'у хватило за глаза: весь Setup Assistant, Finder, System
  Settings, Terminal — всё отработало через тот же Proxmox
  `vncwebsocket`-канал, никаких доп. framebuffer-патчей не понадобилось.
  Via сам Proxmox VNC (`/vncproxy` + `/vncwebsocket` API) — не Screen
  Sharing через `gnome-remote-desktop`-аналог или ARD, тот отдельно не
  проверялся, но раз WindowServer поднимается штатно, шансы хорошие.
- **SMBIOS `MacPro7,1` на Haswell-мобильном CPU — намеренное несоответствие
  поколений.** Ванильный OpenCore это разрешает (XNU проверяет набор
  инструкций, а не буквальное совпадение железа с SMBIOS — в этом суть
  hackintosh), но конкретно эта комбинация (Proxmox + QEMU + Haswell +
  MacPro7,1 + Tahoe) не была массово обкатана сообществом на момент
  написания — ожидать итераций по kext-списку/quirks.
- **`kvm_arguments` не применяется `terraform apply` — только output.**
  Proxmox жёстко привязывает `args:` к `root@pam`, безусловно (см. [Что
  реально сработало](#что-реально-сработало)). После **любого** apply,
  который пересоздаёт VM (не после обычных in-place правок), нужно заново
  выполнить `qm set <vmid> --args '<terraform output kvm_arguments>'` от
  root на ноде — Terraform об этом не напомнит, `plan` не покажет разницу
  (поле вне ресурса).
- **`kvm_arguments` — рабочий набор из активно поддерживаемого источника
  (LongQT-sea/OpenCore-ISO), не гарантия для конкретно этой ноды.**
  Пока не загружен реальной сборкой Xcode — считать проверенным только до
  стадии "грузится и отвечает по SSH", не более. Аудио-кексты
  (`AppleALC`/`VoodooHDA`) намеренно не добавлены — headless backend не
  воспроизводит звук; в Tahoe `AppleHDA.kext` всё равно убран из системы
  (см. tahoe.html), так что аналоговый звук через AppleALC в любом случае
  сломан, если он вдруг понадобится.
- **`import_from` требует content-type `import` на storage** — новее, чем
  `iso`/`vztmpl`; на непроверенном `pve-rog` может потребоваться ручное
  включение (`pvesm set`), см. [Требования](#требования).
- **EFI/OpenCore не управляется Terraform.** `opencore_iso_file_id`
  указывает на файл, который вы собираете и обновляете на ноде вручную —
  итерация `config.plist` (добавить kext, поправить quirk) не требует
  `terraform apply`, только пересборку и повторную загрузку ISO.
- **Легальность non-Apple железа** — уже обсуждалась отдельно, здесь не
  повторяется.

## Источники

- [Dortania OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/)
- [macOS Tahoe (26) — Dortania](https://dortania.github.io/OpenCore-Install-Guide/extras/tahoe.html)
- [Choosing the right SMBIOS — Dortania](https://dortania.github.io/OpenCore-Install-Guide/extras/smbios-support.html)
- [`LongQT-sea/OpenCore-ISO`](https://github.com/LongQT-sea/OpenCore-ISO) —
  основной источник для CPU/network/SMBIOS/tablet-выбора в этой версии
  README и `mod/vm-headless` (актуальнее и авторитетнее для этой связки,
  чем нижеследующие)
- [`kholia/OSX-KVM`](https://github.com/kholia/OSX-KVM) (`fetch-macOS-v2.py`,
  бывший `macrecovery.py`)
- [`acidanthera/OpenCorePkg`](https://github.com/acidanthera/OpenCorePkg)
  (`Utilities/macserial` — генерация серийников)
- [`thenickdude/KVM-Opencore`](https://github.com/thenickdude/KVM-Opencore)
- [Installing macOS Tahoma as a Proxmox VM — archy.net](https://www.archy.net/installing-macos-tahoma-as-a-proxmox-vm-a-complete-guide/)
  (первоначальный источник `kvm_arguments`, частично вытеснен LongQT-sea —
  см. [Что реально сработало](#что-реально-сработало))
- [bpg/proxmox provider — `proxmox_virtual_environment_vm`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm)
