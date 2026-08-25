import pathlib
p = pathlib.Path('/root/proxy_manager.sh')
t = p.read_text()
old = '^\s*(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1)'
new = '^\s*(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I5|ContentPaddingAddition|RekeyAfterTime)'
t = t.replace(old, new)
p.write_text(t)
print('proxy_manager.sh updated')
