#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox.
#
# This bypasses `openclaw onboard` and writes the config directly. Onboard
# under openclaw 2026.4.29 hangs when given an OpenAI-compatible key that
# doesn't validate against api.openai.com (e.g. TesseraAI), and the script
# never reaches the gateway-start step. Generating the config in-place with
# all required fields lets us drive any provider — including OpenAI-compatible
# proxies — without depending on onboard.
#
# Persistence (backup/restore) is handled by the Sandbox SDK at the Worker
# level, not inside the container.

set -e   # do NOT add -x: it traces every command, including secret env vars.

echo "===== start-openclaw.sh boot $(date -u +%FT%TZ) (script v10-host-header-fallback) ====="

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="$CONFIG_DIR/workspace"
SESSIONS_DIR="$CONFIG_DIR/agents/main/sessions"

CURRENT_OPENCLAW_VERSION="$(openclaw --version 2>/dev/null | head -1)"
echo "OpenClaw version: $CURRENT_OPENCLAW_VERSION"

# Make sure the directories that onboard used to create exist. These are
# referenced by the gateway and by agent runtime; missing them causes silent
# startup failures.
mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$SESSIONS_DIR"

# Archive any pre-existing config when the openclaw version changes, so a
# stricter schema can't poison startup. Paired-device state lives in the
# workspace directory and is preserved.
VERSION_MARKER="$CONFIG_DIR/.openclaw-version"
PREV_OPENCLAW_VERSION=""
[ -f "$VERSION_MARKER" ] && PREV_OPENCLAW_VERSION="$(cat "$VERSION_MARKER")"
if [ -f "$CONFIG_FILE" ] && { [ -z "$PREV_OPENCLAW_VERSION" ] || [ "$PREV_OPENCLAW_VERSION" != "$CURRENT_OPENCLAW_VERSION" ]; }; then
    BACKUP="$CONFIG_FILE.bak.$(date +%s)"
    echo "Config schema may be stale (prev=${PREV_OPENCLAW_VERSION:-<no marker>}, current=$CURRENT_OPENCLAW_VERSION), archiving to $BACKUP"
    mv "$CONFIG_FILE" "$BACKUP"
fi

# ============================================================
# WRITE CONFIG (replaces `openclaw onboard`)
# ============================================================
node << 'EOFGEN'
const fs = require('fs');
const path = require('path');

const configPath = '/root/.openclaw/openclaw.json';

// Read existing config if present (preserves anything we set last boot,
// e.g. paired devices that landed there). Strictly optional.
let config = {};
try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (_e) {
    config = {};
}

// ---- gateway ----
config.gateway = config.gateway || {};
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

config.gateway.controlUi = config.gateway.controlUi || {};
const allowedOrigins = ['*'];
if (process.env.WORKER_URL) {
    const o = process.env.WORKER_URL.replace(/\/+$/, '');
    if (!allowedOrigins.includes(o)) allowedOrigins.unshift(o);
}
config.gateway.controlUi.allowedOrigins = allowedOrigins;
// When the Worker fronts the gateway, the browser's Origin header gets
// proxied through but the gateway's allowlist match isn't reliable in
// 2026.4.29 (saw '*' in the config not being honored). The host-header
// fallback matches Origin.host against the Host header, which Workers
// preserves verbatim. This is safe here because the entire worker is
// already gated by Cloudflare Access + the gateway token.
config.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}
if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi.allowInsecureAuth = true;
}

// ---- providers / model ----
// Schema reference: https://docs.openclaw.ai/gateway/config-tools#custom-providers-and-base-urls
// 2026.4.29 requires the full model entry: id, name, reasoning, input, cost,
// contextWindow, contextTokens, maxTokens. Missing fields make the gateway
// exit silently after parsing. mode "merge" preserves the built-in catalog.
function buildModelEntry(opts) {
    const ctxWindow = opts.contextWindow;
    return {
        id: opts.id,
        name: opts.name || opts.id,
        reasoning: false,
        input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: ctxWindow,
        // contextTokens is the runtime budget; leave ~25% headroom for response.
        contextTokens: Math.floor(ctxWindow * 0.75),
        maxTokens: opts.maxTokens,
    };
}

