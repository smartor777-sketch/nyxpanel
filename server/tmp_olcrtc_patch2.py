#!/usr/bin/env python3
"""Continue patching olcRTC: server.go auth hook."""
import os

ROOT = '/root/pj/olcrtc'

# ============================================================
# server.go — add UsersFile field + create AuthHook that reads users.json
# ============================================================
server_path = os.path.join(ROOT, 'internal/server/server.go')
with open(server_path) as f:
    sv = f.read()

# Add UsersFile to Config struct
old_server_config = '''// Config holds runtime configuration for [Run].
type Config struct {
	Transport        string
	Carrier          string
	RoomURL          string
	ChannelID        string
	KeyHex           string
	DNSServer        string
	SOCKSProxyAddr   string
	SOCKSProxyPort   int
	SOCKSProxyUser   string
	SOCKSProxyPass   string
	TransportOptions transport.Options
	Engine           string
	URL              string
	Token            string
	AuthToken        string
	Liveness         control.Config
	Traffic          transport.TrafficConfig

	// AuthHook is invoked after CLIENT_HELLO to authorize the client and
	// return a session ID. If nil, every client is admitted with a random UUID.
	AuthHook handshake.AuthFunc'''  # no commas needed
new_server_config = '''// Config holds runtime configuration for [Run].
type Config struct {
	Transport        string
	Carrier          string
	RoomURL          string
	ChannelID        string
	KeyHex           string
	DNSServer        string
	SOCKSProxyAddr   string
	SOCKSProxyPort   int
	SOCKSProxyUser   string
	SOCKSProxyPass   string
	TransportOptions transport.Options
	Engine           string
	URL              string
	Token            string
	AuthToken        string
	Liveness         control.Config
	Traffic          transport.TrafficConfig

	// UsersFile is a path to a JSON file mapping username -> password.
	// When set, per-user authentication is enforced; otherwise all clients are admitted.
	UsersFile string

	// AuthHook is invoked after CLIENT_HELLO to authorize the client and
	// return a session ID. If nil, every client is admitted with a random UUID.
	AuthHook handshake.AuthFunc'''

print(f"old_server_config in sv: {old_server_config in sv}")
assert old_server_config in sv, 'Server Config struct not found'
sv = sv.replace(old_server_config, new_server_config, 1)

# Add UsersFile handling in Run function
old_hook = '''\thook := cfg.AuthHook
\tif hook == nil {
\t\thook = defaultAuthHook
\t}'''
new_hook = '''\thook := cfg.AuthHook
\tif cfg.UsersFile != "" {
\t\thook = createFileAuthHook(cfg.UsersFile)
\t} else if hook == nil {
\t\thook = defaultAuthHook
\t}'''
assert old_hook in sv, 'hook initialization not found'
sv = sv.replace(old_hook, new_hook, 1)

# Add "os" import
old_imports = '''"net"
\t"sort"
\t"strconv"
\t"strings"
\t"sync"
\t"time"

\t"github.com/google/uuid"'''
new_imports = '''"net"
\t"os"
\t"sort"
\t"strconv"
\t"strings"
\t"sync"
\t"time"

\t"github.com/google/uuid"'''
assert old_imports in sv, 'imports not found'
sv = sv.replace(old_imports, new_imports, 1)

# Add createFileAuthHook before setupCipher
old_setup_cipher = '''func setupCipher(keyHex string) (*crypto.Cipher, error) {'''
new_setup_cipher = '''// createFileAuthHook returns an AuthFunc that validates client claims
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
assert old_setup_cipher in sv, 'setupCipher not found'
sv = sv.replace(old_setup_cipher, new_setup_cipher, 1)

with open(server_path, 'w') as f:
    f.write(sv)
print('server.go: OK')
