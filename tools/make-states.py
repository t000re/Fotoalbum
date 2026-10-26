"""Lager Sources/Fotoalbum/Resources/usa-states.json fra Natural Earth (allemannseie).

Kilde: ne_50m_admin_1_states_provinces.geojson, Natural Earth v5.1.2
(https://github.com/nvkelso/natural-earth-vector). Beholder bare USA-statene, navn og
forkortelse, og forenkler omrisset (Douglas–Peucker) så fila blir liten.

    python3 tools/make-states.py <states.geojson> <ut.json>
"""
import json, sys

def simplify(points, tol):
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = (dx * dx + dy * dy) ** 0.5 or 1e-12
    best, index = 0, 0
    for i in range(1, len(points) - 1):
        x, y = points[i]
        d = abs(dy * x - dx * y + x2 * y1 - y2 * x1) / norm
        if d > best:
            best, index = d, i
    if best <= tol:
        return [points[0], points[-1]]
    return simplify(points[: index + 1], tol)[:-1] + simplify(points[index:], tol)

source, target = sys.argv[1], sys.argv[2]
data = json.load(open(source))
states = []
for f in data["features"]:
    p = f["properties"]
    if p.get("adm0_a3") != "USA":
        continue
    g = f["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    rings = []
    for poly in polys:
        # Bare ytterkanten. Ringen er lukket (første = siste punkt), så den deles i to halvdeler
        # før forenkling. Toleranse ca. 3 km.
        outer = poly[0]
        half = len(outer) // 2
        ring = simplify(outer[: half + 1], 0.03)[:-1] + simplify(outer[half:], 0.03)
        if len(ring) >= 4:
            rings.append([[round(x, 3), round(y, 3)] for x, y in ring])
    states.append({"name": p["name"], "code": p.get("postal", ""), "rings": rings})
states.sort(key=lambda s: s["name"])
json.dump(states, open(target, "w"), separators=(",", ":"))
print(len(states), "stater,", sum(len(r) for s in states for r in s["rings"]), "punkter")
