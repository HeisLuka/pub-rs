# LAB-ENV-01

Preflight для version-pinned Microsoft Publisher evidence environment.

Связанный issue: #26.

## Запуск

На чистом snapshot:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\pub-runtime\Get-PubLabEnvironment.ps1 `
  -SnapshotId MODERN-2019-12527 `
  -OutputRoot C:\pub-lab\environment\MODERN
```

Для Publisher 2007 используется другой snapshot и другой ID, например `P2007-RTM`. Само имя ID не является доказательством build.

## Что фиксируется

- OS/process bitness и PowerShell;
- locale/UI locale/ANSI codepage/timezone;
- default printer;
- Publisher COM Version/Build/Path;
- для найденных рядом с Publisher: MSPUB.EXE, PUBCONV.DLL, PTXT9.DLL, PUBOLE.DLL:
  - размер;
  - SHA-256;
  - FileVersion;
  - ProductVersion;
  - PE COFF timestamp;
- canonical fingerprint font registry set;
- stable fingerprint всего перечисленного.

По умолчанию выполняются два независимых Publisher-process capture. `comparison.json` сообщает, совпала ли стабильная часть manifest.

## Важное ограничение

Два process-cold capture не заменяют restore VM snapshot. Для финального evidence run:

1. restore clean snapshot;
2. запустить LAB-ENV-01;
3. сохранить EnvironmentManifest;
4. выполнить experiment;
5. для независимого повтора снова restore того же snapshot.

## Отсутствующие DLL

Скрипт инвентаризирует перечисленные модули, только если они найдены в Publisher install directory. Отсутствие файла в этом каталоге не означает, что соответствующий компонент никогда не участвует в runtime path.

## Gate

Если stable fingerprints двух captures различаются, script возвращает exit code 2. Drift надо классифицировать до native experiment.

Это infrastructure gate, не доказательство формата PUB.
