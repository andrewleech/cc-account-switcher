#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Account identifier resolution function
resolve_account_identifier() {
    local identifier="$1"

    # First, check if it's a numeric account number
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"
        return
    fi

    # Then check if it's an alias
    local account_num
    account_num=$(jq -r --arg alias "$identifier" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$account_num" && "$account_num" != "null" ]]; then
        echo "$account_num"
        return
    fi

    # Finally, check if it's an email
    account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$account_num" && "$account_num" != "null" ]]; then
        echo "$account_num"
        return
    fi

    # Not found
    echo ""
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Check if alias exists
alias_exists() {
    local alias="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg alias "$alias" '.accounts[] | select(.alias == $alias)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Validate alias format
validate_alias() {
    local alias="$1"
    # Reject all-numeric aliases: resolve_account_identifier treats a numeric
    # identifier as an account number, so such an alias could never be matched.
    if [[ "$alias" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    # Allow alphanumeric, dashes, and underscores only
    if [[ "$alias" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Add account
cmd_add_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --add-account <alias>"
        echo "Example: $0 --add-account work"
        exit 1
    fi

    local alias="$1"

    # Validate alias format
    if ! validate_alias "$alias"; then
        echo "Error: Invalid alias format. Use letters, numbers, dashes, and underscores, and include at least one non-digit."
        exit 1
    fi

    setup_directories
    init_sequence_file

    # Check if alias already exists
    if alias_exists "$alias"; then
        echo "Error: Alias '$alias' is already in use."
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)
    
    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi
    
    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")
    
    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg alias "$alias" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            alias: $alias,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Added account '$alias' ($current_email) as Account-$account_num"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <alias|account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local account_num
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Resolve alias, email, or account number to an account number
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: No account found matching: $identifier"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi
    
    local email
    email=$(echo "$account_info" | jq -r '.email')
    
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    
    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi
    
    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi
    
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Account-$account_num ($email) has been removed"
}

# Refresh stored credentials/config for the currently logged-in account
cmd_update() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    # Find the managed account whose stored email matches the live login
    local account_num
    account_num=$(resolve_account_identifier "$current_email")

    # Not managed yet: offer to add it (captures the fresh token either way)
    if [[ -z "$account_num" ]]; then
        echo "Notice: Active account '$current_email' is not managed."
        echo -n "Enter an alias for this account (e.g., 'work', 'personal'): "
        read -r alias

        if [[ -z "$alias" ]]; then
            echo "Error: Alias cannot be empty."
            exit 1
        fi

        cmd_add_account "$alias"
        exit 0
    fi

    # Read live credentials and config from the Claude Code locations
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    # Overwrite the stored backup for this account's slot
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"

    # Refresh derived state: uuid from the new config, active account, timestamp
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")

    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg uuid "$account_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].uuid = $uuid |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    local alias
    alias=$(jq -r --arg num "$account_num" '.accounts[$num].alias // empty' "$SEQUENCE_FILE")
    echo "Updated stored credentials for Account-$account_num (${alias:+$alias, }$current_email)"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi

    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response

    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account <alias>' later."
        return 1
    fi

    echo -n "Enter an alias for this account (e.g., 'work', 'personal'): "
    read -r alias

    if [[ -z "$alias" ]]; then
        echo "Error: Alias cannot be empty."
        return 1
    fi

    cmd_add_account "$alias"
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi
    
    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)
    
    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi
    
    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] as $account |
        if $account.alias then
            if "\($num)" == $active then
                "  \($num): \($account.alias) (\($account.email)) (active)"
            else
                "  \($num): \($account.alias) (\($account.email))"
            end
        else
            # Backward compatibility for accounts without aliases
            if "\($num)" == $active then
                "  \($num): \($account.email) (active)"
            else
                "  \($num): \($account.email)"
            end
        end
    ' "$SEQUENCE_FILE"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi
    
    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' is not managed."
        echo -n "Enter an alias for this account (e.g., 'work', 'personal'): "
        read -r alias

        if [[ -z "$alias" ]]; then
            echo "Error: Alias cannot be empty."
            exit 1
        fi

        cmd_add_account "$alias"
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi
    
    # wait_for_claude_close
    
    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))
    
    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done
    
    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"
    
    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <alias|account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local target_account
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Resolve alias, email, or account number to an account number
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        echo "Error: No account found matching: $identifier"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi
    
    # wait_for_claude_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    
    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)
    
    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi
    
    # Step 3: Activate target account
    write_credentials "$target_creds"
    
    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi
    
    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi
    
    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    
    # Step 4: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Switched to Account-$target_account ($target_email)"
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
    
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Running without arguments switches to the next account (same as --switch)."
    echo ""
    echo "Commands:"
    echo "  --add-account <alias>              Add current account with an alias (e.g., 'work', 'personal')"
    echo "  --remove-account <alias|num|email> Remove account by alias, number, or email"
    echo "  --list                             List all managed accounts"
    echo "  --switch                           Rotate to next account in sequence (default)"
    echo "  --switch-to <alias|num|email>      Switch to specific account by alias, number, or email"
    echo "  --update                           Refresh stored token for the currently logged-in account (use after re-login)"
    echo "  --help                             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --add-account work"
    echo "  $0 --add-account personal"
    echo "  $0 --list"
    echo "  $0                                 # Switch to next account"
    echo "  $0 --switch                        # Same as above"
    echo "  $0 --switch-to work"
    echo "  $0 --switch-to personal"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --update                        # After re-logging in to Claude Code"
    echo "  $0 --remove-account work"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    
    check_bash_version
    check_dependencies
    
    case "${1:-}" in
        --add-account)
            shift
            cmd_add_account "$@"
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --update)
            cmd_update
            ;;
        --help)
            show_usage
            ;;
        "")
            cmd_switch
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi