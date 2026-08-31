import json

with open('/opt/vk-session/state.json') as f:
    state = json.load(f)

# Remove origins (not needed, causes errors)
state['origins'] = []

with open('/opt/vk-session/state.json', 'w') as f:
    json.dump(state, f)

print(f"Fixed: {len(state.get('cookies', []))} cookies, origins cleared")
