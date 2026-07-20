#!/usr/bin/env python3
"""Fix server.go imports and auth hook."""
import os

ROOT = '/root/pj/olcrtc'
server_path = os.path.join(ROOT, 'internal/server/server.go')
with open(server_path) as f:
    sv = f.read()

# Add "os" import — match actual content with tabs
old_imports = '\t"net"\n\t"sort"\n\t"strconv"\n\t"strings"\n\t"sync"\n\t"time"\n\n\t"github.com/google/uuid"'
new_imports = '\t"net"\n\t"os"\n\t"sort"\n\t"strconv"\n\t"strings"\n\t"sync"\n\t"time"\n\n\t"github.com/google/uuid"'
print(f"imports match: {old_imports in sv}")
assert old_imports in sv, 'imports pattern not found'
sv = sv.replace(old_imports, new_imports, 1)

# Add UsersFile to Config struct
old_server_config = '\t// AuthHook is invoked after CLIENT_HELLO to authorize the client and\n\t// return a session ID. If nil, every client is admitted with a random UUID.\n\tAuthHook handshake.AuthFunc'
new_server_config = '\t// UsersFile is a path to a JSON file mapping username -> password.\n\t// When set, per-user authentication is enforced; otherwise all clients are admitted.\n\tUsersFile string\n\n\t// AuthHook is invoked after CLIENT_HELLO to authorize the client and\n\t// return a session ID. If nil, every client is admitted with a random UUID.\n\tAuthHook handshake.AuthFunc'
print(f"config match: {old_server_config in sv}")
assert old_server_config in sv, 'Config AuthHook field not found'
sv = sv.replace(old_server_config, new_server_config, 1)

# Add UsersFile handling in Run function
old_hook = '\thook := cfg.AuthHook\n\tif hook == nil {\n\t\thook = defaultAuthHook\n\t}'
new_hook = '\thook := cfg.AuthHook\n\tif cfg.UsersFile != "" {\n\t\thook = createFileAuthHook(cfg.UsersFile)\n\t} else if hook == nil {\n\t\thook = defaultAuthHook\n\t}'
print(f"hook match: {old_hook in sv}")
assert old_hook in sv, 'hook init not found'
sv = sv.replace(old_hook, new_hook, 1)

# Add createFileAuthHook before setupCipher
old_setup = 'func setupCipher(keyHex string) (*crypto.Cipher, error) {'
new_setup = '''// createFileAuthHook returns an AuthFunc that validates client claims
// against a JSON file mapping usernames to passwords.
func createFileAuthHook(path string) handshake.AuthFunc {
\treturn func(deviceID string, claims map[string]any) (string, error) {
\t\tuser, _ := claims["user"].(string)
\t\tpass, _ := claims["pass"].(string)
\t\tif user == "" || pass == "" {
\t\t\treturn "", fmt.Errorf("missing 'user' or 'pass' in claims")
\t\t}
\t\tdata, err := os.ReadFile(path)
\t\tif err != nil {
\t\t\treturn "", fmt.Errorf("read users file: %w", err)
\t\t}
\t\tvar users map[string]string
\t\tif err := json.Unmarshal(data, &users); err != nil {
\t\t\treturn "", fmt.Errorf("parse users file: %w", err)
\t\t}
\t\texpected, ok := users[user]
\t\tif !ok || expected != pass {
\t\t\treturn "", fmt.Errorf("auth failed for user %q", user)
\t\t}
\t\treturn user, nil
\t}
}

func setupCipher(keyHex string) (*crypto.Cipher, error) {'''
print(f"setupCipher match: {old_setup in sv}")
assert old_setup in sv, 'setupCipher not found'
sv = sv.replace(old_setup, new_setup, 1)

with open(server_path, 'w') as f:
    f.write(sv)
print('server.go: OK')
