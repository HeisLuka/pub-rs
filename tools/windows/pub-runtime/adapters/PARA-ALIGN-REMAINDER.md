# Paragraph alignment remainder adapter

Связанный issue: #31.

Adapter закрывает оставшуюся часть controlled paragraph-alignment matrix после уже подтверждённого Publisher 2019 explicit FDPP path для значений 1–4.

Microsoft Publisher Object Model определяет `ParagraphFormat.Alignment` как read/write `PbParagraphAlignmentType` и документирует значения:

- 0 — Left;
- 1 — Center;
- 2 — Right;
- 3 — InterWord;
- 4 — Distribute;
- 5 — DistributeEastAsia;
- 6 — Justified;
- 7 — InterIdeograph;
- 8 — InterCluster;
- 9 — DistributeAll;
- 10 — DistributeCenterLast;
- 11 — Kashida.

Источник: https://learn.microsoft.com/en-us/office/vba/api/publisher.pbparagraphalignmenttype

Это **COM semantic namespace**. Совпадение с wire value для 0/5..11 ещё не доказано.

## Fixture contract

Exact source PUB обязан содержать ровно один text shape с tag:

```text
PUB_ORACLE_ID = ALIGN_TARGET
```

Ни Shape.ID, ни Shape.Name не используются как единственный locator: они записываются только как observation.

## Case ID

```text
<family>--align-<value>--<writer>
```

Family:

- `explicit`
- `style`

Value:

- `0..11`

Writer:

- `current`
- `publisher2000`
- `publisher98`

Примеры:

```text
explicit--align-0--current
explicit--align-5--current
style--align-2--current
explicit--align-6--publisher2000
```

## Что фиксируется

До mutation:

- PageID;
- Shape.ID;
- Shape.Name;
- exact oracle tag;
- TextRange.Text;
- ParagraphFormat.Alignment.

После setter:

- setter `ok` или `rejected`;
- HRESULT/message при rejection;
- повторный in-memory alignment readback.

После SaveAs:

- writer family;
- output path;
- SHA-256;
- size.

После reopen:

- повторный поиск того же `ALIGN_TARGET`;
- semantic alignment readback;
- text/identity snapshot.

## Важный negative result

Если documented COM value отвергается конкретным fixture/build, adapter не падает как infrastructure failure.

В `paragraph-alignment.json` остаётся:

```text
setter.state = rejected
```

Это отдельное runtime observation. Оно не должно быть заменено предположением о binary mapping.

## Порядок controlled run

### Current explicit family

Сначала:

```text
0, 5, 6, 7, 8, 9, 10, 11
```

Values 1–4 уже имеют native Publisher 2019 explicit-path evidence и могут использоваться как controls, но не являются главным remaining gate.

### Current style family

На независимой style topology:

```text
2, 3, 4
```

Цель — не повторно доказать semantic enum, а локализовать carrier selection: explicit FDPP против STSH/default/formatting path.

### Conversion arms

Только после current raw attribution:

```text
publisher2000
publisher98
```

Каждый writer arm стартует с исходного exact fixture. Sequential SaveAs одного открытого Document не используется.

## Guardrails

- Setter success не доказывает FDPP.
- Reopen readback не доказывает byte equality.
- Значения 0/5..11 являются документированными COM enum values, но их late-Quill wire mapping остаётся experiment target.
- `publisher2000` и `publisher98` — conversion writers текущего Publisher.
- Старые no-Quill paragraph bytes не объединяются с этим namespace без отдельного evidence.
