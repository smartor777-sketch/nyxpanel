import pathlib

# Fix app.py version
p = pathlib.Path('/opt/proxy-panel/app.py')
t = p.read_text()
t = t.replace('PANEL_VERSION = "1.09"', 'PANEL_VERSION = "1.10"')
p.write_text(t)
print('app.py version updated')

# Fix manual.html - Android section
mh = pathlib.Path('/opt/proxy-panel/templates/manual.html')
t = mh.read_text()

# Replace old app-name and app-proto for AmneziaWG
old_android = '''      <div class="app-card">
        <div class="app-name">AmneziaWG</div>
        <div class="app-proto" data-i18n="appAwg">AmneziaWG (VPN)</div>
      </div>
    </div>

    <div class="note">
      <strong data-i18n="noteTitle">OlcboxME for olcRTC:</strong>'''

new_android = '''      <div class="app-card">
        <div class="app-name">Amnezia VPN</div>
        <div class="app-proto" data-i18n="appAwg">AmneziaWG (WireGuard)</div>
      </div>
    </div>

    <div class="note">
      <strong data-i18n="noteTitle">OlcboxME for olcRTC:</strong>'''

t = t.replace(old_android, new_android)

# Fix Windows section
old_windows = '''      <div class="app-card">
        <div class="app-name">AmneziaWG</div>
        <div class="app-proto" data-i18n="appAwg">AmneziaWG (VPN)</div>
      </div>
      <div class="app-card">
        <div class="app-name">NekoBox</div>'''

new_windows = '''      <div class="app-card">
        <div class="app-name">Amnezia VPN</div>
        <div class="app-proto" data-i18n="appAwg">AmneziaWG (WireGuard)</div>
      </div>
      <div class="app-card">
        <div class="app-name">NekoBox</div>'''

t = t.replace(old_windows, new_windows)

# Fix translation keys
t = t.replace("appAwg: 'AmneziaWG (VPN)',", "appAwg: 'AmneziaWG (WireGuard)',")

mh.write_text(t)
print('manual.html updated')
