import json

config = {
    "public_hostname": "tg.kuban-forum.ru",
    "listen": "127.0.0.1:8090",
    "admin_listen": "127.0.0.1:8081",
    "public_dir": "/srv/tproxy-site",
    "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}

with open("/etc/tproxy-server/config.json", "w") as f:
    json.dump(config, f, indent=2)

print("Config written")
