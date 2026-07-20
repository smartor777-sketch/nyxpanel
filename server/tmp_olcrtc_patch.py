#!/usr/bin/env python3
"""Patch olcRTC source to add per-user auth: claims in client config + users_file auth on server."""

import os

ROOT = '/root/pj/olcrtc'

# ============================================================
# 1. session.go — add Claims + UsersFile to Config, wire to client.Run / server.Run
# ============================================================
session_path = os.path.join(ROOT, 'internal/app/session/session.go')
with open(session_path) as f:
    s = f.read()

# Add Claims and UsersFile fields to Config struct
old_config = '''// Config holds runtime session settings.
type Config struct {
	Mode                  string
	Transport             string
	Auth                  string
	AuthToken             string'''
new_config = '''// Config holds runtime session settings.
type Config struct {
	Mode                  string
	Transport             string
	Auth                  string
	AuthToken             string
	Claims                map[string]any
	UsersFile             string'''
assert old_config in s, 'Config struct not found'
s = s.replace(old_config, new_config, 1)

# In runOnce, pass Claims to client.Run
old_client_call = '''if err := client.Run(ctx, client.Config{
			Transport:        cfg.Transport,
			Carrier:          cfg.Auth,
			RoomURL:          roomURL,
			ChannelID:        cfg.ChannelID,
			KeyHex:           cfg.KeyHex,
			LocalAddr:        fmt.Sprintf("%s:%d", cfg.SOCKSHost, cfg.SOCKSPort),
			DNSServer:        cfg.DNSServer,
			SOCKSUser:        cfg.SOCKSUser,
			SOCKSPass:        cfg.SOCKSPass,
			TransportOptions: opts,
			Engine:           cfg.Engine,
			URL:              cfg.URL,
			Token:            cfg.Token,
			AuthToken:        cfg.AuthToken,
			Liveness:         liveness,
			Traffic:          traffic,
		}); err != nil {'''
new_client_call = '''if err := client.Run(ctx, client.Config{
			Transport:        cfg.Transport,
			Carrier:          cfg.Auth,
			RoomURL:          roomURL,
			ChannelID:        cfg.ChannelID,
			KeyHex:           cfg.KeyHex,
			LocalAddr:        fmt.Sprintf("%s:%d", cfg.SOCKSHost, cfg.SOCKSPort),
			DNSServer:        cfg.DNSServer,
			SOCKSUser:        cfg.SOCKSUser,
			SOCKSPass:        cfg.SOCKSPass,
			TransportOptions: opts,
			Engine:           cfg.Engine,
			URL:              cfg.URL,
			Token:            cfg.Token,
			AuthToken:        cfg.AuthToken,
			Liveness:         liveness,
			Traffic:          traffic,
			Claims:           cfg.Claims,
		}); err != nil {'''
assert old_client_call in s, 'client.Run call not found'
s = s.replace(old_client_call, new_client_call, 1)

# In runOnce, pass UsersFile to server.Run
old_server_call = '''if err := server.Run(ctx, server.Config{
			Transport:        cfg.Transport,
			Carrier:          cfg.Auth,
			RoomURL:          roomURL,
			ChannelID:        cfg.ChannelID,
			KeyHex:           cfg.KeyHex,
			DNSServer:        cfg.DNSServer,
			SOCKSProxyAddr:   cfg.SOCKSProxyAddr,
			SOCKSProxyPort:   cfg.SOCKSProxyPort,
			SOCKSProxyUser:   cfg.SOCKSProxyUser,
			SOCKSProxyPass:   cfg.SOCKSProxyPass,
			TransportOptions: opts,
			Engine:           cfg.Engine,
			URL:              cfg.URL,
			Token:            cfg.Token,
			AuthToken:        cfg.AuthToken,
			Liveness:         liveness,
			Traffic:          traffic,'''
