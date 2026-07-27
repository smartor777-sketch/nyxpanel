-- We need this for prosody 13.0
component_admins_as_room_owners = true

plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

-- domain mapper options, must at least have domain base set to use the mapper
muc_mapper_domain_base = "vpn.example.com";

external_service_secret = "9oweW1vgCvCW2l62";
external_services = {
     { type = "stun", host = "vpn.example.com", port = 3478 },
     { type = "turn", host = "vpn.example.com", port = 3478, transport = "udp", secret = true, ttl = 86400, algorithm = "turn" },
     { type = "turns", host = "vpn.example.com", port = 5349, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
};

cross_domain_bosh = false;
consider_bosh_secure = true;
consider_websocket_secure = true;

ssl = {
    certificate = "/etc/prosody/certs/vpn.example.com.crt";
    key = "/etc/prosody/certs/vpn.example.com.key";
    protocol = "tlsv1_2+";
    ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"
}

unlimited_jids = {
    "focus@auth.vpn.example.com",
    "jvb@auth.vpn.example.com"
}

-- https://prosody.im/doc/modules/mod_smacks
smacks_max_unacked_stanzas = 5;
smacks_hibernation_time = 60;
smacks_max_old_sessions = 1;

VirtualHost "vpn.example.com"
    authentication = "jitsi-anonymous" -- do not delete me
    allow_unencrypted_plain_auth = true
    ssl = {
        key = "/etc/prosody/certs/vpn.example.com.key";
        certificate = "/etc/prosody/certs/vpn.example.com.crt";
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
    lobby_muc = "lobby.vpn.example.com"
    breakout_rooms_muc = "breakout.vpn.example.com"
    main_muc = "conference.vpn.example.com"

Component "conference.vpn.example.com" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "muc_meeting_id";
        "muc_domain_mapper";
        "muc_rate_limit";
        "muc_password_whitelist";
    }
    admins = { "focus@auth.vpn.example.com" }
    muc_password_whitelist = {
        "focus@auth.vpn.example.com"
    }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "breakout.vpn.example.com" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "muc_meeting_id";
        "muc_domain_mapper";
        "muc_rate_limit";
    }
    admins = { "focus@auth.vpn.example.com" }
    muc_room_locking = false
    muc_room_default_public_jids = true

-- internal muc component
Component "internal.auth.vpn.example.com" "muc"
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "ping";
    }
    admins = { "focus@auth.vpn.example.com", "jvb@auth.vpn.example.com" }
    muc_room_locking = false
    muc_room_default_public_jids = true

VirtualHost "auth.vpn.example.com"
    allow_unencrypted_plain_auth = true
    ssl = {
        key = "/etc/prosody/certs/auth.vpn.example.com.key";
        certificate = "/etc/prosody/certs/auth.vpn.example.com.crt";
    }
    modules_enabled = {
        "tls";
        "saslauth";
        "limits_exception";
        "smacks";
    }
    authentication = "internal_hashed"
    smacks_hibernation_time = 15;

VirtualHost "recorder.vpn.example.com"
    modules_enabled = {
      "smacks";
    }
    authentication = "internal_hashed"
    smacks_max_old_sessions = 2000;

-- Proxy to jicofo's user JID, so that it doesn't have to register as a component.
Component "focus.vpn.example.com" "client_proxy"
    target_address = "focus@auth.vpn.example.com"

Component "speakerstats.vpn.example.com" "speakerstats_component"
    muc_component = "conference.vpn.example.com"

Component "endconference.vpn.example.com" "end_conference"
    muc_component = "conference.vpn.example.com"

Component "avmoderation.vpn.example.com" "av_moderation_component"
    muc_component = "conference.vpn.example.com"

Component "filesharing.vpn.example.com" "filesharing_component"
    muc_component = "conference.vpn.example.com"

Component "lobby.vpn.example.com" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true
    modules_enabled = {
        "muc_hide_all";
        "muc_rate_limit";
    }

Component "metadata.vpn.example.com" "room_metadata_component"
    muc_component = "conference.vpn.example.com"
    breakout_rooms_component = "breakout.vpn.example.com"

Component "polls.vpn.example.com" "polls_component"
