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
6. Включить SSH (`sudo systemsetup -setremotelogin on` — сначала выдать
   `Terminal.app` Full Disk Access, иначе команда откажет) — всё
   дальнейшее удобнее по SSH, чем через VNC-клавиатуру.
7. Скачать `OpenCore-Patcher.pkg` (OCLP) внутри гостя (`scp` по SSH или
   `curl` прямо в госте), поставить (`installer -pkg ... -target /`).
8. **Перед `--patch_sys_vol`**: из настоящего Recovery (`macOS Base
   System` в OpenCore picker) выполнить `csrutil disable` и `csrutil
   authenticated-root disable` — NVRAM-патч `csr-active-config` в самом
   OpenCore ISO (шаг 1) на практике не сработал. После — `sudo nvram
   boot-args="... amfi=0x80"` и `touch ~/.dortania_developer` (см.
   "Найдено при реальном apply" — оба нужны для Tahoe на OCLP 2.5.0).
9. `sudo /Applications/OpenCore-Patcher.app/Contents/MacOS/OpenCore-Patcher
   --patch_sys_vol`, перезагрузка.
10. `terraform apply -var gpu_primary=true -var installer_image_file_id=null`
    (install-диск больше не нужен) — переключить вывод на физический
    монитор. **На этой конкретной карте (см. "Честный статус") этот шаг
    сейчас не даёт рабочего вывода** — карта пропадает из системы
    полностью (legacy-only VBIOS, нет UEFI GOP). Оставлено на
    `gpu_primary = false` до появления UEFI-GOP VBIOS через `rom_file`.

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
- Setup Assistant реально **зависал** на шаге "Update Mac Automatically"
  (~20+ минут, оба навигационных кнопки disabled, spinner крутится без
  дальнейшего прогресса) — похоже на зависший `softwareupdated`
  catalog-запрос на этой конкретной hackintosh-конфигурации. Progress
  Setup Assistant **переживает перезагрузку** — `qm stop`/`workstation.sh
  start macos` привели прямо к экрану логина, без повторного прохождения
  уже пройденных шагов (аккаунт и т.д. сохранились).
- SSH (`sudo systemsetup -setremotelogin on`) требует Full Disk Access у
  `Terminal.app` — тот же урок, что и в `env/macos-tahoe-headless`
  (System Settings → Privacy & Security → Full Disk Access → добавить
  Terminal → Quit & Reopen). Без этого команда молча падает с "Turning
  Remote Login on or off requires Full Disk Access privileges."
