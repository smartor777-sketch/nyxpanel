-- We need this for prosody 13.0
component_admins_as_room_owners = true

plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

-- domain mapper options, must at least have domain base set to use the mapper
muc_mapper_domain_base = "nyx.kuban-forum.ru";

external_service_secret = "9oweW1vgCvCW2l62";
external_services = {
     { type = "stun", host = "nyx.kuban-forum.ru", port = 3478 },
     { type = "turn", host = "nyx.kuban-forum.ru", port = 3478, transport = "udp", secret = true, ttl = 86400, algorithm = "turn" },
     { type = "turns", host = "nyx.kuban-forum.ru", port = 5349, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
};

cross_domain_bosh = false;
consider_bosh_secure = true;
consider_websocket_secure = true;

ssl = {
    certificate = "/etc/prosody/certs/nyx.kuban-forum.ru.crt";
    key = "/etc/prosody/certs/nyx.kuban-forum.ru.key";
    protocol = "tlsv1_2+";
    ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"
}

unlimited_jids = {
    "focus@auth.nyx.kuban-forum.ru",
    "jvb@auth.nyx.kuban-forum.ru"
}

-- https://prosody.im/doc/modules/mod_smacks
smacks_max_unacked_stanzas = 5;
smacks_hibernation_time = 60;
smacks_max_old_sessions = 1;

VirtualHost "nyx.kuban-forum.ru"
    authentication = "jitsi-anonymous" -- do not delete me
    allow_unencrypted_plain_auth = true
    ssl = {
        key = "/etc/prosody/certs/nyx.kuban-forum.ru.key";
        certificate = "/etc/prosody/certs/nyx.kuban-forum.ru.crt";
    }
    -- we need bosh
    modules_enabled = {
        "tls";
        "saslauth";
        "bosh";
        "websocket";
        "smacks";
        "ping"; -- Enable mod_ping
        "external_services";
        "features_identity";
        "conference_duration";
        "muc_lobby_rooms";
        "muc_breakout_rooms";
    }
    c2s_require_encryption = false
    lobby_muc = "lobby.nyx.kuban-forum.ru"
    breakout_rooms_muc = "breakout.nyx.kuban-forum.ru"
    main_muc = "conference.nyx.kuban-forum.ru"

Component "conference.nyx.kuban-forum.ru" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "muc_meeting_id";
        "muc_domain_mapper";
        "muc_rate_limit";
        "muc_password_whitelist";
    }
    admins = { "focus@auth.nyx.kuban-forum.ru" }
    muc_password_whitelist = {
        "focus@auth.nyx.kuban-forum.ru"
    }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "breakout.nyx.kuban-forum.ru" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "muc_meeting_id";
        "muc_domain_mapper";
        "muc_rate_limit";
    }
    admins = { "focus@auth.nyx.kuban-forum.ru" }
    muc_room_locking = false
    muc_room_default_public_jids = true

-- internal muc component
Component "internal.auth.nyx.kuban-forum.ru" "muc"
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "ping";
    }
    admins = { "focus@auth.nyx.kuban-forum.ru", "jvb@auth.nyx.kuban-forum.ru" }
    muc_room_locking = false
    muc_room_default_public_jids = true

VirtualHost "auth.nyx.kuban-forum.ru"
    allow_unencrypted_plain_auth = true
    ssl = {
        key = "/etc/prosody/certs/auth.nyx.kuban-forum.ru.key";
        certificate = "/etc/prosody/certs/auth.nyx.kuban-forum.ru.crt";
    }
    modules_enabled = {
        "tls";
        "saslauth";
        "limits_exception";
        "smacks";
    }
    authentication = "internal_hashed"
    smacks_hibernation_time = 15;

VirtualHost "recorder.nyx.kuban-forum.ru"
    modules_enabled = {
      "smacks";
    }
    authentication = "internal_hashed"
    smacks_max_old_sessions = 2000;

-- Proxy to jicofo's user JID, so that it doesn't have to register as a component.
Component "focus.nyx.kuban-forum.ru" "client_proxy"
    target_address = "focus@auth.nyx.kuban-forum.ru"

Component "speakerstats.nyx.kuban-forum.ru" "speakerstats_component"
    muc_component = "conference.nyx.kuban-forum.ru"

Component "endconference.nyx.kuban-forum.ru" "end_conference"
    muc_component = "conference.nyx.kuban-forum.ru"

Component "avmoderation.nyx.kuban-forum.ru" "av_moderation_component"
    muc_component = "conference.nyx.kuban-forum.ru"

Component "filesharing.nyx.kuban-forum.ru" "filesharing_component"
    muc_component = "conference.nyx.kuban-forum.ru"

Component "lobby.nyx.kuban-forum.ru" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true
    modules_enabled = {
        "muc_hide_all";
        "muc_rate_limit";
    }

Component "metadata.nyx.kuban-forum.ru" "room_metadata_component"
    muc_component = "conference.nyx.kuban-forum.ru"
    breakout_rooms_component = "breakout.nyx.kuban-forum.ru"

Component "polls.nyx.kuban-forum.ru" "polls_component"
