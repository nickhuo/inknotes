#!/bin/sh
# Install the release binary and its matching agent skill. Safe to pipe into sh.
set -eu

die() {
    printf 'inknotes installer: %s\n' "$*" >&2
    exit 1
}

download() {
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --retry 2 "$1" -o "$2"
}

cleanup() {
    if [ -n "$work_dir" ]; then rm -rf "$work_dir"; fi
    if [ -n "$staged_bin" ]; then rm -f "$staged_bin"; fi
}

main() {
    release_tag=''
    agents=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --agent)
                [ "$#" -ge 2 ] || die '--agent needs an agent name.'
                case "$2" in
                    ''|-*|*[!a-z0-9-]*) die "Invalid agent name: $2" ;;
                esac
                agents="${agents:+$agents }$2"
                shift 2
                ;;
            --version)
                [ "$#" -ge 2 ] || die '--version needs a release tag, such as v0.4.0.'
                release_tag=$2
                shift 2
                ;;
            --help|-h)
                printf '%s\n' \
                    'Usage: sh install.sh [--version TAG] [--agent NAME ...]' \
                    'Installs the latest release to ~/.local/bin and its matching global skill.' \
                    'Uses the skills CLI agent picker and confirmations in your terminal.' \
                    'Repeat --agent to preselect specific agents.'
                return
                ;;
            *) die "Unknown argument: $1 (use --help)." ;;
        esac
    done

    [ "$(uname -s)" = Darwin ] || die 'inknotes requires macOS.'
    [ "$(uname -m)" = arm64 ] || die 'inknotes requires Apple silicon (an arm64 terminal).'
    sw_vers -productVersion | awk -F. '{ exit !($1 > 27 || ($1 == 27 && $2 >= 2)) }' \
        || die 'inknotes requires macOS 27.2 or later.'
    for tool in curl node npx shasum; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing $tool. Install Node.js 22.20 or later for node/npx, then rerun."
    done
    node -e '
        const [major, minor] = process.versions.node.split(".").map(Number);
        process.exit(major > 22 || (major === 22 && minor >= 20) ? 0 : 1);
    ' </dev/null || die 'Node.js 22.20 or later is required by the skills installer.'
    if ! ( : </dev/tty ) 2>/dev/null; then
        die 'Interactive skill installation requires a terminal. Run this command in a terminal window.'
    fi
    if [ -n "$release_tag" ]; then
        node -e 'process.exit(/^v\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(process.argv[1]) ? 0 : 1)' \
            "$release_tag" </dev/null || die 'Expected a release tag such as v0.4.0.'
        release_api="https://api.github.com/repos/nickhuo/inknotes/releases/tags/$release_tag"
    else
        release_api='https://api.github.com/repos/nickhuo/inknotes/releases/latest'
    fi

    work_dir=''
    staged_bin=''
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/inknotes-install.XXXXXX")
    printf 'Fetching release metadata...\n'
    download "$release_api" "$work_dir/release.json" || die 'Could not fetch the release. Rerun to retry.'
    metadata=$(node -e '
        const fs = require("node:fs");
        try {
            const release = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            const tag = release.tag_name;
            if (!/^v\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(tag)) throw new Error("Invalid release tag.");
            if (process.argv[2] && tag !== process.argv[2]) throw new Error("Release tag does not match the requested version.");
            const asset = release.assets.find(asset => asset.name === "inknotes");
            const url = `https://github.com/nickhuo/inknotes/releases/download/${tag}/inknotes`;
            if (!asset || asset.browser_download_url !== url) throw new Error("Release has no inknotes binary.");
            if (!/^sha256:[a-f0-9]{64}$/.test(asset.digest)) throw new Error("Release has no SHA-256 digest; cannot verify the binary.");
            console.log([tag, url, asset.digest.slice(7)].join("|"));
        } catch (error) {
            console.error(`inknotes installer: ${error.message}`);
            process.exit(1);
        }
    ' "$work_dir/release.json" "$release_tag" </dev/null)
    IFS='|' read -r release_tag binary_url digest <<EOF
$metadata
EOF

    printf 'Downloading inknotes %s...\n' "$release_tag"
    download "$binary_url" "$work_dir/inknotes" || die 'Binary download failed. The installed CLI has not changed.'
    printf '%s  %s\n' "$digest" "$work_dir/inknotes" | shasum -a 256 -c - \
        || die 'Binary checksum did not match. The installed CLI has not changed.'

    bin_dir="$HOME/.local/bin"
    [ ! -d "$bin_dir/inknotes" ] || die "$bin_dir/inknotes is a directory; cannot install the CLI there."
    mkdir -p "$bin_dir"
    staged_bin=$(mktemp "$bin_dir/.inknotes.XXXXXX")
    install -m 755 "$work_dir/inknotes" "$staged_bin"
    "$staged_bin" version > "$work_dir/version.json" \
        || die 'The downloaded binary could not run. The installed CLI has not changed.'
    node -e '
        const fs = require("node:fs");
        const version = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version;
        process.exit(version === process.argv[2].slice(1) ? 0 : 1);
    ' "$work_dir/version.json" "$release_tag" </dev/null \
        || die 'Binary version does not match the release. The installed CLI has not changed.'

    printf 'Installing use-apple-notes; follow the skills CLI prompts...\n'
    # Agent names are validated above. Split only this list, with globbing disabled.
    set -f
    # shellcheck disable=SC2086
    set -- $agents
    if [ "$#" -gt 0 ]; then set -- --agent "$@"; fi
    skill_lock="${XDG_STATE_HOME:-$HOME/.agents}/.skill-lock.json"
    if [ -n "${XDG_STATE_HOME:-}" ]; then skill_lock="$XDG_STATE_HOME/skills/.skill-lock.json"; fi
    if [ -f "$skill_lock" ]; then
        cp "$skill_lock" "$work_dir/skill-lock-before.json"
    else
        printf '{}\n' > "$work_dir/skill-lock-before.json"
    fi
    # Pin the helper so its install record and runtime requirement stay predictable.
    # Give prompts the controlling terminal, not the curl | sh script on stdin.
    npx skills@1.7.6 add \
        "https://github.com/nickhuo/inknotes/tree/$release_tag/skills/use-apple-notes" \
        --skill use-apple-notes --global "$@" </dev/tty \
        || die 'Skill installation failed. The installed CLI has not changed; rerun to retry.'
    # Interactive cancellation can exit zero. Require a fresh record for this release.
    node -e '
        const fs = require("node:fs");
        try {
            const before = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).skills?.["use-apple-notes"];
            const installed = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).skills?.["use-apple-notes"];
            if (!installed || installed.source !== "nickhuo/inknotes" || installed.ref !== process.argv[3]
                || typeof installed.updatedAt !== "string" || installed.updatedAt === before?.updatedAt) {
                throw new Error("No fresh skill installation was recorded.");
            }
        } catch (error) {
            console.error("inknotes installer: Skill installation was cancelled or could not be verified. The installed CLI has not changed; rerun to retry.");
            process.exit(1);
        }
    ' "$work_dir/skill-lock-before.json" "$skill_lock" "$release_tag" </dev/null

    # Replace atomically only after the binary and skill checks have passed.
    mv -f "$staged_bin" "$bin_dir/inknotes"
    staged_bin=''
    printf '\nInstalled inknotes %s: %s/inknotes\nSkill: use-apple-notes (%s)\n' "$release_tag" "$bin_dir" "$release_tag"
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) printf '\nAdd this to ~/.zshrc, then open a new terminal:\n  export PATH="$HOME/.local/bin:$PATH"\n' ;;
    esac
    printf '\nNext: enable Full Disk Access for your terminal or agent app in\nSystem Settings > Privacy & Security > Full Disk Access, then restart that app.\n'
}

# Define everything before running, so a truncated script cannot start an install.
main "$@"
