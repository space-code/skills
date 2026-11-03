# Languages

Per-locale rules for translation and review. The register defaults are starting points for the table the
user confirms in step 2; the user's choice in the config always wins.

## Register defaults

| Locale | Options (register: form) | Consumer | Business |
|---|---|---|---|
| de | informal: `du` · formal: `Sie` | informal | formal |
| fr | informal: `tu` · formal: `vous` | formal | formal |
| es | informal: `tú` · formal: `usted` | informal | formal |
| es-MX, es-419 | informal: `tú` · formal: `usted` | informal | formal |
| it | informal: `tu` · formal: `Lei` | informal | formal |
| pt-BR | informal: `você` · formal: `o senhor / a senhora` | informal | informal |
| pt-PT | informal: `tu` · formal: `impersonal / você` | formal | formal |
| nl | informal: `je / jij` · formal: `u` | informal | formal |
| sv, da, nb | informal: `du` | informal | informal |
| fi | informal: `sinä` · formal: `te` | informal | informal |
| pl | informal: `ty` · formal: `Pan / Pani, impersonal` | informal | formal |
| cs, sk | informal: `ty` · formal: `vy` | formal | formal |
| hu | informal: `te` · formal: `Ön` | informal | formal |
| ro | informal: `tu` · formal: `dumneavoastră` | informal | formal |
| el | informal: `εσύ` · formal: `εσείς` | formal | formal |
| tr | informal: `sen` · formal: `siz` | formal | formal |
| ru | informal: `ты` · formal: `вы` | formal | formal |
| uk | informal: `ти` · formal: `ви` | formal | formal |
| ja | informal: `plain (だ・である)` · formal: `です・ます` | formal | formal |
| ko | informal: `반말` · polite: `해요체` · formal: `합니다체` | polite | formal |
| zh-Hans, zh-Hant | informal: `你` · formal: `您` | informal | formal |
| hi | informal: `तुम` · formal: `आप` | formal | formal |
| id | informal: `kamu` · formal: `Anda` | formal | formal |
| ms | informal: `awak / kamu` · formal: `anda` | formal | formal |
| vi | neutral: `bạn` | neutral | neutral |
| th | neutral: `คุณ, no gendered particles` | neutral | neutral |
| ar | neutral: `no T-V distinction` | neutral | neutral |
| he | neutral: `no T-V distinction` | neutral | neutral |

Locales not listed: ask the user for the register and describe it in `app.tone`.

How a register shows up beyond the pronoun:

* **Imperatives follow the register**: de `Tippe` / `Tippen Sie`, fr `Appuie` / `Appuyez`, ru `Нажми` /
  `Нажмите`, es `Toca` / `Toque`, it `Tocca` / `Tocchi`, nl `Tik` / `Tikt u`, tr `Dokun` / `Dokunun`.
* **Buttons and menu items** are often register-free: de and nl use the infinitive (`Speichern`,
  `Opslaan`), fr the infinitive (`Enregistrer`), ru the infinitive or noun (`Сохранить`), ja/zh/ko a noun or
  verb stem (`保存`, `저장`). Use those forms for buttons in every register.
* **Possessives** carry the register too: `dein/Ihr`, `ton/votre`, `твой/ваш`, `tu/su`, `jouw/uw`.
* ru, uk: `вы`/`ви` is written lowercase in UI text, not `Вы`.
* de: `Sie`, `Ihnen`, `Ihr` are always capitalized; `du`, `dein` lowercase.

## Per-language notes

### German (de)
Plurals: one, other. Quotes „…“, nested ‚…‘. Text is about 30% longer than English; prefer short compound
nouns and infinitive buttons. Nouns are capitalized, everything else sentence case. Avoid gender stars
(`Nutzer*innen`) unless the app already uses them; rephrase (`Alle, die …`).

### French (fr)
Plurals: one, other (`many` optional: exact millions and compact forms, `1 000 000 de fichiers`). Note that
0 and 1 both take `one`. Narrow no-break space (U+202F) or no-break space (U+00A0) before `: ; ? !` and inside « … ».
Sentence case. Text grows about 20%.

### Spanish (es, es-MX, es-419)
Plurals: one, other. Questions and exclamations open with `¿` and `¡`. Sentence case. es-419 and es-MX avoid
Spain-only words (`ordenador` → `computadora`, `móvil` → `celular`) and use `ustedes` for plural "you".

### Italian (it)
Plurals: one, other. Sentence case. Formal `Lei`, `Suo`, `La` are capitalized inside sentences.

### Portuguese (pt-BR, pt-PT)
Plurals: one, other; in pt-BR 0 also takes `one` (`0 arquivo`). pt-BR addresses the user with `você`; pt-PT prefers impersonal or third-person forms
(`Introduza`, `Toque`) and its own vocabulary (`ecrã` vs pt-BR `tela`, `ficheiro` vs `arquivo`). Never reuse
one variant for the other.

