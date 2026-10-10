"""Nordvik Fastigheter AB - hyresgästportal, felanmälan.

Routes:
  GET  /felanmalan         formuläret (rubrik, beskrivning, kategori, bild)
  POST /felanmalan         sparar bild + uppgifter i privat lagring och meddelar Power Automate
  GET  /mina-anmalningar   den inloggade hyresgästens egna anmälningar
  GET  /halsa              hälsokontroll: når appen lagringen via private endpoint?

Appen loggar in mot lagringen med sin managed identity. Inga nycklar finns i koden
eller i appinställningarna. Hyresgästens identitet kommer från Entra ID-inloggningen
(App Service Authentication), som lägger in headern X-MS-CLIENT-PRINCIPAL-ID.
"""

import html
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from urllib import error as urlerror
from urllib import request as urlrequest

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

KATEGORIER = {
    "varme": "Värme",
    "vatten": "Vatten / avlopp",
    "las": "Lås / dörr",
    "el": "El / belysning",
    "vitvaror": "Vitvaror",
    "ventilation": "Ventilation",
    "ovrigt": "Övrigt",
}
AKUTA = {k.strip() for k in os.environ.get("AKUTA_KATEGORIER", "varme,vatten,las").split(",") if k.strip()}
BILDTYPER = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic"}
MAX_BILD_BYTES = int(os.environ.get("MAX_BILD_MB", "10")) * 1024 * 1024
MAX_RUBRIK = 100
MAX_BESKRIVNING = 2000

_blob_service = None


# ---------------------------------------------------------------- hjälpfunktioner

def lagring():
    """Container-klient för felanmälningar, autentiserad med appens managed identity."""
    global _blob_service
    if _blob_service is None:
        _blob_service = BlobServiceClient(
            account_url=os.environ["DATA_STORAGE_URL"],
            credential=DefaultAzureCredential(),
        )
    return _blob_service.get_container_client(os.environ.get("CONTAINER_FELANMALAN", "felanmalningar"))


def inloggad_hyresgast(req: func.HttpRequest):
    """Returnerar {'id', 'namn'} för den inloggade, eller None om inloggning krävs men saknas."""
    oid = req.headers.get("x-ms-client-principal-id")
    namn = req.headers.get("x-ms-client-principal-name")
    if oid:
        return {"id": oid, "namn": namn or oid}
    if os.environ.get("KRAV_INLOGGNING", "true").lower() == "true":
        return None
    # Första deployen, innan Entra-inloggningen är påslagen.
    return {"id": "demo-hyresgast", "namn": "Demo (inloggning ej aktiverad)"}


def skicka_till_flode(anmalan: dict) -> bool:
    """POST:ar anmälan till Power Automate. Tre försök med backoff, tål throttling (429)."""
    url = os.environ.get("FLOW_URL", "")
    if not url:
        logging.warning("FLOW_URL saknas, ingen notis skickad för %s", anmalan["arendeId"])
        return False
    data = json.dumps(anmalan, ensure_ascii=False).encode("utf-8")
    for forsok in range(3):
        try:
            req = urlrequest.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json; charset=utf-8"})
            with urlrequest.urlopen(req, timeout=10) as svar:
                if 200 <= svar.status < 300:
                    return True
        except (urlerror.URLError, TimeoutError) as fel:
            logging.warning("Flödet svarade inte (försök %s) för %s: %s", forsok + 1, anmalan["arendeId"], fel)
        time.sleep(2 ** forsok)
    return False


def sida(titel: str, innehall: str, status: int = 200) -> func.HttpResponse:
    return func.HttpResponse(SIDMALL.format(titel=html.escape(titel), innehall=innehall),
                             status_code=status, mimetype="text/html", charset="utf-8")


def e(text) -> str:
    return html.escape(str(text or ""))


# ---------------------------------------------------------------- routes

