# macOS Tahoe desktop (env/macos-tahoe-desktop)

Третье, взаимоисключающее состояние `bare-pve`, рядом с `env/windows` и
`env/ubuntu`: реальный GPU passthrough (GTX 950 + USB-контроллеры +
onboard-audio, `vfio-pci`) в hackintosh-VM с OpenCore, macOS **Tahoe 26**.

В отличие от `env/macos-tahoe-headless` (нода `pve-rog`, без GPU вообще,
`mod/vm-headless`) — это `mod/vm`, тот же модуль, что и `env/windows`, с
`manage_mappings = false`: passthrough-устройства и `hardware_mapping_pci`
принадлежат `env/windows`, этот env их только потребляет. Три гостя никогда
не запускаются одновременно — переключение делает
`scripts/gpu-arbiter.sh`/`scripts/workstation.sh` (теперь 3-way:
windows/macos/ubuntu).

## Почему Tahoe, а не Monterey

Первоначальный план — macOS Monterey (12.x) с non-Metal-ускорением через
OpenCore-Legacy-Patcher (OCLP), т.к. официального NVIDIA-драйвера для
Monterey+ не существует, а Maxwell (GTX 950) не Metal-совместим "из коробки"
на новых macOS. Приоритет пользователя (в порядке важности):

1. Работающее GPU-ускорение в госте.
2. Максимально новая версия macOS из возможных.
3. Стабильность.

С этим приоритетом и явным разрешением "рискованно, но можно попробовать —
сначала попробуй, откатиться на более старую версию всегда успеешь" — выбор
пал на **Tahoe** (26), а не на более консервативный Sequoia или сам
Monterey: OCLP 2.5.0 (2026-09-08) уже содержит `tahoe = 25` как реальное
распознаваемое значение в `os_data.py`, а условие для non-Metal-патчинга в
`non_metal.py` (`_os_requires_patches()`) — это просто `xnu_major >=
mojave.value`, без верхней границы. То есть патчинг для Tahoe не
захардкожен-заблокирован в самом коде OCLP, хотя официально Dortania его
ещё не подтверждает как документированную конфигурацию. Если non-Metal на
Tahoe окажется фундаментально нерабочим (не просто нестабильным, а честным
дохлым концом без пути вперёд) — откат на Sequoia или Monterey остаётся
рабочим планом Б, инфраструктура (arbiter, VM, mod/vm) для этого менять не
придётся, только пересобрать OpenCore ISO/recovery под другую версию.

## Архитектура

- `mod/vm` (не отдельный модуль) — `cores = 4` (весь `bare-pve`, i5-4460,
  без SMT — уже степень двойки, `sockets` не нужен), `memory = 12288`
  (как у `env/windows` — гости взаимоисключающи).
- `manage_mappings = false`, `passthrough` — `gtx950` (`primary_gpu =
  var.gpu_primary`), `usb-xhci`, `usb-ehci1`, `usb-ehci2`,
  `onboard-audio` — те же имена, что `env/windows` уже завёл как
  `hardware_mapping_pci`.
- `cdrom_interface = "ide0"` — OpenCore ISO, подключён постоянно (не только
  на установку, в отличие от Windows-инсталлятора).
- `installer_interface = "sata1"` / `installer_image_file_id` — опциональный
  второй диск для recovery/BaseSystem-образа на время установки; `null`
  после того, как система установлена на основной `sata0`.
- `gpu_primary` — `false` на установку (`x-vga` не даёт GOP на этой карте,
  ставим через std VGA / noVNC), `true` после того, как WhateverGreen готов
  сам рулить картой — та же схема, что у `env/windows`.
- Без `kvm_arguments` — у `mod/vm` такой переменной вообще нет (Windows он
  никогда не был нужен), и эта сборка Tahoe грузилась и работала на голом
  `cpu.type = "host"` ещё до того, как в headless-проекте всплыл `isa-applesmc`
  (см. `env/macos-tahoe-headless/README.md`, SMCWDT reboot hang) — добавлять
  превентивно не стали.

