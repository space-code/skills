# Setup: App Store Connect API key

The scripts talk to the App Store Connect API with a team API key. The key is created once and the
`.p8` file can be downloaded **only once**.

## 1. Create the key

App Store Connect -> Users and Access -> Integrations -> App Store Connect API -> Team Keys ->
**Generate API Key**.

* Access: **App Manager** or **Admin**. Lower roles can read apps but cannot change prices (HTTP 403).
* Download `AuthKey_<KEY_ID>.p8` and note the **Issuer ID** (UUID at the top of the Team Keys page).

## 2. Put it where the scripts look

```
~/.appstoreconnect/
├── config.json                       {"issuer_id": "<ISSUER_ID>"}
└── private_keys/
    └── AuthKey_<KEY_ID>.p8
```

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.appstoreconnect/private_keys/
echo '{"issuer_id": "<ISSUER_ID>"}' > ~/.appstoreconnect/config.json
chmod 700 ~/.appstoreconnect ~/.appstoreconnect/private_keys
chmod 600 ~/.appstoreconnect/config.json ~/.appstoreconnect/private_keys/*.p8
```

This is the same folder Apple's `altool` and fastlane use, so one key serves all of them. The Key ID is
read from the file name. With several keys in the folder, set `ASC_KEY_ID` to pick one.

Environment variables override the folder: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_P8` (path to the key).

## 3. Verify

```bash
bash scripts/check_setup.sh
```

| Line | Meaning |
|---|---|
| `FAIL no AuthKey_...` | key missing or in the wrong folder |
| `FAIL ... not a valid EC key` / `curve` | not the downloaded `.p8`, or not a P-256 key |
| `FAIL issuer id missing` | `config.json` missing or empty |
| `WARN permissions` | run the `chmod` it prints |
| `FAIL HTTP 401` | key id, issuer id and `.p8` do not belong together |
| `FAIL HTTP 403` | key role too low, regenerate with App Manager or Admin |

## Security

* The key stays outside every repository. `check_setup.sh` warns when the folder is inside a git work tree.
* Scripts never print key material. Do not paste the `.p8` into a chat; if it leaked, revoke the key in
  App Store Connect and generate a new one.
* `scripts/asc.rb` only reads unless you pass `--write`; the skill adds that flag only after the user approved the Price Proposal.
