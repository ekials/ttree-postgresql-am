import argparse
import bisect
import hashlib
import itertools
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "generators"))
import generar_datos as gd

SEMILLA_WORKLOADS = 777
N_EXITOSAS = 10_000
N_FALLIDAS = 10_000
N_RANGOS = 1_000
FRACCION_INSERCIONES = 0.10
RANGO_FILAS = (10, 1_000)
ZIPF_S = 1.1
ORIGEN = {"d1": "d1", "d2": "d2", "d3": "d2", "d4": "d4", "d5": "d5"}


def leer(ruta):
    with open(ruta) as f:
        filas = [linea.rstrip("\n").split(",", 1) for linea in f]
    return [c for _, c in filas]


def convertir(ds, claves):
    return [int(c) for c in claves] if ORIGEN[ds] in ("d1", "d2") else claves


class Zipf:
    def __init__(self, n, s, rng):
        acumulado = list(itertools.accumulate(1.0 / (r ** s) for r in range(1, n + 1)))
        self.total = acumulado[-1]
        self.acumulado = acumulado
        self.rng = rng

    def rango(self):
        return bisect.bisect_left(self.acumulado, self.rng.random() * self.total)


def ausentes(ds, n, claves, rng, cantidad):
    presentes = set(claves)
    if ds == "d1":
        candidatos = []
        while len(candidatos) < cantidad:
            c = rng.choice((rng.randint(-n, 0), rng.randint(2 * n + 1, 3 * n)))
            candidatos.append(c)
        return candidatos
    if ORIGEN[ds] == "d2":
        fabrica = lambda r: r.randint(*gd.DOMINIO_INT)
    elif ds == "d4":
        fabrica = gd.cadena_aleatoria
    else:
        fabrica = gd.cadena_con_prefijo
    return gd.claves_unicas(rng, cantidad, fabrica, excluir=presentes)


def nuevas(ds, n, claves, rng, cantidad):
    if ds == "d1":
        return list(range(n + 1, n + cantidad + 1))
    presentes = set(claves)
    if ORIGEN[ds] == "d2":
        fabrica = lambda r: r.randint(*gd.DOMINIO_INT)
    elif ds == "d4":
        fabrica = gd.cadena_aleatoria
    else:
        fabrica = gd.cadena_con_prefijo
    return gd.claves_unicas(rng, cantidad, fabrica, excluir=presentes)


def generar(ds, n, claves):
    rng = random.Random(SEMILLA_WORKLOADS * 1_000_003 + int(ds[1:]) * 10_000_000 + n)
    ordenadas = sorted(claves)
    if ds == "d3":
        zipf = Zipf(n, ZIPF_S, rng)
        permutacion = list(range(n))
        rng.shuffle(permutacion)
        elegir = lambda: permutacion[zipf.rango()]
    else:
        elegir = lambda: rng.randrange(n)

    w1 = [(ordenadas[elegir()], "") for _ in range(N_EXITOSAS)]

    pool = ausentes(ds, n, claves, rng, N_FALLIDAS if ds != "d3" else n // 10)
    if ds == "d3":
        zf = Zipf(len(pool), ZIPF_S, rng)
        w2 = [(pool[zf.rango()], "") for _ in range(N_FALLIDAS)]
    else:
        w2 = [(c, "") for c in pool]

    w3 = [(c, "") for c in nuevas(ds, n, claves, rng, int(n * FRACCION_INSERCIONES))]

    w4 = []
    for _ in range(N_RANGOS):
        filas = rng.randint(*RANGO_FILAS)
        i = min(elegir(), n - filas)
        w4.append((ordenadas[i], ordenadas[i + filas - 1]))
    return {"w1": w1, "w2": w2, "w3": w3, "w4": w4}


def escribir(ruta, ops):
    h = hashlib.sha256()
    with open(ruta, "w", newline="") as f:
        for i, (a, b) in enumerate(ops, start=1):
            linea = f"{i},{a},{b}\n"
            f.write(linea)
            h.update(linea.encode())
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description="Genera los workloads W1-W4 para cada dataset y tamano.")
    p.add_argument("--datos", default="/benchdata")
    p.add_argument("--datasets", nargs="+", default=["d1", "d2", "d3", "d4", "d5"])
    p.add_argument("--tamanos", nargs="+", type=int, default=[100_000, 500_000, 1_000_000])
    args = p.parse_args()

    manifiesto = []
    for ds in args.datasets:
        for n in args.tamanos:
            claves = convertir(ds, leer(os.path.join(args.datos, f"{ORIGEN[ds]}_{n}.csv")))
            for w, ops in generar(ds, n, claves).items():
                nombre = f"{ds}_{n}_{w}.csv"
                digest = escribir(os.path.join(args.datos, nombre), ops)
                manifiesto.append(f"{digest}  {nombre}")
                print(f"{nombre}: {len(ops)} operaciones sha256={digest[:16]}")
    with open(os.path.join(args.datos, "manifiesto_workloads.txt"), "w") as f:
        f.write("\n".join(manifiesto) + "\n")


if __name__ == "__main__":
    main()
