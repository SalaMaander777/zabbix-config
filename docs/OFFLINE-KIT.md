# Офлайн-комплекты

Интернета нет ни на одном компьютере объекта. Комплекты собираются в GitHub Actions, скачиваются на машине с интернетом и переносятся на флешке (exFAT/NTFS, от 32 ГБ). Ни один скрипт на объекте в сеть не ходит. Бинарные файлы в git не хранятся — они в артефактах.

## zabbix-vm (workflow `vm-image`)
- `zabbix-vm-debian12.zip` — диск ВМ для Hyper-V (VHDX): Debian 12, Docker Engine, весь стек, образы, подложка карты;
- `zabbix-vm-debian12-vdi.zip` — тот же диск для VirtualBox (VDI);
- `BUILD-INFO.txt` (поколение ВМ, версии), `SHA256SUMS`, `HYPERV-VM.md`;
- `precheck.ps1`, `hyperv-install.ps1`, `hyperv-create-vm.ps1`, `virtualbox-install.ps1`, `virtualbox-create-vm.ps1`.

## zabbix-offline (workflow `offline-bundle`)
- `images.tar` — postgres, zabbix-server-custom (с python3), zabbix-web-nginx-pgsql, zabbix-agent2, zabbix-map (linux/amd64);
- `docker-compose.yml`, `docker-compose.map.yml`, `.env.example`, `server/`, `zabbix/`, `templates/`, `map/` (с `map/data/moscow.pmtiles`), `scripts/`, `docs/`;
- `installers/`:
  - `DockerDesktopInstaller.exe`, `wsl.*.x64.msi` — путь B;
  - `virtualbox/` — VirtualBox 7.1.18, `vc_redist.x64.exe`, `SHA256SUMS` — путь A2;
  - агенты Zabbix 7.0.32: `zabbix_agent2-...-windows-amd64-openssl.msi` (Win10/11), `zabbix_agent-...-windows-amd64/i386-openssl.msi` (классический, Win7);
  - `browsers/` — Firefox ESR (Win10/11) и ESR 115 (Win7 x64/x86), русские;
  - `tools/` — WinSCP portable;
- `SHA256SUMS` на все файлы (проверяет `load-and-start.ps1`; `.env` в комплект не попадает).

## Ручная сборка на Mac (если нужно)
`scripts/build-offline-bundle.sh` → `dist/zabbix-offline-<дата>/` (нужен Docker и интернет). Образ ВМ собирается только в CI (`vm/build-vm-image.sh`, нужен Linux).

## Чего нет и почему
- ISO Windows 10 LTSC 2019 — лицензионный, берётся у владельца лицензии (нужен, только если в Windows вырезаны файлы Hyper-V).
- MIB Infinet и руководства R&S — для работы не нужны (шаблоны на числовых OID); источники указаны в `INFINET.md`, `ESMD.md`.
