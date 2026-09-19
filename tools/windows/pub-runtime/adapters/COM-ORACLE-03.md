# COM-ORACLE-03 story topology adapter

Связанный issue: #33.

Adapter создаёт controlled semantic outputs для сопоставления Publisher `Document.Stories` / linked text frames с Quill/Contents topology.

Microsoft Publisher Object Model документирует:

- `TextFrame.NextLinkedTextFrame` как read/write link;
- `TextFrame.BreakForwardLink()` как разрыв forward link;
- `TextFrame.Story` как semantic story view;
- `HasNextLink` / `HasPreviousLink` как link-state properties.

Источники:
- https://learn.microsoft.com/en-us/office/vba/api/publisher.textframe
- https://learn.microsoft.com/en-us/office/vba/api/publisher.textframe.nextlinkedtextframe
- https://learn.microsoft.com/en-us/office/vba/api/publisher.textframe.breakforwardlink

## Fixture contract

Каждый exact source PUB должен содержать ровно:

```text
PUB_ORACLE_ID = STORY_A
PUB_ORACLE_ID = STORY_B
```

### Source family U

Используется для:

- `unlinked`
- `link`

A и B не связаны.

### Source family L

Используется для:

- `break`

A уже связан forward link с B.

Text/geometry между U и L должны быть проверены fixture provenance слоем отдельно.

Почему так: строить `break` как link+break из unlinked source означало бы две semantic mutations в одном arm.

## Case ID

```text
<operation>--<writer>
```

Operations:

- `unlinked`
- `link`
- `break`

Writers:

- `current`
- `publisher2000`
- `publisher98`

Примеры:

```text
unlinked--current
link--current
break--current
link--publisher2000
```

## Capture

Для всего document:

- `Document.Stories.Count`.

Для STORY_A/STORY_B:

- PageID;
- Shape.ID/Name;
- tag;
- text;
- HasNextLink;
- HasPreviousLink;
- next/previous linked target Shape.ID/Name/tag;
- `TextFrame.Story.Type`;
- `TextFrame.Story.TextRange.Text`.

Снимаются три semantic stages:

1. before;
2. after mutation;
3. reopen сохранённого PUB.

Отдельно сохраняются output SHA-256 и size.

## Mutation rules

### unlinked

Никакой topology mutation.

Если exact source уже содержит A→B link, adapter останавливает arm как fixture mismatch.

### link

Единственное действие:

```text
STORY_A.TextFrame.NextLinkedTextFrame = STORY_B.TextFrame
```

Source обязан быть unlinked.

### break

Единственное действие:

```text
STORY_A.TextFrame.BreakForwardLink()
```

Source обязан уже иметь forward link.

## Что анализировать offline

После native run:

- Quill directory/chunk diff;
- STRS/SYID/story-related structures;
- Contents object linkage fields;
- stable/changed Shape/Story identity;
- current writer отдельно от conversion writers.

Adapter сам не называет ни один изменившийся wire field «story pointer» до binary attribution.

## Guardrails

- COM topology — semantic oracle, не binary model.
- Если Publisher перераспределяет text при link/break, это сохраняется как observation.
- Reopen tags могут исчезнуть при conversion; такой reopen locator failure фиксируется как error, а output PUB всё равно остаётся valid artifact для offline анализа.
- SaveAs 2000/98 — conversion writer evidence.
