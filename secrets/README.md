# Secrets

`claude_code_oauth_token.txt` holds a **Claude Code OAuth token** generated from
your Claude Max subscription (via `claude setup-token`). The `claude-adapter`
container uses it to call Claude through Claude Code — **no Anthropic API key or
credits are used**.

Generate/refresh it with:

```powershell
.\scripts\setup-claude-token.ps1
```

The token is account-scoped (not machine-scoped), so you can generate it on any
machine logged into your subscription and paste it here. It is gitignored.

> Note: driving a personal Max subscription from an automated backend is a
> Terms-of-Service gray area and is subject to your subscription's rate limits.