- **OCLP 2.5.0 CLI (`--patch_sys_vol`) против Tahoe** потребовал трёх
  отдельных фиксов сверх косметического `csr-active-config`-патча в самом
  OpenCore `config.plist` (тот патч, как оказалось, **не сработал** —
  забутленный SIP показывал `0x40`, не ожидаемые `0x0A03`/`0x803`, т.к.
  NVRAM-ключ `csr-active-config` изначально отсутствовал в `NVRAM->Add`
  шаблона LongQT-ISO, и условный патч в `patch_config.py` его не создавал,
  только модифицировал бы существующий):
  1. `csrutil disable` + `csrutil authenticated-root disable` **из
     настоящего Recovery** (`macOS Base System` в OpenCore picker, Utilities
     → Terminal) — это по факту единственный надёжный способ выставить
     верный SIP-битмаск, а не ручной NVRAM-патч в ISO.
  2. `sudo nvram boot-args="... amfi=0x80"` — иначе "AMFI is enabled"
     блокирует патчинг даже при верном SIP.
  3. `touch ~/.dortania_developer` — у OCLP 2.5.0 есть хардкод
     `_max_os = os_data.sequoia.value` в отдельном validation-гейте
     (`detect.py`, НЕ том же файле, что `non_metal.py`'s
     `_os_requires_patches()`, у которого верхней границы нет) — без этого
     файла патчер выдаёт "Unsupported Host OS" для Tahoe независимо от
     остального. Файл — официальный, в самом исходнике предусмотренный
     "Dortania Developer mode" бэкдор для тестирования против ещё не
     официально подтверждённых ОС, не эксплойт.
  После всех трёх фиксов `--patch_sys_vol` реально прошёл ("Patching
  complete") и поставил patchset "Legacy USB 1.1" (+ Extended + Webcam).
  Перезагрузка Recovery↔основной OS ловится через **OpenCore picker с
  Timeout=2 секунды** — через VNC поймать его вживую почти невозможно
  (round-trip дольше самого окна); рабочий приём: `reboot`, подождать ~13с
  (POST + OpenCore init), затем непрерывно слать `Down`/`Right` каждые
  0.15-0.25с несколько секунд — любое нажатие внутри 2-секундного окна
  **отменяет** автозагрузку и ждёт явного выбора.

## Честный статус

**Живая macOS Tahoe 26.6.2 (build 25G83) на bare-pve, стабильно** —
установлена с нуля, аккаунт создан, SSH-доступ настроен и работает
(`ssh workstation@<ip>`, ключ добавлен через `authorized_keys`), 3-way
`gpu-arbiter.sh`/`workstation.sh` переключение подтверждено на реальном
железе без затрагивания `env/windows`/`env/ubuntu`. Это состояние, которое
пользователь увидит утром: гость **включается и полностью
функционален по SSH**, но **не на `gpu_primary = true`** — см. ниже.

### Что реально сработало

- Установка с нуля через Recovery → "Reinstall macOS Tahoe" → создание
  диска → полный Setup Assistant (несмотря на зависание на update-check).
- SSH с Full Disk Access, passwordless auth через `authorized_keys`.
- `csrutil disable` + `authenticated-root disable` из настоящего Recovery.
- OCLP 2.5.0 `--patch_sys_vol` реально патчит корневой том Tahoe (не
  падает, не блокируется): SIP/AMFI/dev-mode гейты все обходятся описанным
  выше способом, `Legacy USB 1.1` patchset ставится и переживает
  перезагрузку.
- `gpu_primary = false` (std-VGA на установку, тот же приём, что и
  `env/windows`) — полностью рабочий, стабильный путь; носитель для этого
  README и вообще всей сессии диагностики.

### Что НЕ сработало (честно) — реальный физический вывод через GTX 950

`gpu_primary = true` (т.е. `x-vga = 1` на `hostpci0`, `-vga none
-nographic` в реальной QEMU-команде — подтверждено `qm showcmd`) **не
работает**: после переключения и ребута гость грузится и остаётся
SSH-доступен, но сама видеокарта **полностью пропадает** из системы —
`system_profiler SPPCIDataType` не показывает vendor `10de` вообще,
`ioreg -l` не находит ни одного упоминания NVIDIA/GeForce, `dmesg` молчит
про GM206. Т.е. это не "нет экрана", а "гостевая ОС не видит устройство на
шине вообще".

Корень найден и подтверждён дампом реального VBIOS прямо с карты (хост,
`/sys/bus/pci/devices/0000:01:00.0/rom`): **58368 байт, единственный
legacy x86 (`codetype=0`) образ, никакого UEFI/EFI Byte Code образа
нет.** Это означает, что у этой конкретной GTX 950 **нет UEFI GOP**
(Graphics Output Protocol) в собственном VBIOS — чисто legacy-BIOS OPROM.
OVMF — чисто UEFI-firmware — не может получить framebuffer от такого
OPROM; судя по всему при `x-vga=1` это приводит к тому, что весь PCI-девайс
не публикуется гостю вообще (не просто "нет вывода").

Важно: это **не баг конкретно macOS-конфигурации** — `env/windows`
использует ровно тот же `hostpci`/`x-vga`-конфиг (`qm showcmd 100`
подтверждает идентичное отсутствие `x-vga=on` в реальной команде и тот же
`-vga none`) и тем не менее помечен как рабочий — потому что Windows не
требует EFI GOP на этапе загрузки и нормально доигрывает без него, а
OpenCore/macOS требует. **Это ограничение железа/прошивки, не версии
macOS** — откат на Sequoia или Monterey эту проблему никак не решит.

Путь вперёд (не сделано в этой сессии — требует внешних
инструментов/физического доступа):
- Достать/пропатчить UEFI-GOP-совместимый VBIOS именно для этой карты
  (например, база techpowerup.com/vgabios под точную ревизию платы, или
  официальный NVIDIA GOP-update тул) и передать через уже существующую
  `rom_file`-переменную в `mod/vm`/`env/macos-tahoe-desktop` — модуль это
  уже поддерживает, просто нет проверенного файла.
- Или принять `gpu_primary = false` как постоянное состояние (гость
  полностью рабочий и доступен по SSH/screen sharing, просто без
  физического вывода на монитор через эту карту) и не проверять non-Metal
  ускорение вживую вообще — не блокирует использование как SSH/удалённой
  рабочей станции.

`gpu_primary` **оставлен в состоянии `false`** (реальный `terraform
apply -var gpu_primary=false` выполнен и подтверждён) — чтобы гость
оставался в предсказуемом, известно-рабочем состоянии, а не в тёмном
экране без диагностики. Non-Metal root-patch (OCLP) для самого Maxwell
GPU (Nvidia non-Metal enablement patchset, не "Legacy USB") **не был и не
может быть проверен**, пока карта не видна системе как графическое
устройство — OCLP определяет нужные патчи по реально обнаруженному
железу, а не видит его сейчас вообще.
