# MORPH-SCENARIO-01

Controlled wizard/design switch для MORPH-FLAGS-01.

Связанный issue: #39.

Microsoft Learn документирует `Document.ChangeDocument(Wizard, Design)` как операцию, которая меняет текущую publication на заданный wizard и optional design. `Wizard.SetId` отдельно документирован как conversion с best-effort mapping и Extra Content; этот первый adapter его не смешивает с ChangeDocument.

## Case ID

`change-document--wizard-<id>--design-<id>`

Пример:

    change-document--wizard-8--design-123

Оба числа — Publisher COM/API values. Они не считаются raw OplControlling/Oid/Contents IDs.

## Fixture contract

- exact wizard publication;
- `Document.Wizard` доступен;
- до switch существует ровно один `PUB_ORACLE_ID=MORPH_TARGET`;
- target wizard/design определены заранее;
- каждый target запускается от свежей копии того же source PUB.

## Mutation

Adapter делает ровно один semantic call:

    Document.ChangeDocument(targetWizard, targetDesign)

Никаких move/resize/formatting mutations в этом arm нет.

## Before / after / reopen snapshot

Document level:
- Pages.Count;
- Wizard.ID / Name;
- Wizard.Properties: collection index, ID, Name, CurrentValueId, Enabled;
- SurplusShapes, где API доступно.

Для каждого shape на каждой page:
- PageID;
- Shape.ID / Name;
- `PUB_ORACLE_ID`;
- WizardTag / WizardTagInstance;
- IsExcess;
- Left / Top / Width / Height / Rotation;
- text, где есть TextFrame.

Это намеренно широкий object graph: ChangeDocument по определению может перестраивать страницы, объекты, geometry и formatting.

## No-op guard

Microsoft documentation для `Documents.Add(PbWizard, desid)` показывает получение design ID через `Wizard.Properties(1).CurrentValueId`. Adapter использует это только как documented current-design probe для запрета очевидного no-op, когда одновременно совпадают Wizard.ID и первый CurrentValueId.

Это не объявляется wire-форматом design identity.

## WizardAfterChange

Microsoft документирует `WizardAfterChange` как событие после wizard operation и отмечает, что оно приходит один раз независимо от числа внутренних modifications.

Текущий adapter не имеет COM event sink, поэтому результат содержит:

`wizard_after_change = not_instrumented`

Нельзя превращать наличие метода ChangeDocument в утверждение, что event был фактически наблюдён.

## Analysis target

После native run сравнить object-aligned binary diff:

- OplControlling;
- MorphingContextData;
- ObjectTracking / OplOt;
- OplPo current flags;
- Oid / OidExpectedParent;
- OplLastFmt;
- SurplusShapes / IsExcess semantic outcomes.

## Guardrails

- ровно один ChangeDocument call;
- COM wizard/design IDs не объединяются с wire IDs;
- mass changes сохраняются, а не фильтруются как noise;
- field-to-API mapping только после raw attribution;
- current SaveAs only для первого scenario arm.

Официальные API страницы:
- https://learn.microsoft.com/en-us/office/vba/api/publisher.document.changedocument
- https://learn.microsoft.com/en-us/office/vba/api/publisher.wizard.setid
- https://learn.microsoft.com/en-us/office/vba/api/publisher.document.wizardafterchange
