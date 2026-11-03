# Translation brief

## Pending file

`RUN/pending-<locale>.json`, one per locale, or one per batch (`pending-<locale>-<n>.json`) when the locale
is split:

```json
{
  "locale": "de",
  "source_locale": "en",
  "register": "informal",
  "form": "du",
  "plural_categories": ["one", "other"],
  "anchors": [
    { "source": "Settings", "target": "Einstellungen" }
  ],
  "units": [
    {
      "id": "App/Localizable.xcstrings::Delete %@?",
      "key": "Delete %@?",
      "comment": "Alert title; %@ is a file name",
      "status": "missing",
      "source": { "": "Delete %@?" },
      "expect": [""],
      "current": null
    },
    {
      "id": "App/Localizable.xcstrings::%lld files",
      "key": "%lld files",
      "comment": null,
      "status": "missing",
      "source": { "plural.one": "%lld file", "plural.other": "%lld files" },
      "expect": ["plural.one", "plural.other"],
      "current": null
    }
  ]
}
```

* `id` is `<catalog path>::<key>`.
* `source`, `current` and the translation are flat maps of **paths** to text: `""` for the plain value,
  `plural.<category>`, `device.<device>`, `substitutions.<name>.plural.<category>`, and combinations.
* `expect` lists the paths the translation must fill: the source paths with plural groups expanded to the
  target language's categories (ru: `plural.one`, `plural.few`, `plural.many`, `plural.other`), plus
  `zero` when the source has an explicit `zero` form (de: `plural.zero`, `plural.one`, `plural.other`).
* `register` and `form` are copied from the config: the level and the one concrete form the user chose.
* `current` is the existing translation for repair runs; reuse what is correct.

The subagent writes the matching translated file, `RUN/translated-<locale>.json` or
`RUN/translated-<locale>-<n>.json` for batch n: the same content with `"target": { "<path>": "<text>" }`
added to every unit. Batches never share an output file.

## Subagent prompt

Fill the placeholders and send one prompt per locale (or batch):

```
You translate the UI strings of an iOS app from {source_locale} into {locale}.

App: {app.name}. {app.description}
Tone: {app.tone}
Register: {register}, written as {form}. Use exactly this form in every sentence: pronouns, possessives
and imperatives.
Buttons and menu items use the form described in the language notes below.

Language notes for {locale}:
{the locale's section and register row from references/languages.md}

Keep exactly as written: {brand_terms}, {keep}, format specifiers (%@, %lld, %1$@, %#@name@, %arg),
\n, Markdown, URLs.
Glossary (meaning and fixed translations): {glossary}

Input: {pending file path}. Each unit has a key, a comment, the source text per path, and `expect`,
the paths you must fill. Use the key name, the comment and neighbouring keys to pick the right meaning;
when a word stays ambiguous, choose the reading that fits a button or label in this app and list it in your
note. Match the vocabulary of the anchors (existing translations of this app).

Plurals: fill every category in `expect` with the grammatically correct form for that category; a
`zero` path is the text for the number 0 and follows the source's zero form ("No files").
Reorder arguments only with positional specifiers (%1$@, %2$@).
Write natural {locale} UI text, not a word-for-word copy: sentence case where the language uses it, the
locale's quotes and punctuation, and a length close to the source for short labels.

Write {translated file path}: the input with "target": {path: text} added to every unit. Reply with the
number of units and a short list of terms you were unsure about.
```
