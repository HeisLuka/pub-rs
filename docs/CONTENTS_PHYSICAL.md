# Физический фундамент Contents

Эта страница описывает только те свойства физического слоя Contents, которые уже имеют прямое подтверждение. Семантические имена объектов и полей сюда не переносятся автоматически.

## Семейства

Подтверждены два точных четырёхбайтовых маркера начала потока:

- `E8 AC 22 00` — бинарное семейство 0x22;
- `E8 AC 2C 00` — бинарное семейство 0x2C.

Это **не** точные номера маркетинговых версий Publisher.

Контролируемый перебор третьего байта на валидном CFB показал, что текущий детектор libmspub принимает только `0x22` и `0x2C`, а изменение других байтов маркера приводит к отказу. Для `pub-rs` это используется только как дополнительная проверка; основное правило проекта — не выводить точную версию из одного family marker.

Основание: Canonical Claim #3, EXP-ORACLE-02.

## Ревизия сериализации Contents

Подтверждено, что little-endian поле `Contents[12..13]` является ревизией целевой сериализации для проверенных structured PUB.

Наблюдаемые подтверждённые значения:

- Publisher 2002: `0x000E`;
- Publisher 2003: `0x0013`;
- Publisher 2007: `0x0015`;
- Publisher 2010: `0x0018`;
- Publisher 2013: `0x001A`;
- Office16/365: также `0x001A`.

Старое семейство 0x22 тоже хранит family-scoped secondary revision в этих двух байтах, например `0x0268` для проверенного Publisher 98 и `0x02CD` для проверенного Publisher 2000.

Критическое ограничение: serialization revision **не равна маркетинговой/producer version**. В частности, `0x001A` используется как минимум Publisher 2013 и Office16/365.

Основание: Canonical Claim PUB-C-120, version fixture lattice и контролируемые 2007→2010 сравнения.

## Указатель trailer в 0x2C

Для проверенного позднего корпуса family 0x2C little-endian `u32` по `Contents+0x1A` указывает на начало trailer.

Подтверждение не основано на одном исходнике:

- directory-authoritative census прошёл по 19 поздним Apache POI PUB через этот физический указатель;
- прямой собственный разбор `Sample.pub`: размер Contents 11 490, trailer offset 9 578, trailer length 1 912, 45 chunk references;
- точный PRONOM Publisher 2002: размер Contents 5 544, trailer offset 4 230, 24 chunk references.

Код обязан проверять, что значение указателя попадает внутрь потока, прежде чем его разыменовывать.

Это правило **только для 0x2C**. В подтверждённом 0x22 trailer pointer расположен по `Contents+0x16`.

Основание: Canonical Claim PUB-C-121, OBS-029A, OBS-006B и точный PRONOM Publisher 2002.

## Корень trailer в 0x2C

Canonical Claim PUB-C-124 закрывает следующий физический слой после pointer по `Contents+0x1A`. В пяти напрямую проверенных 0x2C PUB (Publisher 2002, 2003, 2007, 2010 и 2013-class):

```text
u32 declared_trailer_length
01:20 <u32>
02:20 <u32>
03:90 <directory>
```

Наблюдённые отношения:

- `trailer_offset + declared_trailer_length == Contents.len()`;
- root `0x01` равен фактическому числу directory slots;
- root `0x02` равен maximum ordinal = `slot_count - 1`;
- root `0x03/0x90` содержит ровно позиционный directory;
- в пяти проверенных файлах три root-блока полностью заполняют declared trailer.

В коде эти отношения разделены на **physical grammar** и **observed invariants**. `parse_confirmed_0x2c_trailer_root` требует exact id/type трёх подтверждённых roots и проверяет declared range, но не делает равенства count/max-ordinal универсальными условиями успешного parse. Их можно проверить отдельными методами `observed_slot_count_matches_directory` и `observed_max_ordinal_matches_directory`.

Если новый вариант содержит байты после трёх известных roots внутри declared trailer, parser не угадывает их грамматику и не выбрасывает: диапазон сохраняется как `trailing_source: RawSpan`.

Основание: PUB-C-124, OBS-RS-001.

## Минимальная физическая грамматика блоков

На текущем этапе в общий wire-parser допускаются только четыре подтверждённых типа:

- `0x20`: после `id:u8, type:u8` хранится little-endian `u32`;
- `0x78`: пустой DUMMY, физически только два байта `id/type`;
- `0x88`: container с little-endian `u32 declared_length`;
- `0x90`: container с той же физической схемой длины.

Для `0x88` и `0x90` значение `declared_length` включает собственные 4 байта поля длины. Поэтому полный физический размер блока равен `2 + declared_length`, а содержимое после поля длины занимает `declared_length - 4` байт.

Прямые проверки:

- native 2002/2003 trailer содержит `01 20 <u32>`, `02 20 <u32>`, `03 90 <length...>`;
- DUMMY slot — `00 78`;
- occupied slot — `00 88 <length...>`;
- реальные 0x8A records из OBS-030 содержат вложенные `0x88/0x90`, границы которых точно замыкаются по этому правилу.

`pub-rs` намеренно отклоняет остальные block type на этом уровне, пока для них нет отдельного foundation-доказательства.

Основание: Canonical Claim PUB-C-122, OBS-OPL-EPOCH-01, OBS-029A, OBS-030.

### Bounded parsing

Вложенные блоки должны читаться курсором, ограниченным диапазоном родителя. Такой курсор сохраняет абсолютные offsets относительно исходного `Contents`, но не позволяет дочернему блоку выйти за `RawSpan` родителя.

