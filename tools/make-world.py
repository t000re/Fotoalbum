"""Lager Resources/world-countries.json og Resources/world-regions.json fra Natural Earth (allemannseie).

Kilder: ne_10m_admin_0_countries.geojson og ne_10m_admin_1_states_provinces.geojson, Natural Earth
v5.1.2 (https://github.com/nvkelso/natural-earth-vector). Land: ISO-kode og navn. Regioner (stat, fylke,
provins …): ISO 3166-2-kode, navn, type og land. Omrisset forenkles (Douglas–Peucker) og lagres som
flate lister [lon, lat, lon, lat …] med tre desimaler, pluss avgrensningsboks for raskt oppslag.

    python3 tools/make-world.py <countries.geojson> <regions.geojson> <ut-mappe>
"""
import json, sys

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

def rings(geometry, tol):
    polys = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    out = []
    for poly in polys:
        outer = poly[0]
        half = len(outer) // 2
        ring = simplify(outer[: half + 1], tol)[:-1] + simplify(outer[half:], tol)
        if len(ring) >= 4:
            flat = []
            for x, y in (pt[:2] for pt in ring):
                flat += [round(x, 3), round(y, 3)]
            out.append(flat)
    return out

def bbox(rs):
    xs = [r[i] for r in rs for i in range(0, len(r), 2)]
    ys = [r[i] for r in rs for i in range(1, len(r), 2)]
    return [min(xs), min(ys), max(xs), max(ys)]

countries_src, regions_src, out = sys.argv[1], sys.argv[2], sys.argv[3]
countries = []
for f in json.load(open(countries_src))["features"]:
    p = f["properties"]
    code = p["ISO_A2_EH"] if p["ISO_A2_EH"] not in (None, "-99") else p["ADM0_A3"]
    rs = rings(f["geometry"], 0.02)
    if rs:
        countries.append({"code": code, "name": p["NAME_EN"] or p["NAME"], "box": bbox(rs), "rings": rs})
regions = []
for f in json.load(open(regions_src))["features"]:
    p = f["properties"]
    if not f["geometry"]:
        continue
    rs = rings(f["geometry"], 0.02)
    if rs:
        regions.append({"code": p["iso_3166_2"] or p["adm1_code"], "name": p["name"] or p["name_en"],
                        "kind": p["type_en"] or "", "country": p["iso_a2"], "box": bbox(rs), "rings": rs})
json.dump(countries, open(out + "/world-countries.json", "w"), separators=(",", ":"))
json.dump(regions, open(out + "/world-regions.json", "w"), separators=(",", ":"))
print(len(countries), "land,", len(regions), "regioner")
