import subprocess

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Generate keys and fix the config
cmds = [
    'KEYS=$(/usr/local/bin/xray x25519); PRIV=$(echo "$KEYS" | grep "^PrivateKey" | awk "{print \$2}"); PUB=$(echo "$KEYS" | grep "PublicKey" | awk "{print \$NF}"); echo "PRIV=[$PRIV] PUB=[$PUB]"; python3 -c "
import json
cfg = json.load(open(\"/usr/local/etc/xray/config.json\"))
r = cfg[\"inbounds\"][0][\"streamSettings\"][\"realitySettings\"]
r[\"privateKey\"] = \"'$PRIV'\"
json.dump(cfg, open(\"/usr/local/etc/xray/config.json\",\"w\"), indent=2)
"; systemctl restart xray; sleep 1; systemctl is-active xray',
]

for cmd in cmds:
    r = subprocess.run(plink + [cmd], capture_output=True, text=True, timeout=30)
    print(r.stdout)
    if r.stderr:
        print('ERR:', r.stderr[:300])
