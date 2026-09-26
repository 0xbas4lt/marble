#!/usr/bin/python3

results = []
with open("test.txt", "r") as file:
    for line in file:
        clean_line = line.strip()
        if not clean_line:
            continue
        parts = clean_line.split(None, 2)
        results.append(tuple(parts))

for (a, b, c) in results:
    if a == 'RESERVED':
        continue
    print(f'    /// {c}')
    print(f'    {a.lower()} = {b},')
