-- Prosody main config
c2s_require_encryption = false

ssl = {
    certificate = "/var/lib/prosody/nyx.kuban-forum.ru.crt";
    key = "/var/lib/prosody/nyx.kuban-forum.ru.key";
}

modules_enabled = {
    "http";
    "bosh";
    "websocket";
}

Include "conf.d/*.cfg.lua"