## Установка с нуля

1. Собрать OpenCore ISO ([LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO),
   v0.7) с SMBIOS `MacPro7,1` (свежие серийники), сохранив WhateverGreen,
   `csr-active-config = 030A0000` (частично отключённый SIP — требование
   OCLP root-patcher'а). Загрузить на ноду как `local:iso/<...>.iso`.
2. Скачать recovery/BaseSystem образ через `fetch-macOS-v2.py` (OSX-KVM) —
   `-b Mac-CFF7D910A743CAAF -os latest` (board-id Tahoe; `-s`/`--shortname`
   для `--action download` не работает, это известный мёртвый параметр).
   Конвертировать `qemu-img convert -f dmg -O raw` (родная поддержка dmg,
   `dmg2img` не нужен). Загрузить как `local:import/<...>.raw`.
3. `terraform -chdir=env/macos-tahoe-desktop apply -var opencore_iso_file_id=... -var installer_image_file_id=...`
4. `workstation.sh switch macos && workstation.sh start macos` — арбитр
   перебиндит GTX 950/USB/audio на vfio-pci, поднимет VM.
5. Через консоль/VNC (`x-vga=false`, std VGA — доступен через Proxmox
   noVNC) пройти Recovery → Disk Utility (стереть целевой диск как APFS) →
   Reinstall macOS Tahoe → долгая установка (копирование + несколько
   автоматических перезагрузок).
6. После установки — скачать `OpenCore-Patcher.pkg` (OCLP) внутри гостя,
   root-patch для non-Metal Maxwell.
7. `terraform apply -var gpu_primary=true -var installer_image_file_id=null`
   (уже не нужен install-диск) — переключить вывод на физический монитор.

## Найдено при реальном apply

- `mod/vm`: `hook_script_file_id` и `started` дрейфовали против дефолтов
  схемы провайдера — реальный, ранее существовавший баг, найденный на живом
  состоянии `env/windows` (`terraform plan` показывал снятие hookscript и
  автозапуск VM). Фикс — `lifecycle { ignore_changes = [hook_script_file_id,
  started] }`; подтверждено `terraform plan` → "No changes" на `env/windows`
  без затрагивания самого env.
- `ignore_changes` на `started` не подменяет дефолт при **первом** create —
  первый `apply` новой VM попытался автостартовать её, пока хост ещё был в
  режиме ubuntu/nvidia: `"Cannot bind 0000:01:00.0 to vfio ... No such
  device"`. Фикс — явный `started = false` в теле ресурса. Ресурс остался
  `tainted` — почищено `terraform untaint`, а не пересоздание (иначе заново
  перезаливать 2.6 ГБ BaseSystem-диск).
- `vm_role()`/`other_guest_running()` в `gpu-arbiter.sh` — новая логика
  различает гостей по **имени**, а не просто "это VM = значит Windows"
  (латентный баг исходного 2-way скрипта: любая другая qemu-VM с
  hookscript'ом была бы ошибочно принята за Windows).
- Клавиатура в госте на время пропадала (мышь работала) во время установки
  — совпало с `PKDownloadError error 8` при загрузке payload. Добавление
  выделенного `usb-kbd` через `qm set --args` не помогло; при этом
  клавиатура явно работала раньше в той же сессии (стирание диска,
  лицензия, выбор диска, старт установки). Откатили `--args`, перезапустили
  VM — клавиатура снова заработала без каких-либо изменений конфигурации.
  Похоже на переходный сбой самой VNC-сессии, а не реальную проблему ввода;
  `PKDownloadError`, скорее всего, тоже был случайным сетевым сбоем
  (`curl -sS https://swscan.apple.com` после отката отработал за ~0.2s).

## Честный статус

**Установка Tahoe идёт** (эта секция будет дополнена честными результатами
после завершения установки и root-patch OCLP — что реально заработало
из non-Metal-ускорения на этой GTX 950, что нет, и итоговое состояние
`gpu_primary`/физического вывода).
