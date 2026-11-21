import csv
import os
import statistics
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

RAIZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RESULTADOS = os.path.join(RAIZ, "results")
GRAFICOS = os.path.join(RAIZ, "plots")

SERIES = [
    ("tt4", "sin_indice", "Sin indice", "#eda100", "s"),
    ("tt4", "btree", "B-tree", "#2a78d6", "o"),
    ("tt4", "ttree", "T-Tree (TT_MAX_KEYS=4)", "#eb6834", "^"),
    ("tt500", "ttree", "T-Tree (TT_MAX_KEYS=500)", "#1baf7a", "D"),
]
WORKLOADS = {"w1": "W1 busquedas exitosas", "w2": "W2 busquedas fallidas",
             "w4": "W4 busquedas por rango", "w3": "W3 inserciones (+10 %)"}
DATASETS = {"d1": "D1 secuencial", "d2": "D2 aleatorio", "d3": "D3 aleatorio + consultas Zipf",
            "d4": "D4 VARCHAR aleatorio", "d5": "D5 VARCHAR con prefijos"}
TEXTO = "#0b0b0b"
TEXTO2 = "#52514e"
GRILLA = "#e4e3df"


def leer():
    filas = []
    for cfg in sorted(os.listdir(RESULTADOS)):
        ruta = os.path.join(RESULTADOS, cfg, "resultados.csv")
        if os.path.isfile(ruta):
            with open(ruta) as f:
                filas.extend(csv.DictReader(f))
    return filas


def num(v):
    return float(v) if v not in ("", None) else None


def resumir(filas):
    grupos = defaultdict(list)
    for r in filas:
        clave = (r["config"], r["dataset"], int(r["n"]), r["metodo"], r["medida"])
        ms, ops, by = num(r["ms"]), num(r["operaciones"]), num(r["bytes"])
        if r["medida"] in WORKLOADS:
            valor = ms * 1000.0 / ops
        elif r["medida"] == "construccion":
            valor = ms
        elif by is not None:
            valor = by
        else:
            continue
        grupos[clave].append(valor)
    resumen = {}
    for clave, vals in grupos.items():
        media = statistics.mean(vals)
        resumen[clave] = {
            "reps": len(vals), "mediana": statistics.median(vals), "media": media,
            "min": min(vals), "max": max(vals),
            "cv": (statistics.stdev(vals) / media * 100) if len(vals) > 1 and media else 0.0,
        }
    return resumen


def consistencia(filas):
    vistos = defaultdict(set)
    for r in filas:
        if r["medida"] in ("w1", "w2", "w4"):
            vistos[(r["dataset"], r["n"], r["medida"])].add((r["filas"], r["control"]))
    return {k: len(v) == 1 for k, v in vistos.items()}


def unidad(medida):
    if medida in WORKLOADS:
        return "us/op"
    if medida == "construccion":
        return "ms"
    return "bytes"


