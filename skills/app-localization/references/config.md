# Project config

`.app-localization.json` in the project root. It records the decisions that must stay the same across runs,
so commit it with the project.

```json
{
  "source_locale": "en",
  "locales": ["de", "fr", "es", "pt-PT", "ru", "ja", "ko", "zh-Hans"],
  "app": {
    "name": "Habitly",
    "type": "consumer",
    "description": "Habit tracker with streaks and reminders.",
    "tone": "Friendly, short, encouraging; no exclamation marks in errors."
  },
  "register": {
    "de": { "level": "informal", "form": "du" },
    "fr": { "level": "formal", "form": "vous" },
    "es": { "level": "informal", "form": "tú" },
    "pt-PT": { "level": "formal", "form": "impersonal (Introduza, Toque)" },
    "ru": { "level": "formal", "form": "вы, lowercase" },
    "ja": { "level": "formal", "form": "です・ます" },
    "ko": { "level": "polite", "form": "해요체" },
    "zh-Hans": { "level": "informal", "form": "你" }
  },
  "brand_terms": ["Habitly", "Habitly Pro", "iCloud", "Apple Watch"],
  "keep": ["OK", "Wi-Fi"],
  "glossary": {
    "Streak": { "sense": "days in a row a habit was completed", "ja": "連続記録", "ru": "серия" },
    "Record": { "sense": "verb: to log today's progress" }
  }
}
```

| Field | Meaning |
|---|---|
| `source_locale` | Development language; String Catalogs carry their own `sourceLanguage`. |
| `locales` | Target locales, in the catalog's codes (`zh-Hans`, `pt-BR`, `es-419`). |
| `app.type` | `consumer` or `business`; picks the register defaults. |
| `app.description`, `app.tone` | One sentence each; passed to every translator. |
| `register` | Locale → `level` (`formal`, `informal`, `polite` for ko, or `neutral`) and `form`: the one concrete form used, with an example when the level allows several (pt-PT, pl). Options are in `references/languages.md`. |
| `brand_terms` | Text that stays as written inside any translation. |
| `keep` | Keys or whole source texts whose translation is the source text itself. |
| `glossary` | Term → `sense` (the meaning to use) and optional fixed translations per locale. |