new_server_call = '''if err := server.Run(ctx, server.Config{
			Transport:        cfg.Transport,
			Carrier:          cfg.Auth,
			RoomURL:          roomURL,
			ChannelID:        cfg.ChannelID,
			KeyHex:           cfg.KeyHex,
			DNSServer:        cfg.DNSServer,
			SOCKSProxyAddr:   cfg.SOCKSProxyAddr,
			SOCKSProxyPort:   cfg.SOCKSProxyPort,
			SOCKSProxyUser:   cfg.SOCKSProxyUser,
			SOCKSProxyPass:   cfg.SOCKSProxyPass,
			TransportOptions: opts,
			Engine:           cfg.Engine,
			URL:              cfg.URL,
			Token:            cfg.Token,
			AuthToken:        cfg.AuthToken,
			Liveness:         liveness,
			Traffic:          traffic,
			UsersFile:        cfg.UsersFile,'''
assert old_server_call in s, 'server.Run call not found'
s = s.replace(old_server_call, new_server_call, 1)

with open(session_path, 'w') as f:
    f.write(s)
print('session.go: OK')

# ============================================================
# 2. config.go — add claims and auth.users_file to YAML schema + Apply
# ============================================================
config_path = os.path.join(ROOT, 'internal/config/config.go')
with open(config_path) as f:
    c = f.read()

# Add Claims to File struct
old_file = '''// File is the on-disk YAML schema.
type File struct {
	Mode      string    `yaml:"mode"`
	Auth      Auth      `yaml:"auth"`
	Room      Room      `yaml:"room"`
	Crypto    Crypto    `yaml:"crypto"`
	Net       Net       `yaml:"net"`
	SOCKS     SOCKS     `yaml:"socks"`
	Engine    Engine    `yaml:"engine"`
	Video     Video     `yaml:"video"`
	VP8       VP8       `yaml:"vp8"`
	SEI       SEI       `yaml:"sei"`
	Liveness  Liveness  `yaml:"liveness"`
	Lifecycle Lifecycle `yaml:"lifecycle"`
	Traffic   Traffic   `yaml:"traffic"`
	Gen       Gen       `yaml:"gen"`
	Profiles  []Profile `yaml:"profiles"`
	Failover  Failover  `yaml:"failover"`
	Data      string    `yaml:"data"`
	Debug     bool      `yaml:"debug"`
}'''
new_file = '''// File is the on-disk YAML schema.
type File struct {
	Mode      string            `yaml:"mode"`
	Auth      Auth              `yaml:"auth"`
	Room      Room              `yaml:"room"`
	Crypto    Crypto            `yaml:"crypto"`
	Net       Net               `yaml:"net"`
	SOCKS     SOCKS             `yaml:"socks"`
	Engine    Engine            `yaml:"engine"`
	Video     Video             `yaml:"video"`
	VP8       VP8               `yaml:"vp8"`
	SEI       SEI               `yaml:"sei"`
	Liveness  Liveness          `yaml:"liveness"`
	Lifecycle Lifecycle         `yaml:"lifecycle"`
	Traffic   Traffic           `yaml:"traffic"`
	Gen       Gen               `yaml:"gen"`
	Profiles  []Profile         `yaml:"profiles"`
	Failover  Failover          `yaml:"failover"`
	Claims    map[string]any    `yaml:"claims"`
	Data      string            `yaml:"data"`
	Debug     bool              `yaml:"debug"`
}'''
assert old_file in c, 'File struct not found'
c = c.replace(old_file, new_file, 1)

# Add UsersFile to Auth struct
old_auth = '''// Auth selects the auth provider.
type Auth struct {
	Provider string `yaml:"provider"` // telemost, wbstream, none
	Token    string `yaml:"token"`    // optional pre-issued account token (wbstream)
}'''
new_auth = '''// Auth selects the auth provider.
type Auth struct {
	Provider  string `yaml:"provider"`   // telemost, wbstream, none
	Token     string `yaml:"token"`      // optional pre-issued account token (wbstream)
	UsersFile string `yaml:"users_file"` // path to JSON with user->pass map (server-side auth)
}'''
assert old_auth in c, 'Auth struct not found'
c = c.replace(old_auth, new_auth, 1)

# Add Apply mapping for Claims and UsersFile
old_apply = '''\tdst.Amount = pickInt(dst.Amount, f.Gen.Amount)
\treturn dst
}'''
new_apply = '''\tdst.Amount = pickInt(dst.Amount, f.Gen.Amount)
\tdst.Claims = pickStringMap(dst.Claims, f.Claims)
\tdst.UsersFile = pickString(dst.UsersFile, f.Auth.UsersFile)
\treturn dst
}'''
assert old_apply in c, 'Apply function end not found'
c = c.replace(old_apply, new_apply, 1)