@app.route(route="felanmalan", methods=["GET", "POST"])
def felanmalan(req: func.HttpRequest) -> func.HttpResponse:
    hyresgast = inloggad_hyresgast(req)
    if hyresgast is None:
        return sida("Logga in", "<p>Du måste vara inloggad för att göra en felanmälan.</p>", 401)

    if req.method == "GET":
        return sida("Felanmälan", formular(hyresgast))

    form = req.form
    rubrik = (form.get("rubrik") or "").strip()
    beskrivning = (form.get("beskrivning") or "").strip()
    kategori = (form.get("kategori") or "").strip()
    fastighet = (form.get("fastighet") or "").strip()[:100]
    lagenhet = (form.get("lagenhet") or "").strip()[:20]
    bild = req.files.get("bild")
    bilddata = bild.read() if bild else b""
    bildtyp = (bild.content_type or "").split(";")[0].strip().lower() if bild else ""

    fel = []
    if not rubrik or len(rubrik) > MAX_RUBRIK:
        fel.append(f"Rubrik krävs (högst {MAX_RUBRIK} tecken).")
    if not beskrivning or len(beskrivning) > MAX_BESKRIVNING:
        fel.append(f"Beskrivning krävs (högst {MAX_BESKRIVNING} tecken).")
    if kategori not in KATEGORIER:
        fel.append("Välj en kategori.")
    if not fastighet:
        fel.append("Ange adress eller fastighet.")
    if not bilddata:
        fel.append("Bifoga en bild på felet.")
    elif len(bilddata) > MAX_BILD_BYTES:
        fel.append(f"Bilden är för stor (högst {MAX_BILD_BYTES // (1024 * 1024)} MB).")
    elif bildtyp not in BILDTYPER:
        fel.append("Bilden måste vara JPG, PNG, WEBP eller HEIC.")
    if fel:
        return sida("Felanmälan", formular(hyresgast, form, fel), 400)

    arende_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    mapp = f"{hyresgast['id']}/{arende_id}"
    bild_blob = f"{mapp}/bild.{BILDTYPER[bildtyp]}"

    anmalan = {
        "arendeId": arende_id,
        "skapad": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "rubrik": rubrik,
        "beskrivning": beskrivning,
        "kategori": kategori,
        "kategoriNamn": KATEGORIER[kategori],
        "akut": kategori in AKUTA,
        "fastighet": fastighet,
        "lagenhet": lagenhet,
        "hyresgastId": hyresgast["id"],
        "hyresgastNamn": hyresgast["namn"],
        "bildBlob": bild_blob,
        "status": "Ny",
        "miljo": os.environ.get("MILJO", ""),
    }

    try:
        c = lagring()
        c.upload_blob(bild_blob, bilddata, overwrite=False,
                      content_settings=ContentSettings(content_type=bildtyp))
        c.upload_blob(f"{mapp}/anmalan.json", json.dumps(anmalan, ensure_ascii=False, indent=2).encode("utf-8"),
                      overwrite=False,
                      content_settings=ContentSettings(content_type="application/json; charset=utf-8"))
    except Exception:  # noqa: BLE001 - visa ett begripligt fel för hyresgästen, logga detaljerna
        logging.exception("Kunde inte spara anmälan %s", arende_id)
        return sida("Något gick fel",
                    "<p>Anmälan kunde inte sparas just nu. Försök igen om en stund. "
                    "Vid akuta fel, ring felanmälan.</p>", 503)

    notis_skickad = skicka_till_flode(anmalan)
    if not notis_skickad:
        # Anmälan är sparad men förvaltaren har inte fått notis. Lägg den i en kö så den inte tappas bort.
        try:
            lagring().upload_blob(f"olevererade/{arende_id}.json",
                                  json.dumps(anmalan, ensure_ascii=False).encode("utf-8"), overwrite=True)
        except Exception:  # noqa: BLE001
            logging.exception("Kunde inte köa olevererad notis %s", arende_id)

    logging.info("Felanmälan %s sparad (kategori=%s, akut=%s, notis=%s)",
                 arende_id, kategori, anmalan["akut"], notis_skickad)
    akut_text = ("<p class='akut'>Akut kategori: förvaltaren har fått ett mejl direkt.</p>"
                 if anmalan["akut"] and notis_skickad else "")
    return sida("Tack för din anmälan", f"""
      <div class="kvitto">
        <h2>Tack! Din felanmälan är mottagen.</h2>
        <p>Ärendenummer: <strong>{e(arende_id)}</strong></p>
        <p>{e(rubrik)} ({e(KATEGORIER[kategori])}), {e(fastighet)} {e(lagenhet)}</p>
        {akut_text}
        <p><a href="/felanmalan">Gör en ny anmälan</a> · <a href="/mina-anmalningar">Mina anmälningar</a></p>
      </div>""")


