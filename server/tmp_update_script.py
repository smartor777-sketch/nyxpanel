#!/usr/bin/env python3
"""Edit proxy_manager.sh to use userpass auth for Hysteria 2."""
import re

with open('/root/proxy_manager.sh', 'r') as f:
    content = f.read()

# === Change 1: add_hy2_user — generate individual password, add to userpass ===
old_hy2 = '''add_hy2_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_hy2.json" ]; then
        echo -e "${YELLOW}Hysteria 2 уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки Hysteria 2 для '$username'...${NC}"
    
    local global_password=$(yq '.auth.password' "$HY2_CONFIG" | tr -d '"')
    if [ -z "$global_password" ] || [ "$global_password" == "null" ]; then
        echo -e "${RED}Не удалось прочитать пароль из конфига.${NC}"; return 1; fi

    local server_port=$(yq '.listen' "$HY2_CONFIG" | tr -d ':"' | grep -oE '[0-9]+')
    [ -z "$server_port" ] && server_port=443

    local obfs_type=$(yq '.obfs.type' "$HY2_CONFIG" | tr -d '"')
    local obfs_pass=""
    if [ "$obfs_type" = "salamander" ]; then
        obfs_pass=$(yq '.obfs.salamander.password // .obfs.password' "$HY2_CONFIG" | tr -d '"')
    fi

    local user_dir="$BASE_DIR/$username"
    local tag_name="pxy-hy2 - $username"

    jq -n \\
      --arg tag_val "$tag_name" --arg server_val "$SERVER_DOMAIN" --argjson port_val "$server_port" \\
      --arg pass_val "$global_password" --arg obfs_type_val "$obfs_type" --arg obfs_pass_val "$obfs_pass" \\
      '{
        outbounds: [
          {
            type: "hysteria2", tag: $tag_val, server: $server_val, server_port: $port_val
          } +
          (if $obfs_type_val != "" and $obfs_type_val != "null" and $obfs_pass_val != "" and $obfs_pass_val != "null" then
             { obfs: { type: $obfs_type_val, password: $obfs_pass_val } }
           else {} end) +
          {
            password: $pass_val,
            tls: { enabled: true, server_name: $server_val }
          }
        ]
      }' > "$user_dir/${username}_hy2_temp.json"

    jq . "$user_dir/${username}_hy2_temp.json" > "$user_dir/${username}_hy2.json"
    generate_qr "$(jq -c . "$user_dir/${username}_hy2_temp.json")" "$user_dir/${username}_hy2.png"
    rm "$user_dir/${username}_hy2_temp.json"
    echo -e "${GREEN}Готово! Конфиг и QR-код Hysteria 2 сохранены.${NC}"
}'''

new_hy2 = '''add_hy2_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_hy2.json" ]; then
        echo -e "${YELLOW}Hysteria 2 уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки Hysteria 2 для '$username'...${NC}"
    
    local password=$(openssl rand -hex 12)

    local server_port=$(yq '.listen' "$HY2_CONFIG" | tr -d ':"' | grep -oE '[0-9]+')
    [ -z "$server_port" ] && server_port=443

    local obfs_type=$(yq '.obfs.type' "$HY2_CONFIG" | tr -d '"')
    local obfs_pass=""
    if [ "$obfs_type" = "salamander" ]; then
        obfs_pass=$(yq '.obfs.salamander.password // .obfs.password' "$HY2_CONFIG" | tr -d '"')
    fi

    jq --arg user "$username" --arg pass "$password" \\
      '.auth.userpass[$user] = $pass' \\
      "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
    systemctl restart hysteria-server

    local user_dir="$BASE_DIR/$username"
    local tag_name="pxy-hy2 - $username"
    local auth_str="${username}:${password}"

    jq -n \\
      --arg tag_val "$tag_name" --arg server_val "$SERVER_DOMAIN" --argjson port_val "$server_port" \\
      --arg pass_val "$auth_str" --arg obfs_type_val "$obfs_type" --arg obfs_pass_val "$obfs_pass" \\
      '{
        outbounds: [
          {
            type: "hysteria2", tag: $tag_val, server: $server_val, server_port: $port_val
          } +
          (if $obfs_type_val != "" and $obfs_type_val != "null" and $obfs_pass_val != "" and $obfs_pass_val != "null" then
             { obfs: { type: $obfs_type_val, password: $obfs_pass_val } }
           else {} end) +
          {
            password: $pass_val,
            tls: { enabled: true, server_name: $server_val }
          }
        ]
      }' > "$user_dir/${username}_hy2_temp.json"

    jq . "$user_dir/${username}_hy2_temp.json" > "$user_dir/${username}_hy2.json"
    generate_qr "$(jq -c . "$user_dir/${username}_hy2_temp.json")" "$user_dir/${username}_hy2.png"
    rm "$user_dir/${username}_hy2_temp.json"
    echo -e "${GREEN}Готово! Конфиг и QR-код Hysteria 2 сохранены.${NC}"
}'''

assert old_hy2 in content, "old_hy2 block not found!"
content = content.replace(old_hy2, new_hy2, 1)
print("Change 1 (add_hy2_user): OK")

# === Change 2: remove_protocol hy2 case — remove from userpass ===
old_rm = '''        hy2)
            rm -f "$BASE_DIR/$username/${username}_hy2.json"
            rm -f "$BASE_DIR/$username/${username}_hy2.png"
            echo -e "${GREEN}Конфигурация Hysteria 2 удалена.${NC}"
            ;;'''

new_rm = '''        hy2)
            jq --arg user "$username" 'del(.auth.userpass[$user])' \\
              "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
            systemctl restart hysteria-server
            rm -f "$BASE_DIR/$username/${username}_hy2.json"
            rm -f "$BASE_DIR/$username/${username}_hy2.png"
            echo -e "${GREEN}Конфигурация Hysteria 2 удалена.${NC}"
            ;;'''

assert old_rm in content, "old_rm block not found!"
content = content.replace(old_rm, new_rm, 1)
print("Change 2 (remove_protocol hy2): OK")

# === Change 3: del_user — add hy2 cleanup before folder deletion ===
old_del = '''    # 5. Удаляем папку с ключами и файлами
    rm -rf "$target_dir"'''

new_del = '''    # 5. Удаляем из Hysteria 2 (если есть)
    if [ -f "$target_dir/${username}_hy2.json" ] && [ -f "$HY2_CONFIG" ]; then
        jq --arg user "$username" 'del(.auth.userpass[$user])' \\
          "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
        systemctl restart hysteria-server
        echo -e "${GREEN}Удален из Hysteria 2.${NC}"
    fi

    # 6. Удаляем папку с ключами и файлами
    rm -rf "$target_dir"'''

assert old_del in content, "old_del block not found!"
content = content.replace(old_del, new_del, 1)
print("Change 3 (del_user hy2): OK")

with open('/root/proxy_manager.sh', 'w') as f:
    f.write(content)

print("=== All changes applied successfully ===")