# Add pickStringMap helper function after pickInt
old_pickint = '''func pickInt(cli, yamlVal int) int {
	if cli != 0 {
		return cli
	}
	return yamlVal
}'''
new_pickint = '''func pickInt(cli, yamlVal int) int {
	if cli != 0 {
		return cli
	}
	return yamlVal
}

func pickStringMap(cli, yamlVal map[string]any) map[string]any {
	if len(cli) > 0 {
		return cli
	}
	return yamlVal
}'''
assert old_pickint in c, 'pickInt function not found'
c = c.replace(old_pickint, new_pickint, 1)

# Add Profile Apply mapping
old_profile_apply = '''\tdst.Amount = overlayInt(dst.Amount, p.Gen.Amount)
	return dst
}'''
new_profile_apply = '''\tdst.Amount = overlayInt(dst.Amount, p.Gen.Amount)
\treturn dst
}

// OverlayStringMap merges profile claims on top of base claims.
func overlayStringMap(base, profile map[string]any) map[string]any {
\tif len(profile) == 0 {
\t\treturn base
\t}
\treturn profile
}'''
# Actually this is not critical for profiles but let me be safe
# Let me just check what comes after the ApplyProfile return
assert old_profile_apply in c, 'ApplyProfile function end not found'

with open(config_path, 'w') as f:
    f.write(c)
print('config.go: OK')

# ============================================================
# 3. server.go — add UsersFile field + create AuthHook that reads users.json
# ============================================================
server_path = os.path.join(ROOT, 'internal/server/server.go')
with open(server_path) as f:
    sv = f.read()

# Add UsersFile and imports
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
	AuthHook handshake.AuthFunc'''
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
assert old_server_config in sv, 'Server Config struct not found'
sv = sv.replace(old_server_config, new_server_config, 1)

# Add UsersFile handling in Run function, after "hook := cfg.AuthHook"
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

# Add the createFileAuthHook function and imports right before setupCipher
# First add the needed imports
old_imports = '''import (
\t"context"
\t"encoding/json"
\t"errors"
\t"fmt"
\t"io"
\t"net"
\t"sort"
\t"strconv"
\t"strings"
\t"sync"
\t"time"

\t"github.com/google/uuid"
\t"github.com/openlibrecommunity/olcrtc/internal/control"
\t"github.com/openlibrecommunity/olcrtc/internal/crypto"
\t"github.com/openlibrecommunity/olcrtc/internal/framing"
\t"github.com/openlibrecommunity/olcrtc/internal/handshake"
\t"github.com/openlibrecommunity/olcrtc/internal/logger"
\t"github.com/openlibrecommunity/olcrtc/internal/muxconn"
\t"github.com/openlibrecommunity/olcrtc/internal/names"
\t"github.com/openlibrecommunity/olcrtc/internal/runtime"
\t"github.com/openlibrecommunity/olcrtc/internal/transport"
\t"github.com/xtaci/smux"
)'''
new_imports = '''import (
\t"context"
\t"encoding/json"
\t"errors"
\t"fmt"
\t"io"
\t"net"
\t"os"
\t"sort"
\t"strconv"
\t"strings"
\t"sync"
\t"time"

\t"github.com/google/uuid"
\t"github.com/openlibrecommunity/olcrtc/internal/control"
\t"github.com/openlibrecommunity/olcrtc/internal/crypto"
\t"github.com/openlibrecommunity/olcrtc/internal/framing"
\t"github.com/openlibrecommunity/olcrtc/internal/handshake"
\t"github.com/openlibrecommunity/olcrtc/internal/logger"
\t"github.com/openlibrecommunity/olcrtc/internal/muxconn"
\t"github.com/openlibrecommunity/olcrtc/internal/names"
\t"github.com/openlibrecommunity/olcrtc/internal/runtime"
\t"github.com/openlibrecommunity/olcrtc/internal/transport"
\t"github.com/xtaci/smux"
)'''
assert old_imports in sv, 'imports not found'
sv = sv.replace(old_imports, new_imports, 1)

# Add the createFileAuthHook function before setupCipher
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

print('\n=== All patches applied successfully ===')
