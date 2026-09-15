А что если взять 128 lanes cpu и много pci 5.0 x16, поставить бифуркаторы и много мелких ssd? Что там по скоростям и ценам?

--

Да, **по сырой полосе это неожиданно жизнеспособная идея**. Но как замена RAM для CPU-inference есть неприятный подвох: SSD-массив можно сделать на **400–470 GB/s**, однако обычный `mmap()`/llama.cpp эту полосу почти наверняка не использует.

У PCIe 5.0 эффективный потолок примерно такой:

| Интерфейс   | Полоса в одну сторону |
| ----------- | --------------------: |
| PCIe 5.0 ×4 |           ~15.75 GB/s |
| ×16         |              ~63 GB/s |
| 128 lanes   |         **~504 GB/s** |

У EPYC SP5 все нужные линии действительно есть: например, Turin/EPYC 9005 даёт 128 PCIe Gen5 линий, а низший EPYC 9015 тоже имеет полный ×128, несмотря на всего 8 ядер. ([AMD][1])

### Вариант 32× NVMe

Берём восемь ×16 слотов и каждый делим:

```text
PCIe5 x16
 ├─ x4 SSD
 ├─ x4 SSD
 ├─ x4 SSD
 └─ x4 SSD

× 8 slots = 32 SSD
```

Пассивный ASUS Hyper M.2 X16 Gen5 как раз делает `x16 → 4×x4`, если motherboard умеет `x4/x4/x4/x4` bifurcation. Сейчас такие платы стоят примерно **€70 за штуку**, то есть восемь — всего ~€560. ([Geizhals.de][2])

