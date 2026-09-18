import re

with open('/etc/caddy/Caddyfile') as f:
    content = f.read()

start = content.index('tg.kuban-forum.ru')
depth = 0
end = start
for i in range(start, len(content)):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break

old_block = content[start:end]
new_block = '''tg.kuban-forum.ru {
    header {
        -Via
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }
    reverse_proxy 127.0.0.1:8090 {
        transport http {
            response_header_timeout 120s
        }
    }
    handle_errors {
        header {
            Cache-Control "no-store"
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
        }
        respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
    }
}'''

content = content[:start] + new_block + content[end:]

with open('/etc/caddy/Caddyfile', 'w') as f:
    f.write(content)

print('Caddyfile updated')
