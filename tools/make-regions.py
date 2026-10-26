"""Lager Sources/Fotoalbum/Resources/usa-regions.json fra Natural Earth (allemannseie).

Kilde: ne_10m_geography_regions_polys.geojson, Natural Earth v5.1.2
(https://github.com/nvkelso/natural-earth-vector). Beholder geografiske regioner som berører
fastlands-USA (fjellkjeder, ørkener, sletter, platåer, daler …), med engelsk navn, type og
«scalerank» (høyere = mindre og mer presis region), og forenkler omrisset.

    python3 tools/make-regions.py <regions.geojson> <ut.json>
"""
import json, sys

SKIP = {"Continent", "Tundra", "Island group", "Island"}

def simplify(points, tol):
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0][:2], points[-1][:2]
    dx, dy = x2 - x1, y2 - y1
    norm = (dx * dx + dy * dy) ** 0.5 or 1e-12
    best, index = 0, 0
    for i in range(1, len(points) - 1):
        x, y = points[i][:2]
        d = abs(dy * x - dx * y + x2 * y1 - y2 * x1) / norm
        if d > best:
            best, index = d, i
    if best <= tol:
        return [points[0], points[-1]]
    return simplify(points[: index + 1], tol)[:-1] + simplify(points[index:], tol)

def bbox(rings):
    xs = [p[0] for r in rings for p in r]; ys = [p[1] for r in rings for p in r]
    return min(xs), min(ys), max(xs), max(ys)

source, target = sys.argv[1], sys.argv[2]
data = json.load(open(source))
regions = []
for f in data["features"]:
    p = f["properties"]
    if p["FEATURECLA"] in SKIP:
        continue
    g = f["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    rings = []
    for poly in polys:
        outer = poly[0]
        half = len(outer) // 2
        ring = simplify(outer[: half + 1], 0.02)[:-1] + simplify(outer[half:], 0.02)
        if len(ring) >= 4:
            rings.append([[round(x, 3), round(y, 3)] for x, y in (pt[:2] for pt in ring)])
    if not rings:
        continue
    x0, y0, x1, y1 = bbox(rings)
    if x1 < -125 or x0 > -66 or y1 < 24 or y0 > 50:
        continue
    regions.append({"name": p["NAME_EN"] or p["NAME"], "kind": p["FEATURECLA"], "rank": p["SCALERANK"], "rings": rings})
regions.sort(key=lambda r: (-r["rank"], r["name"]))
json.dump(regions, open(target, "w"), separators=(",", ":"))
print(len(regions), "regioner,", sum(len(r) for x in regions for r in x["rings"]), "punkter")