@app.route(route="mina-anmalningar", methods=["GET"])
def mina_anmalningar(req: func.HttpRequest) -> func.HttpResponse:
    hyresgast = inloggad_hyresgast(req)
    if hyresgast is None:
        return sida("Logga in", "<p>Du måste vara inloggad.</p>", 401)

    c = lagring()
    poster = []
    # Prefixet är hyresgästens eget objekt-ID: man ser bara sina egna anmälningar.
    for blob in c.list_blobs(name_starts_with=f"{hyresgast['id']}/"):
        if blob.name.endswith("/anmalan.json"):
            poster.append(json.loads(c.download_blob(blob.name).readall()))
    poster.sort(key=lambda p: p.get("skapad", ""), reverse=True)

    if not poster:
        rader = "<p>Du har inga felanmälningar än.</p>"
    else:
        rader = "<table><thead><tr><th>Datum</th><th>Ärende</th><th>Rubrik</th><th>Kategori</th></tr></thead><tbody>"
        for p in poster:
            rader += (f"<tr><td>{e(p.get('skapad', '')[:10])}</td><td>{e(p.get('arendeId'))}</td>"
                      f"<td>{e(p.get('rubrik'))}</td><td>{e(p.get('kategoriNamn'))}</td></tr>")
        rader += "</tbody></table>"
    return sida("Mina anmälningar", f"""
      <p class="inloggad">Inloggad som {e(hyresgast['namn'])}</p>
      {rader}
      <p><a href="/felanmalan">Gör en ny felanmälan</a></p>""")


@app.route(route="halsa", methods=["GET"])
def halsa(req: func.HttpRequest) -> func.HttpResponse:
    """Verifierar att appen når den privata lagringen. Visar inga data."""
    resultat = {"app": "ok", "miljo": os.environ.get("MILJO", "")}
    status = 200
    try:
        next(iter(lagring().list_blobs(results_per_page=1)), None)
        resultat["lagring"] = "ok"
    except Exception as fel:  # noqa: BLE001
        logging.exception("Hälsokontroll mot lagringen misslyckades")
        resultat["lagring"] = f"fel: {type(fel).__name__}"
        status = 503
    resultat["flode"] = "konfigurerat" if os.environ.get("FLOW_URL") else "saknas"
    return func.HttpResponse(json.dumps(resultat, ensure_ascii=False), status_code=status,
                             mimetype="application/json", charset="utf-8")


# ---------------------------------------------------------------- HTML

