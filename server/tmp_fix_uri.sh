#!/bin/bash
UUID=$(python3 -c "import json; print(json.load(open('/etc/xray/users.json'))['test'])")
URI="vless://${UUID}@76t05pyu.ikill.baby:443?security=reality&type=xhttp&path=%2Fvless&sni=1.1.1.1&fp=chrome&pbk=iqmUrTnhYDcm-hhuGJaze6dTGNIcvyMOyYIN7LB4kU4&sid=2e30b986cabb4bca&spx=%2Fdns-query%2F#test"
echo "$URI" > /root/proxy_users/test/test_vless.uri
qrencode -t PNG -o /root/proxy_users/test/test_vless.png "$URI"
echo "OK: $URI"
