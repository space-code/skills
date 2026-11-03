---
name: app-localization
description: Localizes the UI strings of an Apple app (String Catalogs .xcstrings, .strings, .stringsdict, InfoPlist) into other languages with the right formality register (`du`/`Sie`, `tu`/`vous`, `ты`/`вы`, `です・ます`, `해요체`), plural forms and typography per language. Trigger on "localize the app", "translate strings", "add a language", "xcstrings", "локализуй приложение" or "переведи строки".
---

# App Localization

You translate the user-visible strings of an Apple app into a set of locales. Each locale gets one
**register** (how the app addresses the user) for the whole app, the plural forms its grammar needs and its
own typography. You edit the catalogs yourself and review every translation against a fixed checklist
instead of asking the user to proof-read each language.

`SKILL_DIR` below is the folder that holds this file.

## Terms

* **Catalog**: one strings resource: a `.xcstrings` file, or one table (`Localizable.strings`,
  `InfoPlist.strings`, `Localizable.stringsdict`) across its `*.lproj` folders.
* **Unit**: one key of one catalog with its source text, comment and plural/device variants.
* **Register**: the formality level of a locale (`formal`, `informal`, `polite`, `neutral`) and its concrete
  form (`Sie`, `вы`, `해요체`). Defaults per app type are in `references/languages.md`.
* **Brand term**: text that stays exactly as written in every language (app name, product tiers, iCloud).
* **Glossary**: ambiguous source words pinned to one meaning ("Record" = verb, to record audio) and,
  optionally, to a fixed translation per locale.
* **Pending unit**: missing in a locale, identical to the source when it should not be, or marked
  `new` / `needs_review`.

## Hard rules

1. **Merge, never replace.** Add or update keys inside existing files; keep every other key, comment and the
   file's formatting. Before the first edit, make sure the catalogs are committed or copy them to the run folder.
2. **Protected text stays byte-identical**: format specifiers (`%@`, `%lld`, `%1$@`, `%#@var@`, `%arg`),
   `\n`, Markdown and links, brand terms, SF Symbol names, URLs.
3. **One register per locale**, taken from the config. Never choose it per string.
4. **A translation identical to the source is untranslated** unless the key or text is in `keep`.
5. **Done means reviewed**: the review checklist (`references/review.md`) ran over every new translation and
   the user saw the report.
6. Working files go to `./app-localization/<YYYY-MM-DD-HHMM>/` (the **run folder**); offer to add
   `app-localization/` to `.gitignore`.

## Workflow

### 1. Discover

Find every catalog in the project, skipping `Pods`, `Carthage`, `DerivedData`, `.build`, `build`,
`vendor` and the run folders under `app-localization/` (they hold backup copies of catalogs).
Look in every target: app, widgets, watch app, share/notification extensions, App Clips.
Read `references/formats.md` before reading or editing any catalog.

Report per catalog and target locale: keys, translated, missing, same-as-source, needs review, skipped
(`shouldTranslate: false`, `extractionState: stale`, no letters). Then name the project state:

| State | Meaning | Next |
|---|---|---|
| **bootstrap** | No catalog, or catalogs without keys | steps 2, 3, 4 |
| **add-locales** | Catalogs with keys, but no target locale in them yet | steps 2, 4 |
| **repair** | Target locales exist but contain same-as-source values, `needs_review`, or empty locales | steps 2, 4, pending units only |
| **top-up** | Only new keys are missing | steps 2, 4, pending units only |
| **complete** | Nothing pending | report and stop, unless the user wants a register change |

Step 2 is never skipped: when the config already exists it only takes a moment to load and confirm.

### 2. Config

Read `.app-localization.json` in the project root (schema in `references/config.md`). If it does not exist,
ask the user (AskUserQuestion) in one round:

* target locales (suggest the ones already in the catalogs, else a common set: de, fr, es, it, pt-BR, ja, ko,
  zh-Hans, ru);
* app type: `consumer` or `business`;
* one sentence on what the app does and its tone.

Then build the **register table** from `references/languages.md` (locale, register level, concrete form,
other options), show it and let the user change any row. Where a level has several forms (pt-PT formal:
impersonal or `você`; pl formal: `Pan/Pani` or impersonal), the user picks one. Collect brand terms from
the app name, product names in the catalogs and the user. Write the config and show its path.