def escribir_resumen(resumen, ok):
    with open(os.path.join(RESULTADOS, "resumen.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["config", "dataset", "n", "metodo", "medida", "unidad", "reps", "mediana", "media", "min", "max", "cv_pct"])
        for k in sorted(resumen):
            s = resumen[k]
            w.writerow([*k, unidad(k[4]), s["reps"], f"{s['mediana']:.3f}", f"{s['media']:.3f}",
                        f"{s['min']:.3f}", f"{s['max']:.3f}", f"{s['cv']:.2f}"])

    lineas = ["# Resumen del benchmark (semana 6)", "",
              "Valores: mediana de las repeticiones (entre parentesis, coeficiente de variacion %).",
              "Busquedas e inserciones en microsegundos por operacion; construccion en ms; tamano en MB.", ""]
    cfgs = sorted({k[0] for k in resumen})
    for ds in [d for d in DATASETS if any(k[1] == d for k in resumen)]:
        lineas += [f"## {DATASETS[ds]}", ""]
        cols = [(c, m) for c in cfgs for m in ("sin_indice", "btree", "ttree")
                if any(k[0] == c and k[1] == ds and k[3] == m for k in resumen)]
        lineas.append("| medida | n | " + " | ".join(f"{m} ({c})" for c, m in cols) + " |")
        lineas.append("|---|---|" + "---|" * len(cols))
        for medida in ("construccion", "w1", "w2", "w4", "w3", "tamano_inicial", "tamano_final"):
            for n in sorted({k[2] for k in resumen if k[1] == ds}):
                celdas = []
                for c, m in cols:
                    s = resumen.get((c, ds, n, m, medida))
                    if s is None:
                        celdas.append("-")
                    elif medida.startswith("tamano"):
                        celdas.append(f"{s['mediana'] / 2**20:.1f}")
                    else:
                        celdas.append(f"{s['mediana']:.2f} ({s['cv']:.1f})")
                if any(x != "-" for x in celdas):
                    lineas.append(f"| {medida} | {n} | " + " | ".join(celdas) + " |")
        lineas.append("")
    malos = [k for k, v in ok.items() if not v]
    lineas += ["## Consistencia de resultados", "",
               f"Combinaciones (dataset, n, workload) verificadas: {len(ok)}; con diferencias entre metodos o repeticiones: {len(malos)}.",
               ""]
    lineas += [f"- diferencia en {k}" for k in malos]
    with open(os.path.join(RESULTADOS, "resumen.md"), "w") as f:
        f.write("\n".join(lineas) + "\n")
    return malos


def estilo(ax, titulo, ylabel):
    ax.set_title(titulo, fontsize=10, color=TEXTO, loc="left")
    ax.set_ylabel(ylabel, fontsize=9, color=TEXTO2)
    ax.set_xlabel("filas en la tabla", fontsize=9, color=TEXTO2)
    ax.grid(True, which="major", color=GRILLA, linewidth=0.6)
    for lado in ("top", "right"):
        ax.spines[lado].set_visible(False)
    for lado in ("left", "bottom"):
        ax.spines[lado].set_color(TEXTO2)
    ax.tick_params(colors=TEXTO2, labelsize=8)


def linea(ax, resumen, ds, medida, escala=1.0):
    dibujado = False
    for cfg, metodo, nombre, color, marca in SERIES:
        pts = sorted((k[2], s) for k, s in resumen.items()
                     if k[0] == cfg and k[1] == ds and k[3] == metodo and k[4] == medida)
        if not pts:
            continue
        xs = [p[0] for p in pts]
        ys = [p[1]["mediana"] * escala for p in pts]
        lo = [(p[1]["mediana"] - p[1]["min"]) * escala for p in pts]
        hi = [(p[1]["max"] - p[1]["mediana"]) * escala for p in pts]
        ax.errorbar(xs, ys, yerr=[lo, hi], label=nombre, color=color, marker=marca, markersize=6,
                    linewidth=2, capsize=3, markeredgecolor="white", markeredgewidth=1)
        dibujado = True
    ax.set_xticks([100_000, 500_000, 1_000_000], ["100k", "500k", "1M"])
    return dibujado


def graficar(resumen):
    os.makedirs(GRAFICOS, exist_ok=True)
    datasets = [d for d in DATASETS if any(k[1] == d for k in resumen)]
    for ds in datasets:
        fig, axes = plt.subplots(1, 4, figsize=(17, 4.2))
        hubo = False
        for ax, medida in zip(axes, ("w1", "w2", "w4", "w3")):
            hubo |= linea(ax, resumen, ds, medida)
            ax.set_yscale("log")
            estilo(ax, WORKLOADS[medida], "microsegundos por operacion (log)")
        if not hubo:
            plt.close(fig)
            continue
        h, l = axes[0].get_legend_handles_labels()
        fig.legend(h, l, loc="upper center", ncol=len(l), frameon=False, fontsize=9)
        fig.suptitle(f"{DATASETS[ds]}: mediana de 5 repeticiones, barras = min-max", y=0.02, fontsize=9, color=TEXTO2)
        fig.tight_layout(rect=(0, 0.07, 1, 0.9))
        fig.savefig(os.path.join(GRAFICOS, f"operaciones_{ds}.png"), dpi=130, bbox_inches="tight", pad_inches=0.15)
        plt.close(fig)

    for medida, titulo, ylabel, escala, nombre in (
            ("construccion", "Tiempo de construccion del indice", "milisegundos (log)", 1.0, "construccion.png"),
            ("tamano_inicial", "Tamano del indice tras la construccion", "MB (log)", 1 / 2**20, "tamano_indice.png"),
            ("tamano_final", "Tamano del indice tras W3 (+10 % filas)", "MB (log)", 1 / 2**20, "tamano_indice_final.png")):
        fig, axes = plt.subplots(1, len(datasets), figsize=(4.4 * len(datasets), 4.2), squeeze=False)
        for ax, ds in zip(axes[0], datasets):
            linea(ax, resumen, ds, medida, escala)
            ax.set_yscale("log")
            estilo(ax, DATASETS[ds], ylabel)
        h, l = [], []
        for ax in axes[0]:
            for hh, ll in zip(*ax.get_legend_handles_labels()):
                if ll not in l:
                    h.append(hh)
                    l.append(ll)
        fig.legend(h, l, loc="upper center", ncol=len(l), frameon=False, fontsize=9)
        fig.suptitle(f"{titulo}: mediana de 5 repeticiones", y=0.02, fontsize=9, color=TEXTO2)
        fig.tight_layout(rect=(0, 0.07, 1, 0.9))
        fig.savefig(os.path.join(GRAFICOS, nombre), dpi=130, bbox_inches="tight", pad_inches=0.15)
        plt.close(fig)


def main():
    filas = leer()
    resumen = resumir(filas)
    ok = consistencia(filas)
    malos = escribir_resumen(resumen, ok)
    graficar(resumen)
    print(f"filas leidas={len(filas)} grupos={len(resumen)} consistencia: {len(ok) - len(malos)}/{len(ok)} sin diferencias")


if __name__ == "__main__":
    main()