config.models = config.models || {};
config.models.mode = config.models.mode || 'merge';
config.models.providers = config.models.providers || {};

let primaryModel = null;

// 1) TesseraAI / generic OpenAI-compatible
if (process.env.TESSERA_API_KEY && process.env.TESSERA_BASE_URL && process.env.TESSERA_MODEL) {
    const modelId = process.env.TESSERA_MODEL;
    config.models.providers.tessera = {
        baseUrl: process.env.TESSERA_BASE_URL.replace(/\/+$/, ''),
        apiKey: process.env.TESSERA_API_KEY,
        api: 'openai-completions',
        models: [buildModelEntry({
            id: modelId,
            contextWindow: parseInt(process.env.TESSERA_CONTEXT_WINDOW || '131072', 10),
            maxTokens: parseInt(process.env.TESSERA_MAX_TOKENS || '8192', 10),
        })],
    };
    primaryModel = 'tessera/' + modelId;
    console.log('Provider: tessera/' + modelId);
}

// 2) Anthropic direct
else if (process.env.ANTHROPIC_API_KEY) {
    config.models.providers.anthropic = {
        apiKey: process.env.ANTHROPIC_API_KEY,
        api: 'anthropic-messages',
        models: [buildModelEntry({ id: 'claude-sonnet-4-5', contextWindow: 200000, maxTokens: 8192 })],
    };
    if (process.env.ANTHROPIC_BASE_URL) {
        config.models.providers.anthropic.baseUrl = process.env.ANTHROPIC_BASE_URL;
    }
    primaryModel = 'anthropic/claude-sonnet-4-5';
    console.log('Provider: anthropic/claude-sonnet-4-5');
}

// 3) OpenAI direct
else if (process.env.OPENAI_API_KEY) {
    config.models.providers.openai = {
        apiKey: process.env.OPENAI_API_KEY,
        api: 'openai-completions',
        models: [buildModelEntry({ id: 'gpt-4o', contextWindow: 128000, maxTokens: 8192 })],
    };
    primaryModel = 'openai/gpt-4o';
    console.log('Provider: openai/gpt-4o');
}

// 4) Cloudflare AI Gateway
else if (process.env.CLOUDFLARE_AI_GATEWAY_API_KEY && process.env.CF_AI_GATEWAY_ACCOUNT_ID && process.env.CF_AI_GATEWAY_GATEWAY_ID) {
    const raw = process.env.CF_AI_GATEWAY_MODEL || 'anthropic/claude-sonnet-4-5';
    const slash = raw.indexOf('/');
    const gwProvider = raw.substring(0, slash);
    const modelId = raw.substring(slash + 1);
    let baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + process.env.CF_AI_GATEWAY_ACCOUNT_ID + '/' + process.env.CF_AI_GATEWAY_GATEWAY_ID + '/' + gwProvider;
    if (gwProvider === 'workers-ai') baseUrl += '/v1';
    const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
    const providerName = 'cf-ai-gw-' + gwProvider;
    config.models.providers[providerName] = {
        baseUrl: baseUrl,
        apiKey: process.env.CLOUDFLARE_AI_GATEWAY_API_KEY,
        api: api,
        models: [buildModelEntry({ id: modelId, contextWindow: 131072, maxTokens: 8192 })],
    };
    primaryModel = providerName + '/' + modelId;
    console.log('Provider: ' + primaryModel + ' via ' + baseUrl);
}

if (!primaryModel) {
    console.error('ERROR: no AI provider configured. Set TESSERA_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, or the CF_AI_GATEWAY_* trio.');
    process.exit(1);
}

config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = { primary: primaryModel };

// ---- channels ----
config.channels = config.channels || {};

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

if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') dm.allowFrom = ['*'];
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Config written to ' + configPath);
console.log('Gateway controlUi.allowedOrigins: ' + JSON.stringify(config.gateway.controlUi.allowedOrigins));
console.log('Channels enabled: ' + Object.keys(config.channels).join(',') || '(none)');
EOFGEN

# Stamp the version that wrote the config so we can detect drift on next boot.
echo "$CURRENT_OPENCLAW_VERSION" > "$VERSION_MARKER"

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway on port 18789..."
rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
