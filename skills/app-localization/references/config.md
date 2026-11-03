# Project config

`.app-localization.json` in the project root. It records the decisions that must stay the same across runs,
so commit it with the project.

```json
{
  "source_locale": "en",
  "locales": ["de", "fr", "es", "ru", "ja", "ko", "zh-Hans"],
  "app": {
    "name": "Habitly",
    "type": "consumer",
    "description": "Habit tracker with streaks and reminders.",
    "tone": "Friendly, short, encouraging; no exclamation marks in errors."
  },
  "register": {
    "de": "informal",
    "fr": "formal",
    "es": "informal",
    "ru": "formal",
    "ja": "formal",
    "ko": "polite",
    "zh-Hans": "informal"
  },
  "brand_terms": ["Habitly", "Habitly Pro", "iCloud", "Apple Watch"],
  "keep": ["OK", "Wi-Fi"],
  "glossary": {
    "Streak": { "sense": "days in a row a habit was completed", "de": "Serie", "ru": "серия" },
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
| `register` | Locale → `formal`, `informal`, `polite` (ko) or `neutral`, from `references/languages.md`. |
| `brand_terms` | Text that stays as written inside any translation. |
| `keep` | Keys or whole source texts whose translation is the source text itself. |
| `glossary` | Term → `sense` (the meaning to use) and optional fixed translations per locale. |