Ошибка разбора подтверждённого блока не сдвигает исходный курсор: чтение выполняется транзакционно на копии курсора и фиксируется только при успехе.

## Что подтверждено для нативных 0x2C Publisher 2002/2003

На точных PRONOM-файлах подтверждено:

- каталог объектов является разреженной позиционной таблицей;
- номер позиции каталога является `seqNum`;
- пустой слот в этих файлах кодируется байтами `00 78`;
- занятый слот начинается как `00 88 ...`;
- отсутствующие позиции сохраняются явно;
- внутри активного диапазона могут существовать дырки;
- занятый слот не хранит отдельный `seqNum`.

Основание: Canonical Claims #94 и #98, OBS-OPL-EPOCH-01.

### Представление directory в коде

`Contents0x2cDirectory` хранит слоты в исходном порядке. Позиция элемента в `slots` и есть подтверждённый `seqNum`; отдельное поле seqNum внутри occupied slot не создаётся.

На текущем evidence gate распознаются только:

- `id=0, type=0x78` → `Empty`;
- `id=0, type=0x88` → `Occupied`.

Даже другие уже известные wire-типы, например `0x20`, в позиции directory slot отклоняются: знание физической грамматики блока не означает, что этот block type допустим именно как слот каталога.

Directory разбирается только внутри переданного `RawSpan`. Повреждённый occupied container не может выйти за границы этого диапазона.

### Chunk references внутри occupied slot

Canonical Claim PUB-C-123 фиксирует semantic mapping для проверенного later-0x2C corpus:

- field `0x02` → raw chunk type;
- field `0x04` → физический offset chunk внутри `Contents`;
- field `0x05` → parent seqNum, если поле присутствует;
- seqNum самой ссылки остаётся ordinal позиции directory.

После прямого бинарного прогона OBS-RS-001 wire-схема этих references закрыта отдельным Canonical Claim PUB-C-125. На **234/234** occupied slots пяти файлов:

- `field 0x02` всегда имеет `type 0x18` и 2-byte payload;
- `field 0x04` всегда имеет `type 0xB8` и 4-byte payload;
- присутствующий `field 0x05` всегда имеет `type 0x68` и 4-byte payload;
- `field 0x06` всегда имеет `type 0x10` и 2-byte payload;
- optional presence fields используют `type 0x08` без payload;
- optional `field 0x0B` использует `type 0x18`.

В каждом из пяти файлов один корневой occupied reference не имеет field `0x05`; отсутствие parent поэтому не является malformed-состоянием.

Общий `parse_confirmed_block` по-прежнему не расширяется этими типами глобально: PUB-C-125 подтверждает их именно в **chunk-reference context**. Для occupied reference используется отдельный context parser, который:

- переиспользует глобально подтверждённые wire-types, когда они встречаются;
- дополнительно допускает только `0x08/0x10/0x18/0x68/0xB8` по PUB-C-125;
- сохраняет каждый физически разобранный field в `fields`;
- поднимает `0x02` только из фактической пары `id0x02/type0x18` в `ObservedU16Field`;
- поднимает `0x04` только из `id0x04/type0xB8` в `ObservedU32Field`;
- поднимает `0x05` только из `id0x05/type0x68` в `ObservedU32Field`;
- не схлопывает дубликаты и не синтезирует отсутствующий parent;
- останавливается на новом неподтверждённом wire-type вместо угадывания его длины.

Основание: PUB-C-123, PUB-C-125, OBS-RS-001.

### Ограничение

Эти наблюдения подтверждены для нативных Publisher 2002/2003. Нельзя без отдельной проверки превращать конкретный префикс `00 78` или детали вложенного контейнера в универсальную грамматику всех поздних 0x2C-файлов.

## Что пока не допускается в фундаментальный парсер

Пока не кодируются как универсальная истина:

- название trailer directory как «OPL Array»;
- политика повторного использования пустых слотов;
- универсальная таблица смыслов block type только по исходному коду libmspub;
- семантическое имя неизвестного chunk type;
- предположение, что физическая длина между соседними chunk offsets всегда равна внутренней логической длине.

## Текущий безопасный код

`pub-contents` содержит:

- точное определение family marker;
- `ContentsPreamble` с family и serialization revision;
- отдельный `Contents0x2cHeader` с проверенным trailer offset;
- `Contents0x2cTrailerRoot` для declared trailer range, roots `01:20` / `02:20` / `03:90` и вложенного positional directory;
- отдельный `RawSpan` для family marker, revision и trailer pointer;
- обязательную проверку границ trailer pointer;
- `ContentsCursor`, который не читает за границы и умеет ограничиваться диапазоном родителя;
- минимальный wire-parser только для подтверждённых block types `0x20/0x78/0x88/0x90`;
- транзакционное чтение блока: ошибка не теряет исходную позицию;
- `Contents0x2cDirectory` с позиционными `Empty/Occupied` slots без синтетического wire-поля seqNum;
- evidence-gated `Contents0x2cChunkReference` с реальной wire-схемой PUB-C-125 для mapping `0x02/0x04/0x05`;
- context-specific разбор reference wire-types `0x08/0x10/0x18/0x68/0xB8` без глобального обобщения;
- сохранение всех физически разобранных reference fields и всех дублирующихся semantic observations;
- точный `RawSpan` для каждого slot, reference field и его значения;
- точный `RawSpan` для блока, его значения/длины и содержимого container;
- никакого вычисления маркетинговой версии Publisher.

Следующий физический шаг должен добавляться только после отдельного подтверждения конкретной грамматики trailer/container.
