#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Runs openclaw onboard --non-interactive to configure from env vars
# 2. Patches config for features onboard doesn't cover (channels, gateway auth)
# 3. Starts the gateway
#
# NOTE: Persistence (backup/restore) is handled by the Sandbox SDK at the
# Worker level, not inside the container. The Worker calls createBackup()
# and restoreBackup() which use squashfs snapshots stored in R2.
# No rclone or R2 credentials are needed inside the container.

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# VERSION SENTINEL — re-onboard when openclaw version changes
# ============================================================
# The container disk persists across deploys (DO sticky storage), so a config
# written by one openclaw version can survive into a newer version that has a
# stricter schema, leaving the gateway unable to start. Track the writing
# version in a sentinel file; when it doesn't match, archive the old config
# and force a fresh onboard. Paired-device state lives in the workspace dir,
# not in openclaw.json, so we don't lose it.
VERSION_MARKER="$CONFIG_DIR/.openclaw-version"
CURRENT_OPENCLAW_VERSION="$(openclaw --version 2>/dev/null | head -1)"
PREV_OPENCLAW_VERSION=""
[ -f "$VERSION_MARKER" ] && PREV_OPENCLAW_VERSION="$(cat "$VERSION_MARKER")"

if [ -f "$CONFIG_FILE" ] && { [ -z "$PREV_OPENCLAW_VERSION" ] || [ "$PREV_OPENCLAW_VERSION" != "$CURRENT_OPENCLAW_VERSION" ]; }; then
    BACKUP="$CONFIG_FILE.bak.$(date +%s)"
    echo "Config schema may be stale (prev=${PREV_OPENCLAW_VERSION:-<no marker>}, current=$CURRENT_OPENCLAW_VERSION), archiving to $BACKUP and re-onboarding"
    mv "$CONFIG_FILE" "$BACKUP"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    # Determine auth choice — openclaw onboard reads the actual key values
    # from environment variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
    # so we only pass --auth-choice, never the key itself, to avoid
    # exposing secrets in process arguments visible via ps/proc.
    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key"
    elif [ -n "$TESSERA_API_KEY" ]; then
        # TesseraAI is OpenAI-compatible (chat completions). Onboard needs an
        # OPENAI_API_KEY to succeed with openai-api-key auth — we re-export the
        # Tessera key as OPENAI_API_KEY so onboard creates a valid baseline.
        # The patch step below replaces the openai provider with a "tessera"
        # provider pointing at TESSERA_BASE_URL and sets it as the primary model.
        export OPENAI_API_KEY="$TESSERA_API_KEY"
        AUTH_ARGS="--auth-choice openai-api-key"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# Stamp the version that wrote / is using this config so we can detect drift.
echo "$CURRENT_OPENCLAW_VERSION" > "$VERSION_MARKER"

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

config.gateway.controlUi = config.gateway.controlUi || {};

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

// Allowed origins for the Control UI WebSocket. The gateway runs inside the
// Cloudflare Container behind the Worker, which proxies requests from the
// public workers.dev domain. openclaw 2026.4.29+ stopped honoring the '*'
// wildcard, so we pin the specific WORKER_URL when available and keep '*'
// as a fallback for older versions and local dev.
const allowedOrigins = ['*'];
if (process.env.WORKER_URL) {
    const workerOrigin = process.env.WORKER_URL.replace(/\/+$/, '');
    if (!allowedOrigins.includes(workerOrigin)) allowedOrigins.unshift(workerOrigin);
}
config.gateway.controlUi.allowedOrigins = allowedOrigins;

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// TesseraAI (OpenAI-compatible) provider override
// When TESSERA_API_KEY + TESSERA_BASE_URL + TESSERA_MODEL are all set, inject a
// "tessera" provider into models.providers and pin it as the agent's primary model.
// This bypasses TesseraAI's lack of a Responses API by using openai-completions.
if (process.env.TESSERA_API_KEY && process.env.TESSERA_BASE_URL && process.env.TESSERA_MODEL) {
    const baseUrl = process.env.TESSERA_BASE_URL.replace(/\/+$/, '');
    const modelId = process.env.TESSERA_MODEL;
    const contextWindow = parseInt(process.env.TESSERA_CONTEXT_WINDOW || '131072', 10);
    const maxTokens = parseInt(process.env.TESSERA_MAX_TOKENS || '8192', 10);

    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.tessera = {
        baseUrl: baseUrl,
        apiKey: process.env.TESSERA_API_KEY,
        api: 'openai-completions',
        models: [{ id: modelId, name: modelId, contextWindow: contextWindow, maxTokens: maxTokens }],
    };
    // Drop the placeholder openai provider that onboard created from the
    // re-exported key — leaving it in place would expose the Tessera key under
    // a misleading provider name and validate against the wrong baseUrl.
    if (config.models.providers.openai) delete config.models.providers.openai;

    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: 'tessera/' + modelId };
    console.log('TesseraAI provider injected: model=' + modelId + ' via ' + baseUrl);
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

# Gateway token (if set) is already written to openclaw.json by the config
# patch above (gateway.auth.token). We deliberately avoid passing --token on
# the command line because CLI arguments are visible to all processes in the
# container via ps/proc.
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
else
    echo "Starting gateway with device pairing (no token)..."
fi
exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