def formular(hyresgast: dict, varden=None, fel=None) -> str:
    varden = varden or {}
    felruta = ""
    if fel:
        felruta = "<div class='fel'><ul>" + "".join(f"<li>{e(f)}</li>" for f in fel) + "</ul></div>"
    vald = varden.get("kategori", "")
    alternativ = "".join(
        f"<option value='{k}'{' selected' if k == vald else ''}>{e(v)}{' (akut)' if k in AKUTA else ''}</option>"
        for k, v in KATEGORIER.items()
    )
    return f"""
      <p class="inloggad">Inloggad som {e(hyresgast['namn'])} · <a href="/mina-anmalningar">Mina anmälningar</a></p>
      {felruta}
      <form method="post" action="/felanmalan" enctype="multipart/form-data">
        <label>Rubrik
          <input name="rubrik" maxlength="{MAX_RUBRIK}" required value="{e(varden.get('rubrik'))}"
                 placeholder="T.ex. Droppande kran i köket">
        </label>
        <label>Kategori
          <select name="kategori" required><option value="">Välj kategori</option>{alternativ}</select>
        </label>
        <div class="rad">
          <label>Adress / fastighet
            <input name="fastighet" maxlength="100" required value="{e(varden.get('fastighet'))}"
                   placeholder="T.ex. Björkvägen 12">
          </label>
          <label>Lägenhetsnummer
            <input name="lagenhet" maxlength="20" value="{e(varden.get('lagenhet'))}" placeholder="T.ex. 1102">
          </label>
        </div>
        <label>Beskrivning
          <textarea name="beskrivning" rows="5" maxlength="{MAX_BESKRIVNING}" required
                    placeholder="Beskriv felet, var det sitter och sedan när det funnits.">{e(varden.get('beskrivning'))}</textarea>
        </label>
        <label>Bild på felet
          <input type="file" name="bild" accept="image/jpeg,image/png,image/webp,image/heic" required>
          <small>JPG, PNG, WEBP eller HEIC, högst {MAX_BILD_BYTES // (1024 * 1024)} MB.</small>
        </label>
        <button type="submit">Skicka felanmälan</button>
      </form>
      <p class="info">Akuta fel (värme, vatten, lås) går direkt till ansvarig förvaltare.
      Vid fara för liv eller egendom, ring 112.</p>"""


SIDMALL = """<!doctype html>
<html lang="sv">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{titel} · Nordvik Fastigheter</title>
<style>
  :root {{ --bla:#1f4e79; --ljus:#eef3f8; --text:#1d2733; --fel:#a4262c; --kant:#c8d3df; }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif; color:var(--text); background:var(--ljus); }}
  header {{ background:var(--bla); color:#fff; padding:16px; }}
  header h1 {{ margin:0; font-size:1.15rem; font-weight:600; }}
  header span {{ opacity:.8; font-size:.9rem; }}
  main {{ max-width:640px; margin:24px auto; background:#fff; padding:24px; border-radius:8px; border:1px solid var(--kant); }}
  h2 {{ margin-top:0; }}
  label {{ display:block; margin:0 0 14px; font-weight:600; font-size:.95rem; }}
  input, select, textarea {{ display:block; width:100%; margin-top:4px; padding:10px; font:inherit; font-weight:400;
    border:1px solid var(--kant); border-radius:6px; }}
  .rad {{ display:grid; grid-template-columns: 2fr 1fr; gap:12px; }}
  small {{ font-weight:400; color:#5a6775; }}
  button {{ background:var(--bla); color:#fff; border:0; padding:12px 20px; border-radius:6px; font:inherit; font-weight:600; cursor:pointer; }}
  .fel {{ border-left:4px solid var(--fel); background:#fbeaea; padding:8px 12px; margin-bottom:16px; }}
  .akut {{ color:var(--fel); font-weight:600; }}
  .inloggad, .info {{ color:#5a6775; font-size:.9rem; }}
  table {{ width:100%; border-collapse:collapse; font-size:.9rem; }}
  th, td {{ text-align:left; padding:8px 6px; border-bottom:1px solid var(--kant); }}
  a {{ color:var(--bla); }}
  @media (max-width:520px) {{ main {{ margin:0; border-radius:0; }} .rad {{ grid-template-columns:1fr; }} }}
</style>
</head>
<body>
<header><h1>Nordvik Fastigheter</h1><span>Hyresgästportal · {titel}</span></header>
<main>{innehall}</main>
</body>
</html>"""
