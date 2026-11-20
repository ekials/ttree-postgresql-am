import argparse
import hashlib
import os
import random
import string

SEMILLA_BASE = 20260906
DOMINIO_INT = (1, 2_147_483_646)
ALFABETO = string.ascii_lowercase + string.digits
PREFIJOS = [
    "arequipa-cercado-", "arequipa-cayma-", "arequipa-yanahuara-", "arequipa-paucarpata-",
    "lima-miraflores-", "lima-san-isidro-", "lima-surco-", "cusco-wanchaq-",
    "cusco-santiago-", "puno-juliaca-",
]


def semilla(dataset, n):
    return SEMILLA_BASE + int(dataset[1:]) * 10_000_000 + n


def cadena_aleatoria(rng):
    return "".join(rng.choices(ALFABETO, k=rng.randint(8, 32)))


def cadena_con_prefijo(rng):
    return rng.choice(PREFIJOS) + "".join(rng.choices(ALFABETO, k=10))


def claves_unicas(rng, n, fabrica, excluir=()):
    vistas = set(excluir)
    salida = []
    while len(salida) < n:
        c = fabrica(rng)
        if c not in vistas:
            vistas.add(c)
            salida.append(c)
    return salida


def generar(dataset, n):
    rng = random.Random(semilla(dataset, n))
    if dataset == "d1":
        return list(range(1, n + 1))
    if dataset == "d2":
        return rng.sample(range(DOMINIO_INT[0], DOMINIO_INT[1] + 1), n)
    if dataset == "d4":
        return claves_unicas(rng, n, cadena_aleatoria)
    if dataset == "d5":
        return claves_unicas(rng, n, cadena_con_prefijo)
    raise ValueError(dataset)


def escribir(ruta, claves):
    h = hashlib.sha256()
    with open(ruta, "w", newline="") as f:
        for i, c in enumerate(claves, start=1):
            linea = f"{i},{c}\n"
            f.write(linea)
            h.update(linea.encode())
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description="Genera los datasets base D1, D2, D4 y D5 (D3 reutiliza D2).")
    p.add_argument("--salida", default="/benchdata")
    p.add_argument("--datasets", nargs="+", default=["d1", "d2", "d4", "d5"])
    p.add_argument("--tamanos", nargs="+", type=int, default=[100_000, 500_000, 1_000_000])
    args = p.parse_args()

    os.makedirs(args.salida, exist_ok=True)
    manifiesto = []
    for ds in args.datasets:
        for n in args.tamanos:
            ruta = os.path.join(args.salida, f"{ds}_{n}.csv")
            digest = escribir(ruta, generar(ds, n))
            manifiesto.append(f"{digest}  {ds}_{n}.csv")
            print(f"{ds} n={n} semilla={semilla(ds, n)} sha256={digest[:16]}")
    with open(os.path.join(args.salida, "manifiesto_datos.txt"), "w") as f:
        f.write("\n".join(manifiesto) + "\n")


if __name__ == "__main__":
    main()
