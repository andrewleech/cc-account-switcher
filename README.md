# Multi-Account Switcher for Claude Code

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

## Features

- **Multi-account management**: Add, remove, and list Claude Code accounts with human-readable aliases
- **Quick switching**: Switch between accounts using aliases, numbers, or email addresses
- **Cross-platform**: Works on macOS, Linux, and WSL
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation**: Only switches authentication - your themes, settings, and preferences remain unchanged

## Installation

Download the script directly:

```bash
curl -O https://raw.githubusercontent.com/ming86/cc-account-switcher/main/ccswitch.sh
chmod +x ccswitch.sh
```

Optional: Install as `ccs` command:

```bash
./install.sh  # Creates symlink in ~/.local/bin/ccs
```

Then use `ccs` instead of `./ccswitch.sh`:
```bash
ccs              # Switch to next account
ccs --list       # List accounts
ccs --switch-to work
```

## Usage

### Basic Commands

```bash
# Add current account to managed accounts with an alias
./ccswitch.sh --add-account work
./ccswitch.sh --add-account personal

# List all managed accounts
./ccswitch.sh --list

# Switch to next account in sequence (or just run without arguments)
./ccswitch.sh
./ccswitch.sh --switch

# Switch to specific account by alias, number, or email
./ccswitch.sh --switch-to work
./ccswitch.sh --switch-to personal
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com

# Refresh the stored token for the currently logged-in account (use after re-login)
./ccswitch.sh --update

# Remove an account by alias, number, or email
./ccswitch.sh --remove-account work
./ccswitch.sh --remove-account user2@example.com

# Show help
./ccswitch.sh --help
```

### First Time Setup

1. **Log into Claude Code** with your first account (make sure you're actively logged in)
2. Run `./ccswitch.sh --add-account work` to add it with an alias (use any name like 'work', 'personal', 'client-a', etc.)
3. **Log out** and log into Claude Code with your second account
4. Run `./ccswitch.sh --add-account personal` to add it with a different alias
5. Now you can switch between accounts with `./ccswitch.sh --switch-to work` or just `./ccswitch.sh`
6. **Important**: After each switch, restart Claude Code to use the new authentication

> **What gets switched:** Only your authentication credentials change. Your themes, settings, preferences, and chat history remain exactly the same.

### Refreshing a Stale Login

When an account's stored token goes stale, log back in to Claude Code normally, then run:

```bash
./ccswitch.sh --update
```

This reads the email currently logged in to Claude Code, finds the managed account with the matching email, and replaces its stored token and config with the fresh ones. If the logged-in account isn't managed yet, `--update` offers to add it.

### Account Aliases

Each account must have a unique alias when added. Aliases are human-readable names that make it easy to identify and switch between accounts:

- **Allowed characters**: Letters, numbers, dashes, and underscores (e.g., `work`, `personal`, `client-a`, `dev_account`)
- **Switching flexibility**: You can switch using the alias, account number, or email address
- **List display**: Running `--list` shows: `1: work (user@example.com) (active)`

## Requirements

- Bash 4.4+
- `jq` (JSON processor)

### Installing Dependencies

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions

When switching accounts, it:

1. Backs up the current account's authentication data
2. Restores the target account's authentication data
3. Updates Claude Code's authentication files

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `./ccswitch.sh --list`
- Verify Claude Code is closed before switching
- Try switching back to your original account

### If you can't add an account

- Make sure you're logged into Claude Code first
- Provide a valid alias (alphanumeric characters, dashes, and underscores only)
- Ensure the alias isn't already in use by another account
- Check that you have `jq` installed
- Verify you have write permissions to your home directory

### If Claude Code doesn't recognize the new account

- Make sure you restarted Claude Code after switching
- Check the current account: `./ccswitch.sh --list` (look for "(active)")

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Note your current active account: `./ccswitch.sh --list`
2. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
3. Delete the script: `rm ccswitch.sh`

Your current Claude Code login will remain active.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- The tool requires Claude Code to be closed during account switches

## License

MIT License - see LICENSE file for details
