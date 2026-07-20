#!/usr/bin/env python3
"""Patch olcbox: add user/pass claims support to URI parser, LocationConfig, and YAML generator."""

import os
import sys

BASE = '/root/pj/olcbox'

# === 1. LocationConfig.kt ===
path = os.path.join(BASE, 'sharedUI/src/commonMain/kotlin/org/olcbox/app/data/model/LocationConfig.kt')
with open(path) as f:
    c = f.read()

# Add claimsUser, claimsPass fields
old = '''    @SerialName("vp8_batch")
    val vp8Batch: Int = DEFAULT_VP8_BATCH
) {'''
new = '''    @SerialName("vp8_batch")
    val vp8Batch: Int = DEFAULT_VP8_BATCH,
    @SerialName("claims_user")
    val claimsUser: String = "",
    @SerialName("claims_pass")
    val claimsPass: String = ""
) {'''
c = c.replace(old, new, 1)

# Add claims fields to normalized()
old = '''            vp8Fps = sanitizeVp8Fps(vp8Fps),
            vp8Batch = sanitizeVp8Batch(vp8Batch)
        )'''
new = '''            vp8Fps = sanitizeVp8Fps(vp8Fps),
            vp8Batch = sanitizeVp8Batch(vp8Batch),
            claimsUser = claimsUser.trim(),
            claimsPass = claimsPass.trim()
        )'''
c = c.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(c)
print('LocationConfig.kt: OK')


# === 2. LocationsDatasource.kt ===
path = os.path.join(BASE, 'sharedUI/src/commonMain/kotlin/org/olcbox/app/data/datasource/LocationsDatasource.kt')
with open(path) as f:
    c = f.read()

# Modify parseOlcRtcUri to extract user/pass from transport token
old = '''        val transportToken = payload.substring(transportMarker + 1, roomMarker).trim()
        val (transport, transportOptions) = parseTransportToken(transportToken)
        val roomId = payload.substring(roomMarker + 1, keyMarker).trim()'''

new = '''        val transportToken = payload.substring(transportMarker + 1, roomMarker).trim()
        val (transport, transportOptions) = parseTransportToken(transportToken)

        var claimsUser = ""
        var claimsPass = ""
        val plainTransport = transportToken.substringBefore('<').trim()
        val ampIdx = plainTransport.indexOf('&')
        if (ampIdx >= 0) {
            val params = plainTransport.substring(ampIdx + 1).split('&')
            for (param in params) {
                val eq = param.indexOf('=')
                if (eq <= 0) continue
                val key = param.substring(0, eq).trim().lowercase()
                val value = param.substring(eq + 1).trim()
                when (key) {
                    "user" -> claimsUser = value
                    "pass" -> claimsPass = value
                }
            }
        }

        val roomId = payload.substring(roomMarker + 1, keyMarker).trim()'''
c = c.replace(old, new, 1)

# Pass claimsUser/claimsPass to LocationConfig
old = '''        val location = LocationConfig(
            name = mimo.ifBlank { roomId },
            id = roomId,
            key = key,
            bypassProvider = provider,
            transport = transport,
            vp8Fps = transportOptions["vp8-fps"]
                ?: transportOptions["fps"]
                ?: LocationConfig.DEFAULT_VP8_FPS,
            vp8Batch = transportOptions["vp8-batch"]
                ?: transportOptions["batch"]
                ?: LocationConfig.DEFAULT_VP8_BATCH
        ).normalized()'''

new = '''        val location = LocationConfig(
            name = mimo.ifBlank { roomId },
            id = roomId,
            key = key,
            bypassProvider = provider,
            transport = transport,
            vp8Fps = transportOptions["vp8-fps"]
                ?: transportOptions["fps"]
                ?: LocationConfig.DEFAULT_VP8_FPS,
            vp8Batch = transportOptions["vp8-batch"]
                ?: transportOptions["batch"]
                ?: LocationConfig.DEFAULT_VP8_BATCH,
            claimsUser = claimsUser,
            claimsPass = claimsPass
        ).normalized()'''
c = c.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(c)
print('LocationsDatasource.kt: OK')


# === 3. OlcRtcCommand.kt ===
path = os.path.join(BASE, 'sharedUI/src/jvmMain/kotlin/org/olcbox/app/vpn/desktop/OlcRtcCommand.kt')
with open(path) as f:
    c = f.read()

# Add claimsUser/claimsPass to data class
old = '''internal data class OlcRtcCommand(
    val binary: Path,
    val location: LocationConfig,
    val socksHost: String = PacServer.LOCAL_SOCKS_HOST,
    val socksPort: Int = PacServer.LOCAL_SOCKS_PORT,
    val socksUser: String = "",
    val socksPass: String = "",
    val dnsServer: String,
    val dataDir: Path? = null
) {'''
new = '''internal data class OlcRtcCommand(
    val binary: Path,
    val location: LocationConfig,
    val socksHost: String = PacServer.LOCAL_SOCKS_HOST,
    val socksPort: Int = PacServer.LOCAL_SOCKS_PORT,
    val socksUser: String = "",
    val socksPass: String = "",
    val dnsServer: String,
    val dataDir: Path? = null,
    val claimsUser: String = "",
    val claimsPass: String = ""
) {'''
c = c.replace(old, new, 1)

