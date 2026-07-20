#!/bin/bash
UUID='6276429c-b022-4425-880f-81d04a45802c'
HOST='76t05pyu.ikill.baby'
PORT='443'
SNI='www.microsoft.com'
PBK='iqmUrTnhYDcm-hhuGJaze6dTGNIcvyMOyYIN7LB4kU4'
SID='2e30b986cabb4bca'
FLOW='xtls-rprx-vision'
NAME='test-vless'
LINK="vless://${UUID}@${HOST}:${PORT}?security=reality&flow=${FLOW}&type=tcp&sni=${SNI}&pbk=${PBK}&sid=${SID}&fp=chrome#${NAME}"
echo "$LINK"
qrencode -t UTF8 "$LINK" 2>/dev/null || echo '(qrencode not installed)'
cat > /root/proxy_users/test/test_vless_link.sh << EOF
#!/bin/bash
echo "$LINK"
EOF
chmod +x /root/proxy_users/test/test_vless_link.sh
echo "Link saved"
