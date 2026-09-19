# MORPH-FLAGS-01 object-level adapter

Связанный issue: #35.

Этот adapter закрывает только object-level часть MORPH-FLAGS-01:

- formatting-only;
- move-only;
- resize-only;
- rotation-only;
- restore-to-baseline.

Scenario/design switch вынесен в отдельный gate, потому что текущий проектный corpus ещё не даёт подтверждённый COM/Ribbon/UI entrypoint, который можно безопасно зашить в harness.

## Fixture contract

### Base source

Должен содержать ровно один:

```text
PUB_ORACLE_ID = MORPH_TARGET
```

Из одного exact base source независимо запускаются format/move/resize/rotation arms.

### Restore source

Для `restore-left` используется отдельный pinned source, где target уже сдвинут относительно baseline.

Он содержит:

```text
PUB_ORACLE_ID = MORPH_TARGET
MORPH_BASE_LEFT = <invariant decimal>
```

Adapter меняет только `Shape.Left` обратно к tagged baseline.

## Case IDs

### Formatting-only

```text
format-fill-<RRGGBB-like hex scalar>
```

Пример:

```text
format-fill-336699
```

Значение передаётся напрямую в `Shape.Fill.ForeColor.RGB` как numeric COM value. Adapter не приписывает этому scalar отдельную on-disk семантику.

Если sentinel уже совпадает с baseline fill value, arm блокируется как no-op.

### Move-only

```text
move-x-12
move-x--12
```

Меняется только `Shape.Left`.

### Resize-only

```text
resize-width-12
resize-width--6.5
```

Меняется только `Shape.Width`; неположительный итоговый width запрещён.

### Rotation-only

```text
rotate-15
rotate--15
```

Меняется только `Shape.Rotation`.

### Restore

```text
restore-left
```

Меняется только `Shape.Left` к `MORPH_BASE_LEFT`.

## Capture

Before / after / reopen:

- PageID;
- Shape.ID/Name;
- oracle tag;
- baseline-left tag;
- Left/Top/Width/Height;
- Rotation;
- Fill.ForeColor.RGB;
- Line.ForeColor.RGB;
- text, если target имеет TextFrame.

После current SaveAs:

- output SHA-256;
- size.

## Что сравнивать offline

Основной target — уже восстановленные Publisher-specific structures:

- OplPo.FUserChangedFmt;
- OplPo.FMoved;
- OplOt.FInCurrentScenario;
- OplOt.FEverChangedFmt;
- OplLastFmt;
- Oid/OidExpectedParent.

Adapter **не** интерпретирует эти поля и не использует их как условие успешности.

## Почему restore source отдельный

Если один run сначала двигает объект, а затем возвращает его назад, невозможно отделить:

```text
move event
+
restore event
```

от одного restore transition.

Поэтому restore arm начинается из отдельно pinned moved source. Это позволяет проверить current-state против sticky/historical flags одним действием.

## Scenario switch

Scenario/design switch остаётся отдельным gate.

До подтверждения exact Publisher entrypoint нельзя подменять его:

- произвольной сменой template;
- повторным применением layout;
- raw patch'ем OplControlling;
- несколькими UI actions без event provenance.

## Guardrails

- Один arm меняет одно COM property.
- Current PUB writer only.
- Geometry/text не нормализуются harness'ом вручную.
- Reopen snapshot — semantic persistence oracle, не wire attribution.
- OplPo/OplOt flags получают смысл только после offline diff.
