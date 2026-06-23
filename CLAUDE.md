# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a bash utility for managing multiple Claude Code accounts on macOS, Linux, and WSL. It switches authentication credentials while preserving user settings, themes, and preferences. Accounts are identified by human-readable aliases (e.g., 'work', 'personal') and can also be referenced by number or email.

## Core Architecture

**Single-file design**: The entire tool is implemented in `ccswitch.sh` (750 lines). There are no build steps, dependencies beyond `jq`, or additional source files.

**Data storage structure**:
- `~/.claude-switch-backup/sequence.json` - Central state tracking active account, account list, and switching sequence
- `~/.claude-switch-backup/configs/` - Stores `.claude-config-{num}-{email}.json` files (OAuth account data)
- `~/.claude-switch-backup/credentials/` - On Linux/WSL only; stores `.claude-credentials-{num}-{email}.json` files
- macOS uses system Keychain for credential storage instead of files

**Platform-specific behavior**:
- Platform detection at ccswitch.sh:38-50 determines macOS, Linux, or WSL
- Credential storage/retrieval (ccswitch.sh:192-226) adapts based on platform
- macOS uses `security` command for Keychain operations
- Linux/WSL uses file-based storage with 600 permissions

**Account switching flow** (ccswitch.sh:614-680):
1. Backs up current account credentials and OAuth config
2. Retrieves target account data from backup storage
3. Writes target credentials to system location
4. Merges target OAuth account section into `~/.claude/.claude.json`
5. Updates `sequence.json` with new active account

**Claude Code configuration locations**:
- Primary: `~/.claude/.claude.json` (OAuth account data)
- Fallback: `~/.claude.json`
- Credentials: macOS Keychain service "Claude Code-credentials" or `~/.claude/.credentials.json`

## Testing the Script

Test switches without Claude Code running:

```bash
# Add current account with alias
./ccswitch.sh --add-account work
./ccswitch.sh --add-account personal

# View managed accounts
./ccswitch.sh --list

# Switch between accounts (by alias, number, or email)
./ccswitch.sh --switch-to work
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user@example.com

# Rotate to next account (or just run without arguments)
./ccswitch.sh
```

The script can be installed as `ccs` via `install.sh` which creates a symlink in `~/.local/bin/ccs`.

Verify credential storage:
- macOS: `security find-generic-password -s "Claude Code-Account-1-email@example.com"`
- Linux/WSL: Check files in `~/.claude-switch-backup/credentials/`

## Modifying Account Management

Account data structure in `sequence.json`:
```json
{
  "activeAccountNumber": 1,
  "lastUpdated": "2025-10-23T...",
  "sequence": [1, 2, 3],
  "accounts": {
    "1": {"email": "user@example.com", "uuid": "...", "alias": "work", "added": "..."}
  }
}
```

Key functions for account operations:
- `get_current_account()` (ccswitch.sh:175-189) - Reads active email from `.claude.json`
- `account_exists()` (ccswitch.sh:320-327) - Checks if email is managed
- `alias_exists()` (ccswitch.sh:330-337) - Checks if alias is in use
- `validate_alias()` (ccswitch.sh:340-348) - Validates alias format (alphanumeric, dashes, underscores)
- `resolve_account_identifier()` (ccswitch.sh:91-117) - Converts alias/email/number to account number

## Security Considerations

All credential files use 600 permissions (owner read/write only). Directory permissions are 700. The script validates JSON integrity before writing using `write_json()` (ccswitch.sh:108-123) which creates temp files and validates before atomic move.

The script refuses to run as root unless in a container (detected via ccswitch.sh:13-35).