Done when the config lists every target locale with a register level and one concrete form.

### 3. Bootstrap (unlocalized projects only)

Use the project's existing mechanism; when there is none, add a String Catalog `Localizable.xcstrings`.
Find user-visible literals in Swift (`Text("…")`, `Button("…")`, `Label`, `.navigationTitle`, `alert`,
`String(localized:)`) and UIKit (`title =`, `text =`, `setTitle`), and wrap the ones that need it
(`String(localized:comment:)`, `LocalizedStringResource`). Leave identifiers, log messages, analytics
events, SF Symbol names and asset names as they are. Turn string interpolation into the catalog's
format-specifier form. Show the user the list of strings you will wrap and which you keep literal (brand
pass); store the kept ones in `brand_terms` / `keep`. Show the code diff before editing.

Xcode fills a String Catalog with keys only when it builds. After wrapping, build every scheme that owns a
catalog (`xcodebuild -scheme <scheme> build`), then run step 1 again. For `.strings` tables, write the
source-language file yourself from the wrapped keys and their comments.

Done when the source catalogs contain every wrapped key and step 1 reports **add-locales**.

### 4. Translate

Collect the pending units per locale and write them to `RUN/pending-<locale>.json` (shape in
`references/translation-brief.md`), with up to 40 existing translations of that locale as **anchors** so new
strings reuse the app's vocabulary.

Translate with one subagent per locale, all in parallel (Agent tool). Give each the brief from
`references/translation-brief.md`, filled with: the locale's section of `references/languages.md`, the
register level and its form, the app description and tone, brand terms, `keep`, the glossary, the anchors,
and the paths of its pending and translated files. A locale with more than about 200 units is split into
batches of about 150 units (`pending-<locale>-<n>.json`) that each get the same brief, so the register
stays consistent. Each subagent writes its own file, `RUN/translated-<locale>.json` or
`RUN/translated-<locale>-<n>.json` for batch n, and returns a short note of terms it was unsure about.
Steps 5 and 6 read every `translated-<locale>*.json`.

Done when every pending unit of every locale, across all batches, has a `target` for every path in its
`expect` list.

### 5. Review

Run every check of `references/review.md` over every translated unit, locale by locale. Write findings to
`RUN/review.md` as a table: locale, key, check, severity, current text, fix. Fix what you can directly
(specifiers, punctuation, quotes, script mixing). Units with meaning or register problems go back to that
locale's subagent with the findings (at most two rounds). Then spot-read a sample yourself: 3 units each
from one CJK locale, one RTL locale, one Cyrillic locale and the unit with the most plural forms.

Done when no **error** remains and every **warning** is fixed or listed for the user.

### 6. Apply

Write the translations into the catalogs following the merge rules in `references/formats.md`: for String
Catalogs set `"state" : "translated"`; create missing `<locale>.lproj` files from the source file's key order
and comments. Validate every edited file: `plutil -lint` for `.strings` and `.stringsdict`,
`python3 -m json.tool` (or `plutil -lint`) for `.xcstrings`.

A new locale must also be known to the Xcode project, or the app ships without it: register it as
described in "Registering a new locale" in `references/formats.md`. Then build one scheme and check that
the built `.app` contains `<locale>.lproj` for every new locale.

Done when every edited file validates and the build contains every target locale.

### 7. Report

Show, per locale: units translated, coverage before and after, warnings left and the path to
`RUN/review.md`. Remind the user that each extension target has its own catalog (and that a widget or watch
app needs the keys the phone sends it), and that every scheme should be built once (`xcodebuild -scheme
<scheme> build`) so Xcode re-syncs the catalogs. Offer to add confirmed same-as-source keys to `keep` and new
term decisions to the glossary.

## References

* `references/languages.md`: per-locale register options and defaults, plural categories, punctuation,
  quotes, casing, pitfalls
* `references/formats.md`: `.xcstrings`, `.strings`, `.stringsdict` structure, specifiers, merge rules
* `references/review.md`: the review checklist with severities
* `references/translation-brief.md`: the subagent prompt and the pending/translated file shape
* `references/config.md`: `.app-localization.json` schema and an example
