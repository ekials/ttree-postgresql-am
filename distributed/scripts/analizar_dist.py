import csv
import glob
import os
import re
import statistics
from collections import defaultdict
from datetime import datetime

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
GRAF = os.path.join(BASE, "graficos")
COLOR = {"rango": "#2a78d6", "hash": "#eb6834"}
ESTILO_IDX = {"btree": dict(hatch=None, alpha=1.0), "ttree": dict(hatch="//", alpha=0.75)}
TEXTO2 = "#52514e"
GRILLA = "#e4e3df"
MODOS = {"0": "uniforme", "1": "concentrado en A (Zipf)", "2": "concentrado en C (Zipf)"}
SCRIPTS = {"0": "lectura_cliente", "1": "lectura_rango", "2": "escritura"}


def pct(vals, p):
    vals = sorted(vals)
    if not vals:
        return float("nan")
    k = (len(vals) - 1) * p
    f = int(k)
    c = min(f + 1, len(vals) - 1)
    return vals[f] + (vals[c] - vals[f]) * (k - f)


def ejes(ax, titulo, xlabel):
    ax.set_title(titulo, fontsize=10, loc="left")
    ax.set_xlabel(xlabel, fontsize=9, color=TEXTO2)
    ax.grid(True, axis="x", color=GRILLA, linewidth=0.6)
    for lado in ("top", "right"):
        ax.spines[lado].set_visible(False)
    ax.tick_params(colors=TEXTO2, labelsize=8)


def consultas(lineas):
    ruta = os.path.join(BASE, "consultas.csv")
    if not os.path.isfile(ruta):
        return
    grupos = defaultdict(list)
    with open(ruta) as f:
        for r in csv.DictReader(f):
            grupos[(r["consulta"], r["estrategia"], r["indice"], r["latencia"])].append(
                (float(r["ms"]), int(r["filas"]), int(r["bytes_rx"]), int(r["bytes_tx"])))
    with open(os.path.join(BASE, "consultas_resumen.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["consulta", "estrategia", "indice", "latencia", "reps", "ms_mediana", "ms_p90", "ms_min", "ms_max",
                    "filas", "bytes_rx_mediana", "bytes_tx_mediana"])
        for k in sorted(grupos):
            v = grupos[k]
            ms = [x[0] for x in v]
            w.writerow([*k, len(v), f"{statistics.median(ms):.3f}", f"{pct(ms, 0.9):.3f}", f"{min(ms):.3f}",
                        f"{max(ms):.3f}", v[0][1], int(statistics.median([x[2] for x in v])),
                        int(statistics.median([x[3] for x in v]))])

    nombres = sorted({k[0] for k in grupos})
    lineas += ["## Latencia por consulta (mediana en ms, coordinador en el nodo A)", "",
               "| consulta | latencia de red | rango btree | rango ttree | hash btree | hash ttree | bytes recibidos por A (rango / hash, btree) |",
               "|---|---|---|---|---|---|---|"]
    for q in nombres:
        for lat in ("con", "sin"):
            celdas = []
            for e in ("rango", "hash"):
                for i in ("btree", "ttree"):
                    v = grupos.get((q, e, i, lat))
                    celdas.append(f"{statistics.median([x[0] for x in v]):.2f}" if v else "-")
            br = [grupos.get((q, e, "btree", lat)) for e in ("rango", "hash")]
            by = " / ".join(str(int(statistics.median([x[2] for x in v]))) if v else "-" for v in br)
            lineas.append(f"| {q} | {lat} | " + " | ".join(celdas) + f" | {by} |")
    lineas.append("")

    for lat in ("con", "sin"):
        fig, ax = plt.subplots(figsize=(10, 0.55 * len(nombres) + 1.5))
        alto = 0.2
        for j, (e, i) in enumerate([(e, i) for e in ("rango", "hash") for i in ("btree", "ttree")]):
            ys = [n + (j - 1.5) * alto for n in range(len(nombres))]
            xs = [statistics.median([x[0] for x in grupos[(q, e, i, lat)]]) if (q, e, i, lat) in grupos else 0 for q in nombres]
            ax.barh(ys, xs, height=alto, color=COLOR[e], edgecolor="white", linewidth=0.8,
                    label=f"{e} / {i}", **ESTILO_IDX[i])
        ax.set_yticks(range(len(nombres)), nombres, fontsize=8)
        ax.invert_yaxis()
        ax.set_xscale("log")
        ejes(ax, f"Latencia por consulta, {'con' if lat == 'con' else 'sin'} latencia de red simulada", "ms (mediana, escala log)")
        ax.legend(frameon=False, fontsize=8, ncol=4, loc="lower center", bbox_to_anchor=(0.5, 1.04))
        fig.tight_layout()
        fig.savefig(os.path.join(GRAF, f"consultas_{lat}_latencia.png"), dpi=130)
        plt.close(fig)


