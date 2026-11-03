# Review checklist

Run every check over every translated unit. **Error**: breaks the app or loses meaning; fix before apply.
**Warning**: likely wrong; fix it or list it for the user.

## Structure

| Check | Severity | Rule |
|---|---|---|
| missing | error | Every path in `expect` has a non-empty value, every plural category the language needs is present (`references/languages.md`). |
| specifiers | error | Same arguments with the same types as the source; reordering only with positional specifiers; `%#@name@` and `%arg` unchanged. A plural `one` form may drop the number only where `one` means exactly 1 (`references/formats.md`). |
| protected text | error | Brand terms, `keep` texts, URLs, Markdown links and `\n` count match the source. |
| extra plural form | warning | A category the language does not use (`few` in German). |
| whitespace | warning | Leading and trailing spaces match the source. |

## Language

| Check | Severity | Rule |
|---|---|---|
| untranslated | warning | Identical to the source while not in `keep`. Short words that really are the same (`OK`, `Wi-Fi`) go to `keep` after the user confirms. |
| wrong script | error | A non-Latin locale (ru, uk, el, ar, he, hi, th, ja, ko, zh) without any of its own script outside brand terms. |
| Latin leftovers | warning | A Latin word of 3+ letters in a non-Latin locale that is not a brand term or `keep` text. |
| Chinese script | error | Simplified characters in zh-Hant or Traditional in zh-Hans (这/這, 设/設, 视/視, 录/錄, 个/個), or the other region's vocabulary (视频 vs 影片, 软件 vs 軟體). |
| sense | error | The translation picks the wrong meaning of an ambiguous word (Record noun/verb, Free gratis/unrestricted, Match, Close, Share, Post, Archive). Check against the key name, comment, neighbouring keys and the glossary. |
| glossary | warning | A glossary term with a fixed translation for this locale appears in the source but not in the translation. |
| consistency | warning | The same source term is translated differently across units of one locale, or differs from the anchors (existing app vocabulary). |
| duplicates | warning | Different source strings of one group (`theme.light`, `theme.dark`, `theme.system`) got the same translation. |

## Register

| Check | Severity | Rule |
|---|---|---|
| register | warning | Pronouns, possessives and imperatives match the configured register (`du` vs `Sie`, `tu` vs `vous`, `ты` vs `вы`, `tú` vs `usted`, `je` vs `u`, `sen` vs `siz`, 你 vs 您, `kamu` vs `Anda`; ja です・ます vs plain endings; ko 해요 vs 합니다). Read every sentence, not only those with pronouns: a bare imperative carries the register too. |
| register mix | error | One locale uses two registers across its units. |
| gender | warning | Past-tense or adjective forms that assume the user's gender (ru `ты удалил`, he/ar imperatives) where a neutral phrasing exists. |

## Typography and length

| Check | Severity | Rule |
|---|---|---|
| punctuation | warning | Final punctuation follows the source: a period, question mark, colon or ellipsis stays (in the locale's form: `。`, `？`, `؟`, `;` for Greek, `…`), and a label without one does not gain one. |
| quotes | warning | Locale quotes: de „…“, fr « … », ru/uk «…», pl „…”, ja 「…」, zh-Hans “…”, zh-Hant 「…」. |
| spacing | warning | French no-break space before `: ; ? !` and inside « »; full-width punctuation after CJK text; Spanish `¿` `¡`. |
| casing | warning | English Title Case (`Save Changes`) becomes sentence case in fr, es, it, pt, nl, sv, da, nb, fi, pl, cs, ru, uk, tr; German capitalizes nouns only. |
| length | warning | A label of 25 characters or fewer that grows past 1.6x the source + 4 characters may truncate; offer a shorter wording. |

## Report

`RUN/review.md`: one table per locale with key, check, severity, current text and fix, followed by the units
sent back for retranslation and the warnings left for the user.