# Add claims section to yaml()
old = '''            appendLine("crypto:")
            appendLine("  key: ${config.key.yamlValue()}")
            appendLine("net:")'''
new = '''            appendLine("crypto:")
            appendLine("  key: ${config.key.yamlValue()}")
            if (claimsUser.isNotBlank()) {
                appendLine("claims:")
                appendLine("  user: ${claimsUser.yamlValue()}")
                appendLine("  pass: ${claimsPass.yamlValue()}")
            }
            appendLine("net:")'''
c = c.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(c)
print('OlcRtcCommand.kt: OK')


# === 4. DesktopVpnManager.kt — thread claims ===
path = os.path.join(BASE, 'sharedUI/src/jvmMain/kotlin/org/olcbox/app/vpn/DesktopVpnManager.kt')
with open(path) as f:
    c = f.read()

# Pass claims from location to OlcRtcCommand
old = '''        val olcRtcCommand = OlcRtcCommand(
            binary = binary,
            location = config,
            socksHost = socksSettings.host,
            socksPort = socksSettings.port,
            socksUser = socksSettings.username,
            socksPass = socksSettings.password,
            dnsServer = dnsServer,
            dataDir = dataDir
        )'''
new = '''        val olcRtcCommand = OlcRtcCommand(
            binary = binary,
            location = config,
            socksHost = socksSettings.host,
            socksPort = socksSettings.port,
            socksUser = socksSettings.username,
            socksPass = socksSettings.password,
            dnsServer = dnsServer,
            dataDir = dataDir,
            claimsUser = config.claimsUser,
            claimsPass = config.claimsPass
        )'''
c = c.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(c)
print('DesktopVpnManager.kt: OK')


# === 5. OlcRtcConnectionChecker.kt (JVM) ===
path = os.path.join(BASE, 'sharedUI/src/jvmMain/kotlin/org/olcbox/app/vpn/OlcRtcConnectionChecker.kt')
with open(path) as f:
    c = f.read()

# Find the startOlcRtcProcessWithFallback method and add claims threading
# Look for the part where OlcRtcCommand is created in the ping helper
old = '''    private suspend fun pingOnce(
        config: LocationConfig,
        privileged: Boolean
    ): Long = coroutineScope {'''
new = '''    private suspend fun pingOnce(
        config: LocationConfig,
        privileged: Boolean
    ): Long = coroutineScope {'''
c = c.replace(old, new, 1)

# Find the process start section in pingOnce
old = '''        val ready = CompletableDeferred<Unit>()

        val process = startOlcRtcProcessWithFallback(
            scope = this,
            config = config,
            socksPort = socksPort,
            ready = ready,
            privileged = privileged
        )'''
new = '''        val ready = CompletableDeferred<Unit>()

        val process = startOlcRtcProcessWithFallback(
            scope = this,
            config = config,
            socksPort = socksPort,
            ready = ready,
            privileged = privileged,
            claimsUser = config.claimsUser,
            claimsPass = config.claimsPass
        )'''
c = c.replace(old, new, 1)

# Find and update checkOnce process start in the same file
old = '''        val process = startOlcRtcProcessWithFallback(
            scope = this,
            config = config,
            socksPort = socksPort,
            ready = ready,
            privileged = privileged
        )

        val startedAt = System.currentTimeMillis()'''
new = '''        val process = startOlcRtcProcessWithFallback(
            scope = this,
            config = config,
            socksPort = socksPort,
            ready = ready,
            privileged = privileged,
            claimsUser = config.claimsUser,
            claimsPass = config.claimsPass
        )

        val startedAt = System.currentTimeMillis()'''
c = c.replace(old, new, 1)

# Update startOlcRtcProcessWithFallback function signature
old = '''    private suspend fun startOlcRtcProcessWithFallback(
        scope: CoroutineScope,
        config: LocationConfig,
        socksPort: Int,
        ready: CompletableDeferred<Unit>,
        privileged: Boolean
    ): Process {'''
new = '''    private suspend fun startOlcRtcProcessWithFallback(
        scope: CoroutineScope,
        config: LocationConfig,
        socksPort: Int,
        ready: CompletableDeferred<Unit>,
        privileged: Boolean,
        claimsUser: String = "",
        claimsPass: String = ""
    ): Process {'''
c = c.replace(old, new, 1)

# Find where OlcRtcCommand is created inside startOlcRtcProcessWithFallback
old = '''        val command = OlcRtcCommand(
            binary = olcrtcBinary,
            location = config,
            socksHost = PacServer.LOCAL_SOCKS_HOST,
            socksPort = socksPort,
            dnsServer = DesktopNativeAssets.DEFAULT_DNS,
            dataDir = dataDir
        )'''
new = '''        val command = OlcRtcCommand(
            binary = olcrtcBinary,
            location = config,
            socksHost = PacServer.LOCAL_SOCKS_HOST,
            socksPort = socksPort,
            dnsServer = DesktopNativeAssets.DEFAULT_DNS,
            dataDir = dataDir,
            claimsUser = claimsUser,
            claimsPass = claimsPass
        )'''
c = c.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(c)
print('OlcRtcConnectionChecker.kt: OK')

print('\nAll patches applied successfully!')
