-- Prosody main config
c2s_require_encryption = false

ssl = {
    certificate = "/var/lib/prosody/vpn.example.com.crt";
    key = "/var/lib/prosody/vpn.example.com.key";
}

modules_enabled = {
    "http";
    "bosh";
    "websocket";
}

Include "conf.d/*.cfg.lua"
