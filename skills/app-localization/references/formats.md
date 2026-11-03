# Catalog formats

How to read and edit each format without losing data. Keep each file's existing style: indentation, key
order, comments, encoding.

## String Catalog (.xcstrings)

JSON written by Xcode: two-space indent, `"key" : value` (a space before the colon), keys sorted, empty
objects as `{\n\n}`.

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "Delete %@?" : {
      "comment" : "Alert title; %@ is a file name",
      "localizations" : {
        "de" : {
          "stringUnit" : { "state" : "translated", "value" : "%@ löschen?" }
        }
      }
    },
    "%lld files" : {
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld file" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld files" } }
            }
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

* **Source text**: the source-language localization if present, otherwise the key itself.
* **Skip** keys with `"shouldTranslate" : false`, `"extractionState" : "stale"`, empty keys and keys with no
  letters (`%@`, `—`).
* **Variations**: `variations.plural.<category>`, `variations.device.<iphone|ipad|mac|watch|…>`, and nested
  combinations. Mirror the source's variation tree, but give plural groups the target language's
  categories (`references/languages.md`).
* **Substitutions** (several plurals in one string): the value holds `%#@name@` placeholders and
  `substitutions.<name>` holds `argNum`, `formatSpecifier` and `variations.plural`; inside those variants
  the number is written `%arg`. Copy `argNum` and `formatSpecifier` from the source; translate only the
  variant values.
* **State**: write `"state" : "translated"`. `new` and `needs_review` mean pending.
* **Merging**: add the locale under `localizations` in sorted position; replace only the units you
  translated. Never add or remove keys under `strings`: Xcode owns them.

Edit the file with targeted edits or a small one-off script in the scratchpad that loads the JSON, inserts
the translations and writes it back in Xcode's style. Then validate with `plutil -lint` and check `git diff`
touches only `localizations`.

## Strings tables (.lproj/*.strings)

```
/* Alert title; %@ is a file name */
"Delete %@?" = "%@ löschen?";
```

* One file per language: `<locale>.lproj/<Table>.strings` (`de.lproj`, `zh-Hans.lproj`, `pt-BR.lproj`). The
  source is `<source>.lproj`, else `Base.lproj` (storyboards).
* Escapes inside quotes: `\"`, `\\`, `\n`, `\t`, `\U00A0`.
* Files may be UTF-16 (check with `file`); write them back in the same encoding.
* **Merging**: replace the value of an existing key in place; append new keys at the end with the source
  comment. A missing locale file is created in the source file's key order with its comments.
* `InfoPlist.strings` keys (`NSCameraUsageDescription`, `CFBundleDisplayName`) are translated like any other;
  the display name usually stays a brand term.

## Plural dictionaries (.stringsdict)

```xml
<key>%lld files</key>
<dict>
	<key>NSStringLocalizedFormatKey</key>
	<string>%#@files@</string>
	<key>files</key>
	<dict>
		<key>NSStringFormatSpecTypeKey</key>
		<string>NSStringPluralRuleType</string>
		<key>NSStringFormatValueTypeKey</key>
		<string>lld</string>
		<key>one</key>
		<string>%lld file</string>
		<key>other</key>
		<string>%lld files</string>
	</dict>
</dict>
```

Translate `NSStringLocalizedFormatKey` only when it contains text besides the placeholders, and the category
strings. Keep `NSStringFormatSpecTypeKey` and `NSStringFormatValueTypeKey`. Give each variable the target
language's categories. Validate with `plutil -lint`.

## Format specifiers

| Specifier | Meaning |
|---|---|
| `%@` | object / string |
| `%lld`, `%ld`, `%d` | integer |
| `%f`, `%.1f` | floating point |
| `%1$@`, `%2$lld` | positional: the translation may reorder arguments with these |
| `%#@name@` | substitution / plural variable |
| `%arg` | the number inside a substitution's variant |
| `%%` | a literal percent sign |

A translation keeps the same set of arguments with the same types. When it reorders two or more arguments,
it uses positional specifiers (`%2$@ … %1$@`). A plural `one` form may drop the number (`One file`) in
languages where `one` means exactly 1 (en, de, nl, it, es, sv, pl, cs); keep it in languages where `one`
covers other numbers (ru and uk `21 файл`, fr `0 fichier`).
