# Upgrading

## pi 1.3.0

pi.nvim does not change your backend settings or credentials. When upgrading an older backend:

- Rename the Azure provider key from `azure-openai-responses` to `azure` in `auth.json`, `models.json`, and relevant `settings.json` model/provider entries, or sign in again. The `AZURE_OPENAI_*` environment variables are unchanged.
- Include `/v1` in any custom `kimi-coding` base URL in `models.json`.
- Use the tool-wrapper pattern in [Diff review](README.md#diff-review) for permission extensions that handle already-applied edits, including nested calls through codemode.
