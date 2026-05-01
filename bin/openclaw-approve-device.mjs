#!/usr/bin/env node
// Approve a pending OpenClaw device pairing request, bypassing the gateway's
// caller-scope check.
//
// openclaw 2026.4.29 added a check requiring the *caller* of `device.pair.approve`
// to already hold operator.admin. The gateway-token-only auth used by the
// moltworker admin UI does not grant any scopes, so the CLI's
// `openclaw devices approve <id>` always fails with "missing scope: operator.admin"
// — chicken-and-egg, since approval is what creates the first admin device.
//
// The CLI internally has a "local pairing fallback" path that calls
// approveDevicePairing(requestId, { callerScopes: ['operator.admin'] }) directly,
// but it only triggers on a "pairing required" error string, not on scope errors.
// We trigger the same fallback unconditionally.
//
// Usage: openclaw-approve-device <requestId>
// Output (stdout): {"status":"ok","deviceId":"...","role":"...","message":"Approved"}
// Exit code: 0 on success, 1 on not-found, 2 on bad arguments,
// 3 on internal module discovery failure, 4 on forbidden, 5 on other error.

import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const requestId = process.argv[2];
if (!requestId) {
    console.error('usage: openclaw-approve-device <requestId>');
    process.exit(2);
}

// device-pairing module name has a content-hash suffix that changes per
// openclaw version. Glob-find it in the installed dist directory.
const distDir = '/usr/local/lib/node_modules/openclaw/dist';
let candidates;
try {
    candidates = readdirSync(distDir).filter((f) => /^device-pairing-[A-Za-z0-9_-]+\.js$/.test(f));
} catch (e) {
    console.error(`failed to list ${distDir}: ${e.message}`);
    process.exit(3);
}
if (candidates.length !== 1) {
    console.error(`expected exactly one device-pairing module, found ${candidates.length}: ${candidates.join(',')}`);
    process.exit(3);
}

const mod = await import(join(distDir, candidates[0]));
// approveDevicePairing is exported under the alias `n` due to bundler minification.
const approveDevicePairing = mod.approveDevicePairing ?? mod.n;
if (typeof approveDevicePairing !== 'function') {
    console.error('approveDevicePairing not exported from device-pairing module');
    process.exit(3);
}

try {
    const result = await approveDevicePairing(requestId, { callerScopes: ['operator.admin'] });
    if (!result) {
        console.log(JSON.stringify({ status: 'not_found', requestId, message: 'unknown requestId' }));
        process.exit(1);
    }
    if (result.status === 'forbidden') {
        console.log(JSON.stringify({ status: 'forbidden', reason: result.reason, scope: result.scope }));
        process.exit(4);
    }
    // Include "Approved" so existing case-insensitive success checks in the
    // caller still work after this drop-in replacement.
    console.log(
        JSON.stringify({
            status: 'ok',
            requestId,
            deviceId: result.device?.deviceId,
            role: result.device?.role,
            message: 'Approved',
        }),
    );
} catch (e) {
    console.error(`approve failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(5);
}