### Dutch (nl)
Plurals: one, other. `u` and `uw` lowercase. Sentence case.

### Swedish, Danish, Norwegian Bokmål, Finnish (sv, da, nb, fi)
Plurals: one, other. `du` / `sinä` everywhere. Sentence case. Finnish grows a lot (up to 40%) and inflects
nouns, so avoid building sentences from fragments.

### Polish (pl)
Plurals: one, few, many, other (`1 plik`, `2 pliki`, `5 plików`). Formal style often uses impersonal verbs
(`Wprowadź` informal, `Proszę wprowadzić` formal). Sentence case. Quotes „…”.

### Czech, Slovak (cs, sk)
Plurals: one, few, many, other (`many` is for fractions). `vy` style. Quotes „…“.

### Hungarian (hu)
Plurals: one, other, but nouns after a number stay singular (`5 fájl`). Formal `Ön` capitalized.

### Romanian (ro)
Plurals: one, few, other (`20 de fișiere` takes `de` from 20 up). Use ș and ț with comma below, not cedilla.

### Greek (el)
Plurals: one, other. The question mark is `;` (U+037E). Sentence case; uppercase text drops accents.

### Turkish (tr)
Plurals: one, other, but nouns after a number stay singular (`5 dosya`). Dotted and dotless i (`i/İ`,
`ı/I`) must be right in uppercase strings.

### Russian, Ukrainian (ru, uk)
Plurals: one, few, many, other (`1 файл`, `2 файла`, `5 файлов`, `1,5 файла`). Quotes «…», nested „…“.
Sentence case. Use `ё` consistently or not at all (match the existing catalog). Text grows about 15%. Verbs in
the past tense have gender (`Вы удалили` is fine, `Ты удалил` is not neutral); rephrase with nouns or
impersonal forms (`Файл удалён`).

### Arabic (ar)
Plurals: zero, one, two, few, many, other; all six are required. RTL; keep specifiers and Latin brand terms as
they are, the runtime handles direction. Punctuation `،` `؛` `؟`. Avoid gendered imperatives where you can
(use verbal nouns: `الحفظ`), otherwise masculine is the convention.

### Hebrew (he)
Plurals: one, two, other (`many` optional). RTL. Imperatives are gendered: prefer infinitives for buttons
(`לשמור`) and plural or impersonal forms in sentences.

### Hindi (hi)
Plurals: one, other; 0 also takes `one`. `आप` with matching verb forms (`करें`). Common English tech words (`ऐप`, `लॉग इन`) are
fine in Devanagari script.

### Japanese (ja)
Plurals: other only. です・ます in sentences; buttons and labels are nouns or verb stems (`保存`, `削除`),
not polite sentences. Full-width punctuation `。、！？「」`; no spaces between words; no trailing `。` on
labels. Katakana loanwords are normal (`アカウント`). Counters matter (`3件`, `3個`, `3枚`).

### Korean (ko)
Plurals: other only. 해요체 (`저장했어요`) or 합니다체 (`저장했습니다`) for sentences, nouns for buttons
(`저장`). Spaces between words (띄어쓰기). Particles depend on the preceding word (`을/를`, `이/가`); with a
variable before a particle use both (`%@을(를)`) or rephrase.

### Chinese (zh-Hans, zh-Hant)
Plurals: other only. zh-Hans uses Simplified characters and mainland vocabulary (`视频`, `软件`, `信息`);
zh-Hant uses Traditional characters and Taiwan vocabulary (`影片`, `軟體`, `訊息`). Never convert one into
the other character by character. Full-width punctuation `，。！？：；`, quotes `“…”` (zh-Hans) and `「…」`
(zh-Hant). No spaces between Chinese characters; a space between Chinese and Latin text is optional but must be
consistent.

### Thai (th)
Plurals: other only. No spaces between words, spaces between phrases. Leave out the gendered politeness
particles `ครับ` / `ค่ะ`.

### Vietnamese, Indonesian, Malay (vi, id, ms)
Plurals: other only. vi addresses the user with `bạn`. id `Anda` capitalized; ms `anda`.

## Plural categories at a glance

| Categories | Locales |
|---|---|
| other | ja, ko, zh-Hans, zh-Hant, th, vi, id, ms |
| one, other | en, de, nl, sv, da, nb, fi, it, es, pt, fr, el, hu, tr, hi, ca, bg, et |
| one, few, other | ro, hr, sr, bs |
| one, two, few, other | sl |
| one, few, many, other | ru, uk, be, pl, cs, sk, lt |
| zero, one, other | lv |
| one, two, other | he |
| zero, one, two, few, many, other | ar |

When the source has an explicit `zero` form ("No items"), every locale gets a `zero` form too, even where the
language has no `zero` category: Apple uses it for the number 0. `many` is optional for fr, es, it, pt and
ca.