Это намного разумнее, чем покупать PCIe-switch карты типа HighPoint по $1000–1500. HighPoint нужен, когда bifurcation нет или хочется 8 SSD на один ×16; его реальный массив уже показывал около **59.7 GB/s с одного ×16**. ([Tom's Hardware][3])

### На дешёвых 1TB Gen5

Например, 1TB Crucial T705 читает до **13.6 GB/s**. Samsung 9100 Pro — до **14.8 GB/s**. ([Tehnomarket][4])

Получается:

| SSD                | Количество | Теоретический aggregate read |
| ------------------ | ---------: | ---------------------------: |
| T705 13.6 GB/s     |          8 |                    ~109 GB/s |
|                    |         16 |                    ~218 GB/s |
|                    |         32 |                **~435 GB/s** |
| 9100 Pro 14.8 GB/s |          8 |                    ~118 GB/s |
|                    |         16 |                    ~237 GB/s |
|                    |         32 |                **~474 GB/s** |

То есть **32 мелких Gen5 SSD почти добивают весь 128-lane PCIe5 root complex**.

Иными словами, по последовательной полосе это уже почти уровень **12-канальной DDR5**. Для сравнения EPYC 9015 с 12×DDR5-6400 имеет официальные **614 GB/s memory bandwidth**. ([AMD][5])

---

## И по цене это выглядит чертовски заманчиво

В Сербии Samsung 9100 Pro 1TB сейчас встречается примерно за **28,090 RSD**, а Crucial T705 1TB — около **25–31.5k RSD**. ([eponuda.com][6])

32× Samsung:

`32 × 28,090 = 898,880 RSD`

То есть примерно **€7,670** по текущему курсу.

Плюс:

`8 × ~€70 bifurcation cards ≈ €560`

Итого грубо:

**~€8.2k за 32 TB NAND и теоретические ~474 GB/s read.**

Это действительно выглядит дёшево на фоне безумных текущих цен на DDR5-6400 RDIMM: один новый Micron 64GB RDIMM сейчас листится примерно в районе **€2.7–3k**, хотя серверная память сейчас вообще находится в крайне ненормальном ценовом состоянии. ([heise online][7])

### [Samsung 9100 PRO 2TB]()

*Цена није доступна*

### [Crucial T705 2TB]()

*Цена није доступна*

### [Corsair MP700 PRO 2TB]()

*Цена није доступна*

## Но теперь главный облом: это не 474 GB/s RAM

CPU не считает матмул непосредственно над NAND.

Получается:

```text
SSD
  ↓ PCIe DMA
DDR5
  ↓ CPU load
L2/L3
  ↓
CPU
```

То есть каждый байт веса сначала **записывается SSD-контроллером в RAM**, а потом **ещё раз считывается CPU из RAM**.

Если у тебя DDR5 subsystem на 600 GB/s, при непрерывном streaming возникает примерно:

```text
~300 GB/s SSD → RAM
+
~300 GB/s RAM → CPU
=
~600 GB/s DRAM traffic
```

То есть DRAM-контроллер всё равно становится потолком.

На твоём нынешнем 7702P вообще хуже:

**204.8 GB/s DDR4 theoretical**, поэтому даже 16 Gen5 SSD уже могут накачивать больше, чем его RAM способна принять и одновременно отдать CPU.

---

# Для GLM-5.3 можно оценить потолок

Full GLM-5.3 имеет около 39–40B active params/token.

При условных ~4.8 bit/weight:

`40B × 4.8 / 8 ≈ 24 GB/token`

Если волшебным образом читать веса непосредственно со всего массива:

**32×9100:**

`474 / 24 ≈ 19.8 tok/s`

**16×9100:**

`237 / 24 ≈ 9.9 tok/s`

**8×9100:**

`118 / 24 ≈ 4.9 tok/s`

И это только идеальный bandwidth roofline, без вычислений.

На первый взгляд получается совершенно интересно:

> ~€8k NAND-массив → потенциально около 20 t/s GLM-5.3.

Но реально будет заметно хуже.

### Причина №2 — latency

DRAM:

**~100 ns порядок величины.**

NVMe:

**десятки микросекунд**, то есть в сотни раз хуже.

Для большого последовательного чтения это не страшно. Но MoE делает примерно:

```text
layer N
 ↓
router
 ↓
выбрать experts 17, 51, 72...
 ↓
прочитать веса выбранных experts
 ↓
compute
 ↓
layer N+1
 ↓
router
 ...
```

И заранее ты не всегда знаешь, какие experts понадобятся следующему layer.

Если позволить Linux просто fault'ить страницы через `mmap`, получится скорее **катастрофа**, чем 400 GB/s.

---

# Чтобы идея заработала, нужен специальный inference engine

Я бы вообще **не делал RAID0 + mmap**.

Я бы разложил expert tensors по SSD и сделал примерно:

```text
router output
      ↓
io_uring O_DIRECT async reads
      ↓
несколько pinned staging buffers
      ↓
AVX compute текущего expert
      │
      └── одновременно prefetch следующих данных
```

Ещё лучше держать:

```text
Attention
Shared experts
часто используемые experts
             → DDR5

cold MoE experts
             → SSD array
```

То есть SSD должен быть не swap, а **explicit expert backing store**.

Можно даже статистически кешировать наиболее популярные experts в 192–384 GB дешёвой RAM, а остальные несколько сотен GB стримить.

Тогда NAND latency начинает скрываться вычислениями.

---

## И есть ещё интересная штука: batch помогает

Допустим восемь sequences выбрали одного и того же expert.

Вместо:

```text
load expert weights
compute token 1

load expert weights
compute token 2
...
```

можно:

```text
load expert ONCE from SSD

W × [token1 token2 ... token8]
```

И внезапно bandwidth NAND амортизируется на batch.

То есть такая машина была бы почти противоположностью CMP170HX:

**single stream:** посредственно;

**batch 8–32:** потенциально очень интересно.

---

### Сколько электричества

Тоже вполне нормально.

Samsung указывает для 1TB 9100 Pro около **7.6 W average при чтении**. ([Samsung Semiconductor Download][8])

32 штуки:

`32 × 7.6 ≈ 243 W`

Добавь bifurcation-карты/вентиляторы — пусть **~270–300 W storage subsystem**.

Это всё равно гораздо меньше 8×CMP170HX с их ~1.4–2 kW.

---

## Я бы попробовал не 32, а 16 SSD

Вот это, мне кажется, особенно разумный эксперимент:

```text
4 × PCIe5 x16
4 × ASUS Hyper M.2 Gen5
16 × 1TB 9100 Pro/T705

≈ 220–237 GB/s raw sequential
≈ 16 TB
```

SSD в Сербии:

**~400–450k RSD**, плюс около **€280** за carriers.

При этом это уже сравнимо по bandwidth с твоим **всем восьмиканальным DDR4-3200 на 7702P**.

А 32 диска удваивают цену, но CPU-инференс всё равно начинает упираться в DDR5 memory fabric и compute.

### Самое интересное

Я бы вообще попробовал Frankenstein:

```text
SP5
12-channel DDR5
192–384 GB дешёвой RAM
+
16× PCIe5 NVMe
+
твоя RTX PRO 6000 96GB
```

96 GB самых горячих tensors → **Blackwell VRAM**
192–384 GB hot expert/cache → **DDR5**
остальные ~200–300 GB weights → **striped NVMe**

Это потенциально намного рациональнее, чем **€20–30k+ за 768 GB свежих DDR5-6400 RDIMM**, особенно при нынешних ценах памяти.

Но чтобы оно реально «срало токенами», а не красиво показывало `fio 230 GB/s`, нужен **tensor-aware async expert streaming**, а не стандартный llama.cpp mmap. Вот это как раз интересный pet project.

[1]: https://www.amd.com/content/dam/amd/en/documents/epyc-technical-docs/user-guides/58462_amd-epyc-9005-tg-architecture-overview.pdf?utm_source=chatgpt.com "AMD EPYC™ 9005 PROCESSOR"
[2]: https://geizhals.de/asus-hyper-m-2-x16-gen5-card-90mc0cy0-m0eay0-a3064418.html?utm_source=chatgpt.com "ASUS Hyper M.2 X16 Gen5 Card ab € 69,90 (2026) | Preisvergleich Geizhals Deutschland"
[3]: https://www.tomshardware.com/pc-components/storage/highpoint-rocket-1608a-add-in-card-review?utm_source=chatgpt.com "HighPoint Rocket 1608A add-in card review: More drives, more power | Tom's Hardware"
[4]: https://www.technomarket.rs/crucial-t705-1000gb-1tb-nvme-pcie-gen-5-m-2-2280?utm_source=chatgpt.com "CRUCIAL T705 1000GB [1TB] NVMe PCIe Gen.5 M.2 2280 | TEHNOMARKET"
[5]: https://www.amd.com/en/products/processors/server/epyc/9005-series/amd-epyc-9015.html?utm_source=chatgpt.com "AMD EPYC™ 9015"
[6]: https://www.eponuda.com/ssd-diskovi-cene/samsung-1tb-m-2-nvme-mz-vap1t0bw-9100-pro-series-cena-34832212?utm_source=chatgpt.com "Samsung 1TB M.2 nvme MZ-VAP1T0BW 9100 pro series | Eponuda.com"
[7]: https://preisvergleich.heise.de/micron-rdimm-64gb-mtc40f2046s1rc64bh1-a3871706.html?utm_source=chatgpt.com "Micron RDIMM 64GB, DDR5-6400, CL52-52-52, 2RX4, reg ECC (MTC40F2046S1RC64BH1) ab € 2691,97 (2026) | heise preisvergleich Deutschland"
[8]: https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_9100_PRO_with_Heatsink_Datasheet_Rev.2.0_10149814993597.pdf?utm_source=chatgpt.com "Data Sheet  
SAMSUNG PROPRIETARY

\# TECHNICAL SPEC"

--

А есть ssd 5.0 но меньше 1 тб? Точнее дешевле

--

Да, но тут рынок неприятно устроен: **нормальные быстрые PCIe 5.0 ×4 SSD практически начинаются с 1 TB**. 500/512 GB сейчас в основном Gen4. Enterprise Gen5 бывают с меньшими ёмкостями около 800 GB, но они обычно **дороже**, а не дешевле.

Для твоей идеи важнее считать **RSD за GB/s**, а не RSD за TB.

Сейчас в Сербии интересны, например:

* **Kioxia Exceria Plus G4 1TB** — Gen5×4, ~10 GB/s read, **19 990 RSD**. ([eponuda.com][1])
* **Samsung 9100 Pro 1TB** — ~14.7 GB/s read, **27 899 RSD**. ([eponuda.com][2])
* **Crucial P510 1TB** — ~11 GB/s, **26 000 RSD**. ([eponuda.com][3])

### [Crucial P510 1TB PCIe 5.0]()

*Цена није доступна*

### [Samsung 990 EVO 1TB]()

*Цена није доступна*

Причём дешёвая Kioxia выглядит неплохо по абсолютной цене, но Samsung всё равно чуть лучше **по цене полосы**:

`Kioxia: 19,990 / 10 ≈ 1,999 RSD за 1 GB/s`

`9100 Pro: 27,899 / 14.7 ≈ 1,898 RSD за 1 GB/s`

То есть более дорогой Samsung фактически **дешевле по bandwidth**.

Для массива:

|                       | 32× Kioxia 1TB | 32× Samsung 9100 1TB |
| --------------------- | -------------: | -------------------: |
| Цена SSD              |      ~640k RSD |            ~893k RSD |
| Ёмкость               |          32 TB |                32 TB |
| advertised read       |      ~320 GB/s |        **~470 GB/s** |
| цена / aggregate GB/s |      ~2.0k RSD |        **~1.9k RSD** |

И это меняет мою предыдущую оценку: если цель именно **максимальная streaming bandwidth**, дешёвые маленькие SSD не обязательно выгоднее.

500GB Gen4 сейчас можно купить примерно за **10–14k RSD**, но они дают только ~4–6 GB/s. Например, ADATA Legend 860 500GB в Сербии встречается примерно за 12–14k и заявляет 6 GB/s. ([Uspon][4]) Получается около `~2,000 RSD/(GB/s)` — то есть почти та же экономика, но ты тратишь PCIe lanes вдвое менее эффективно.

А это в твоём проекте критично:

```text
1 × PCIe5 x4 → 9100 Pro → ~14.7 GB/s

тот же x4 слот → Gen4 SSD → ~5–7 GB/s
```

У тебя ограничивающий ресурс — **128 PCIe lanes**, а не ёмкость NAND.

Поэтому я бы вообще забил на объём и искал **самый дешёвый SSD с 12–15 GB/s sequential read**. Даже если он 1 TB, лишние десятки терабайт просто остаются бонусом.

Ещё потенциально интереснее — искать **OEM/used Gen5 drives без красивой retail-наценки**. Если найти 1TB Gen5×4 с ~12–14 GB/s в районе €100–150, тогда массив становится реально безумно привлекательным по €/GB/s.

[1]: https://www.eponuda.com/ssd-diskovi-cene/kioxia-ssd-m-2-2280-1tb-exceria-plus-g4-pcie-5-0-nvme-cena-34153617?utm_source=chatgpt.com "KIOXIA SSD M.2 (2280) 1TB Exceria Plus G4 (PCIe 5.0/NVMe) | Eponuda.com"
[2]: https://www.eponuda.com/ssd-diskovi-cene/samsung-1tb-m-2-nvme-mz-vap1t0bw-9100-pro-series-cena-34832212?utm_source=chatgpt.com "Samsung 1TB M.2 nvme MZ-VAP1T0BW 9100 pro series | Eponuda.com"
[3]: https://www.eponuda.com/ssd-diskovi-cene/crucial-p510-1tb-pcie-gen5-nvme-2280-m-2-ssd-ct1000p510ssd8-cena-36579768?utm_source=chatgpt.com "Crucial P510 1TB pcie Gen5 nvme 2280 M.2 ssd ( CT1000P510SSD8 ) | Eponuda.com"
[4]: https://www.uspon.rs/racunarske-komponente/hard-diskovi/m-2?utm_source=chatgpt.com "M.2 NVME - USPON DOO"

--

А может можно fpga зарядить?

--

Да — **и FPGA здесь как раз может исправить самое мерзкое место схемы “NVMe как память”**: убрать промежуточный прогон весов через системную DDR и сразу делать `NVMe → FPGA → dequant/Q4 matvec`.

AMD это даже официально поддерживает: Alveo умеет PCIe P2P с NVMe, то есть SSD может DMA-шить прямо в память FPGA без staging через host RAM. ([Xilinx][1])

Но есть один фундаментальный предел.

Для full GLM-5.3 Q4 мы грубо имеем около **24 GB активных весов на сгенерированный токен**. Поэтому для настоящих:

* 10 t/s нужно ~240 GB/s чтения весов;
* 20 t/s → ~480 GB/s;
* 40 t/s → ~960 GB/s.

Одна FPGA-карта такой поток с SSD не примет.

### Самая интересная FPGA сейчас — Alveo V80

У неё:

* **32 GB HBM2e**
* **819–820 GB/s HBM**
* 10,848 DSP58
* PCIe Gen5
* отдельные MCIO: `2×x4 + 1×x8 PCIe Gen5`
* MCIO прямо заявлены AMD для **direct connection to NVMe storage**
* до 190 W. ([AMD][2])

То есть можно физически построить:

```text
4x Gen5 NVMe
   │
   │ ~50-60 GB/s
   ▼
┌──────────── V80 ────────────┐
│ PCIe/NVMe DMA               │
│        ↓                    │
│ 32 GB HBM @ 820 GB/s        │
│        ↓                    │
│ Q4 unpack + GEMV + routing  │
└─────────────────────────────┘
             ↓
       hidden state
```

И CPU занимается практически только orchestration/tokenizer.

### FPGA по compute неожиданно подходит

На V80 физически 10,848 DSP58. Недавняя работа непосредственно на V80 показала работающие INT4 GEMM kernels; у DSP58 нет специального удвоения производительности INT4 относительно INT8, зато INT4 вдвое уменьшает memory traffic. Авторы оценивают масштабирование их реализации примерно до **~1.7 TMAC/s** при достаточно широком распараллеливании, хотя это именно extrapolated upper bound, а не готовый GLM kernel. ([MDPI][3])

А GLM требует примерно:

`40B MAC/token`

Следовательно:

```text
10 t/s = 0.40 TMAC/s
20 t/s = 0.80 TMAC/s
30 t/s = 1.20 TMAC/s
```

То есть **арифметически V80 потенциально хватает**.

Проблема снова storage bandwidth.

---

## А вот 8 FPGA уже становятся очень интересными

Представь, что модель не PP-шардим слоями, как на CMP170HX, а **раскидываем MoE experts по FPGA**.

```text
             router
               │
     ┌─────────┼─────────┐
     ▼         ▼         ▼
 FPGA0       FPGA1 ... FPGA7
 experts     experts     experts
   │           │           │
4xSSD       4xSSD       4xSSD
```

Каждая FPGA одновременно считает выбранные на ней experts.

Если каждой дать примерно:

`~60 GB/s NVMe`

то восемь дают:

**~480 GB/s storage bandwidth.**

А это как раз тот порядок, который соответствует:

`480 GB/s / ~24 GB/token ≈ 20 tokens/s`

без какого-либо повторного чтения через DDR.

Но теперь в отличие от `CMP170HX PP8` **все восемь устройств могут работать одновременно над одним слоем одного запроса**, потому что это expert parallelism, а не pipeline parallelism.

Hidden-state, который надо гонять между картами, на порядки меньше самих expert weights.

И тут V80 ещё веселее: у неё есть **4×200G networking**, т.е. до ~800 Gbit/s сетевой connectivity на карту. ([AMD][2])

Получается почти самодельный MoE appliance.

---

## Но цена убивает

V80 сейчас имеет официальный MSRP **$9,495 за штуку**. ([AMD][2])

Восемь:

**~$76k только FPGA.**

За такие деньги вся затея теряет экономический смысл.

Старый **Alveo U55C** чуть интереснее:

* 16 GB HBM2
* 460 GB/s
* 9,024 DSP
* ~115 W
* PCIe Gen4
* тоже ориентирован в том числе на computational storage. ([AMD][4])

Но даже used U55C сейчас вижу примерно **$3.5–5k/card**. ([eBay][5])

Опять ~$30k за восемь.

---

## Где FPGA действительно имеет смысл

Я бы **не покупал восемь дорогих FPGA**.

Гораздо прикольнее FPGA использовать только как **storage front-end**:

```text
             16/32 NVMe
                 │
          PCIe switches
                 │
               FPGA
       ┌─────────┴─────────┐
       │ router            │
       │ async prefetch    │
       │ Q4 unpack         │
       │ expert cache mgr  │
       └─────────┬─────────┘
                 │
         CPU / Blackwell
```

Она может:

1. Получить результат MoE-router.
2. Уже знать, какие expert tensors понадобятся.
3. Запустить десятки NVMe DMA одновременно.
4. Собрать куски.
5. Распаковать Q4.
6. Возможно сразу сделать часть GEMV.
7. Не трогать системную RAM вообще.

AMD прямо документирует `O_DIRECT` NVMe → P2P-buffer FPGA, именно без копирования через host memory. ([Xilinx][1])

Это уже не теоретическая возможность.

### Причём HBM FPGA можно использовать как L4 cache

Допустим V80:

```text
32 GB HBM
```

У GLM active set одного токена ~24 GB Q4.

Ты можешь держать:

* shared expert;
* attention;
* routing;
* наиболее часто встречающиеся experts;

в HBM.

Остальное fetching с SSD.

Если добиться хотя бы 50% hit rate, необходимая NVMe bandwidth падает условно:

`480 → ~240 GB/s для 20 t/s`.

При 75% hits:

`→ ~120 GB/s`.

И вот тогда устройство становится гораздо более реалистичным.

---

### Но есть ещё более интересный вариант конкретно у тебя

У тебя уже есть **RTX PRO 6000 Blackwell 96 GB**.

Поэтому я бы Frankenstein строил так:

```text
                   GLM-5.3 Q4 ~455 GB
                           │
          ┌────────────────┼───────────────┐
          ▼                ▼               ▼
      96 GB VRAM       200-300 GB RAM     NVMe pool
      hottest             warm              cold
      tensors            experts           experts
          │                │                 │
          └────────── FPGA prefetch ─────────┘
                           │
                        compute
```

Blackwell держит attention/shared experts/hottest MoE experts.

DDR держит второй tier.

NVMe — cold experts.

FPGA предсказывает/маршрутизирует и асинхронно тащит следующую порцию ещё пока GPU считает текущую.

**Вот это потенциально намного интереснее, чем покупать 8×CMP170HX.**

Потому что у тебя задача превращается не в «как заставить восемь старых GPU общаться», а в **как максимально спрятать NAND latency за MoE compute**.

И GLM как MoE специально удобен для такого безумия: на каждый токен тебе **не нужны все 455 GB весов**, нужны только выбранные experts.

Если делать это как pet project, я бы даже сначала **вообще не покупал FPGA**: реализовал prototype `io_uring + O_DIRECT + pinned buffers + CUDA` на твоём нынешнем 7702P/RTX Pro 6000 и замерил achievable expert-cache hit rate. Если cache hit окажется условно 70–90%, тогда FPGA действительно может превратить эту архитектуру в очень быстрый inference appliance.

[1]: https://xilinx.github.io/XRT/2022.2/html/p2p.html?utm_source=chatgpt.com "PCIe Peer-to-Peer (P2P) — XRT 2022.2 documentation"
[2]: https://www.amd.com/en/products/accelerators/alveo/v80/a-v80-p64g-pq-g.html?utm_source=chatgpt.com "AMD Alveo™ V80 Compute Accelerator Card"
[3]: https://www.mdpi.com/2079-9292/15/14/3093?utm_source=chatgpt.com "Hardware-Validated HLS Engines and Design-Time HBM Partitioning for AI Inference on AMD Alveo V80"
[4]: https://www.amd.com/en/products/accelerators/alveo/u55c/a-u55c-p00g-pq-g.html?utm_source=chatgpt.com "AMD Alveo™ U55C High Performance Compute Card"
[5]: https://www.ebay.com/itm/397875595152?utm_source=chatgpt.com "A-U55C-P00G-PQ-G AMD Alveo U55C 16GB HBM2 PCI-E 2xQSFP28 FPGA Accelerator Card | eBay"
