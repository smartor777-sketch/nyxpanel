#!/usr/bin/env python3
"""Add traffic protocols note above charts in self.html and self_admin.html on dev."""

NOTE_HTML_USER = '''    <p style="font-size:0.78rem;color:var(--muted);margin-bottom:0.8rem" data-i18n="trafficNote">Считается трафик: VLESS (XHTTP+REALITY), Hysteria 2, AmneziaWG.</p>'''

NOTE_HTML_ADMIN = '''    <p style="font-size:0.78rem;color:var(--muted);margin-bottom:0.8rem" data-i18n="trafficNote">Считается трафик: VLESS (XHTTP+REALITY), Hysteria 2, AmneziaWG.</p>'''

I18N_RU = "Считается трафик: VLESS (XHTTP+REALITY), Hysteria 2, AmneziaWG."
I18N_EN = "Traffic is tracked for: VLESS (XHTTP+REALITY), Hysteria 2, AmneziaWG."

# --- self.html ---
path = '/opt/proxy-panel/templates/self.html'
with open(path, 'r', encoding='utf-8') as f:
    c = f.read()

# Add i18n keys if not present
if 'trafficNote' not in c:
    c = c.replace(
        "traffic: 'Трафик'",
        f"traffic: 'Трафик', trafficNote: '{I18N_RU}'"
    )
    c = c.replace(
        "traffic: 'Traffic'",
        f"traffic: 'Traffic', trafficNote: '{I18N_EN}'"
    )

# Add note after <h2> in traffic card
old = '    <h2 data-i18n="traffic">Traffic</h2>\n    <div class="toolbar">'
new = '    <h2 data-i18n="traffic">Traffic</h2>\n    ' + NOTE_HTML_USER + '\n    <div class="toolbar">'
if old in c and 'trafficNote' not in c.split('trafficChart')[0].split('traffic</h2>')[-1]:
    c = c.replace(old, new)

with open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print(f'Updated {path}')

# --- self_admin.html ---
path2 = '/opt/proxy-panel/templates/self_admin.html'
with open(path2, 'r', encoding='utf-8') as f:
    c2 = f.read()

# Add i18n keys
if 'trafficNote' not in c2:
    c2 = c2.replace(
        "traffic: 'Трафик'",
        f"traffic: 'Трафик', trafficNote: '{I18N_RU}'"
    )
    c2 = c2.replace(
        "traffic: 'Traffic'",
        f"traffic: 'Traffic', trafficNote: '{I18N_EN}'"
    )

# Add note after <h2> in traffic card
old2 = '    <h2 data-i18n="traffic">Traffic</h2>\n    <div style="display:flex'
new2 = '    <h2 data-i18n="traffic">Traffic</h2>\n    ' + NOTE_HTML_ADMIN + '\n    <div style="display:flex'
if old2 in c2:
    c2 = c2.replace(old2, new2)

with open(path2, 'w', encoding='utf-8') as f:
    f.write(c2)
print(f'Updated {path2}')