def pgbench(lineas):
    archivos = sorted(glob.glob(os.path.join(BASE, "pgbench", "*.txt")))
    if not archivos:
        return
    bytes_ = defaultdict(lambda: [0, 0])
    ruta_b = os.path.join(BASE, "pgbench_bytes.csv")
    if os.path.isfile(ruta_b):
        with open(ruta_b) as f:
            for r in csv.DictReader(f, delimiter=";"):
                k = (r["indice"], r["estrategia"], r["modo"])
                bytes_[k][0] += int(r["rx_bytes"])
                bytes_[k][1] += int(r["tx_bytes"])
    filas = []
    for ruta in archivos:
        tag = os.path.basename(ruta)[:-4]
        indice, estrategia, modo = re.match(r"(\w+?)_(rango|hash)_modo(\d)", tag).groups()
        texto = open(ruta).read()
        tps = re.search(r"tps = ([\d.]+)", texto)
        fallidas = re.search(r"number of failed transactions: (\d+)", texto)
        total = re.search(r"number of transactions actually processed: (\d+)", texto)
        lat = defaultdict(list)
        log = ruta[:-4] + ".log"
        if os.path.isfile(log):
            for linea in open(log):
                p = linea.split()
                if len(p) >= 4 and p[2].isdigit():
                    lat[p[3]].append(int(p[2]) / 1000.0)
        n = int(total.group(1)) if total else 0
        b = bytes_[(indice, estrategia, modo)]
        filas.append({
            "indice": indice, "estrategia": estrategia, "modo": modo,
            "tps": float(tps.group(1)) if tps else float("nan"),
            "transacciones": n, "fallidas": int(fallidas.group(1)) if fallidas else 0,
            **{f"{SCRIPTS[s]}_n": len(lat[s]) for s in SCRIPTS},
            **{f"{SCRIPTS[s]}_p50_ms": pct(lat[s], 0.5) for s in SCRIPTS},
            **{f"{SCRIPTS[s]}_p95_ms": pct(lat[s], 0.95) for s in SCRIPTS},
            "bytes_red_total": b[0] + b[1],
            "bytes_por_transaccion": (b[0] + b[1]) / n if n else float("nan"),
        })
    with open(os.path.join(BASE, "pgbench_resumen.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(filas[0]))
        w.writeheader()
        for r in filas:
            w.writerow({k: (f"{v:.3f}" if isinstance(v, float) else v) for k, v in r.items()})

    lineas += ["## Carga mixta 70 % lecturas / 30 % escrituras (pgbench, 4 clientes en A, 60 s)", "",
               "| índice | estrategia | acceso | tps | transacciones | fallidas | p50 cliente | p50 rango | p50 escritura | p95 rango | KB de red por transacción |",
               "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(filas, key=lambda r: (r["indice"], r["modo"], r["estrategia"])):
        lineas.append(f"| {r['indice']} | {r['estrategia']} | {MODOS[r['modo']]} | {r['tps']:.1f} | {r['transacciones']} | {r['fallidas']} | "
                      f"{r['lectura_cliente_p50_ms']:.1f} | {r['lectura_rango_p50_ms']:.1f} | {r['escritura_p50_ms']:.1f} | "
                      f"{r['lectura_rango_p95_ms']:.1f} | {r['bytes_por_transaccion'] / 1024:.1f} |")
    lineas.append("")
    for r in filas:
        tot = sum(r[f"{SCRIPTS[s]}_n"] for s in SCRIPTS)
        if tot:
            r["frac_escritura"] = r["escritura_n"] / tot
    fr = [r["frac_escritura"] for r in filas if "frac_escritura" in r]
    if fr:
        lineas += [f"Proporción real de escrituras en las corridas: entre {min(fr) * 100:.1f} % y {max(fr) * 100:.1f} % de las transacciones.", ""]

    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    for ax, ind in zip(axes, ("btree", "ttree")):
        ancho = 0.38
        for j, e in enumerate(("rango", "hash")):
            xs = [int(m) + (j - 0.5) * ancho for m in MODOS]
            ys = [next((r["tps"] for r in filas if r["indice"] == ind and r["estrategia"] == e and r["modo"] == m), 0) for m in MODOS]
            ax.bar(xs, ys, width=ancho, color=COLOR[e], edgecolor="white", label=e)
        ax.set_xticks(range(3), [MODOS[m] for m in MODOS], fontsize=8)
        ax.set_title(f"Transacciones por segundo, índice {ind}", fontsize=10, loc="left")
        ax.set_ylabel("tps", fontsize=9, color=TEXTO2)
        ax.grid(True, axis="y", color=GRILLA, linewidth=0.6)
        for lado in ("top", "right"):
            ax.spines[lado].set_visible(False)
        ax.legend(frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(GRAF, "pgbench_tps.png"), dpi=130)
    plt.close(fig)


def replicacion(lineas):
    ruta = os.path.join(BASE, "replicacion_lag.csv")
    if not os.path.isfile(ruta):
        return
    grupos = defaultdict(list)
    with open(ruta) as f:
        for r in csv.DictReader(f, delimiter=";"):
            if r["replay_lag_ms"]:
                grupos[(r["estrategia"], r["suscripcion"])].append(float(r["replay_lag_ms"]))
    if not grupos:
        return
    lineas += ["## Retraso de la replicación lógica durante la carga mixta (`pg_stat_replication.replay_lag`)", "",
               "| estrategia de la carga | suscripción | muestras | mediana ms | p95 ms | máximo ms |", "|---|---|---|---|---|---|"]
    for k in sorted(grupos):
        v = grupos[k]
        lineas.append(f"| {k[0]} | {k[1]} | {len(v)} | {statistics.median(v):.1f} | {pct(v, 0.95):.1f} | {max(v):.1f} |")
    lineas.append("")


def caida(lineas):
    eventos = defaultdict(list)
    ruta_e = os.path.join(BASE, "caida_eventos.csv")
    if os.path.isfile(ruta_e):
        with open(ruta_e) as f:
            for r in csv.DictReader(f, delimiter=";"):
                eventos[r["estrategia"]].append((datetime.fromisoformat(r["instante"]), r["evento"]))
    for ruta in sorted(glob.glob(os.path.join(BASE, "caida_sonda_*.csv"))):
        est = os.path.basename(ruta)[len("caida_sonda_"):-4]
        filas = list(csv.DictReader(open(ruta)))
        if not filas:
            continue
        t0 = datetime.fromisoformat(filas[0]["instante"])
        consultas_ = sorted({r["consulta"] for r in filas})
        fig, ax = plt.subplots(figsize=(11, 3.2))
        for y, q in enumerate(consultas_):
            ok = [(datetime.fromisoformat(r["instante"]) - t0).total_seconds() for r in filas if r["consulta"] == q and r["ok"] == "t"]
            er = [(datetime.fromisoformat(r["instante"]) - t0).total_seconds() for r in filas if r["consulta"] == q and r["ok"] != "t"]
            ax.scatter(ok, [y] * len(ok), s=10, marker="o", color="#1baf7a", label="correcta" if y == 0 else None)
            ax.scatter(er, [y] * len(er), s=18, marker="x", color="#e34948", label="error" if y == 0 else None)
        marcas_ev = [(t, ev) for t, ev in eventos.get(est, []) if "sonda" not in ev]
        for i, (t, ev) in enumerate(marcas_ev):
            x = (t - t0).total_seconds()
            ax.axvline(x, color=TEXTO2, linewidth=1, linestyle="--")
            ax.text(x + 0.5, len(consultas_) - 0.2 - 0.35 * (i % 2), ev.split(":")[0].split(" (")[0],
                    fontsize=7, color=TEXTO2)
        ax.set_yticks(range(len(consultas_)), consultas_, fontsize=8)
        ax.set_ylim(-0.6, len(consultas_) + 0.4)
        ejes(ax, f"Disponibilidad durante la caída del nodo C (estrategia {est})", "segundos desde el inicio")
        ax.legend(frameon=False, fontsize=8, loc="lower right")
        fig.tight_layout()
        fig.savefig(os.path.join(GRAF, f"caida_{est}.png"), dpi=130)
        plt.close(fig)

        lineas += [f"## Caída del nodo C, estrategia {est}", "",
                   "| consulta | fase | correctas | con error | ms mediana (correctas) |", "|---|---|---|---|---|"]
        marcas = [t for t, ev in eventos.get(est, []) if "sonda" not in ev]
        nombres_f = ["antes de la caída", "caído, sin conmutar", "conmutado a réplica", "tras el retorno"]
        for q in consultas_:
            for k in range(len(nombres_f)):
                ini = marcas[k - 1] if k > 0 and k - 1 < len(marcas) else None
                fin = marcas[k] if k < len(marcas) else None
                if k == 3 and len(marcas) >= 4:
                    ini, fin = marcas[3], None
                sel = [r for r in filas if r["consulta"] == q
                       and (ini is None or datetime.fromisoformat(r["instante"]) >= ini)
                       and (fin is None or datetime.fromisoformat(r["instante"]) < fin)]
                if not sel:
                    continue
                okms = [float(r["ms"]) for r in sel if r["ok"] == "t"]
                lineas.append(f"| {q} | {nombres_f[k]} | {len(okms)} | {len(sel) - len(okms)} | "
                              f"{statistics.median(okms):.1f} |" if okms else
                              f"| {q} | {nombres_f[k]} | 0 | {len(sel)} | - |")
        errores = sorted({r["error"] for r in filas if r["ok"] != "t"})
        lineas += ["", "Mensajes de error observados:", ""] + [f"- `{e}`" for e in errores] + [""]


def main():
    os.makedirs(GRAF, exist_ok=True)
    lineas = ["# Resultados distribuidos (semanas 8 y 9)", "",
              "Generado por `distributed/scripts/analizar_dist.py` a partir de los archivos de `distributed/results/`.", ""]
    consultas(lineas)
    pgbench(lineas)
    replicacion(lineas)
    caida(lineas)
    with open(os.path.join(BASE, "resumen.md"), "w") as f:
        f.write("\n".join(lineas) + "\n")
    print("resumen escrito en distributed/results/resumen.md")


if __name__ == "__main__":
    main()
