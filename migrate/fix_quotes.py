import pathlib
p = pathlib.Path('/opt/proxy-panel/app.py')
t = p.read_text()
t = t.replace('PANEL_VERSION = .1.10.', 'PANEL_VERSION = "1.10"')
p.write_text(t)
print('quotes fixed')
