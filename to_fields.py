#!/usr/bin/python3

results = []
with open("test.txt", "r") as file:
    for line in file:
        clean_line = line.strip()
        if not clean_line:
            continue
        parts = clean_line.split(None, 3)
        if len(parts) == 3:
            parts.append('unspecified')
        results.append(tuple(parts))

for (a, b, c, d) in results:
    if a == 'RESERVED':
        continue
    # name = "".join(part.capitalize() for part in a.split("_"))
    name = a.lower()
    print(f'    /// field: {c:<9}    ; Calculation: {d}')
    print(f'    {name} = {b},')
