# Power Automate-flödet: Felanmälan till förvaltare

Flödet tar emot varje inskickad felanmälan från Function-appen och integrerar den med Nordviks Microsoft 365.

```
Function App ──HTTPS POST──▶ [Trigger: When a HTTP request is received]
                                   │
                                   ├─▶ SharePoint: Create item i listan "Felanmälningar"
                                   ├─▶ SharePoint: Get items i listan "Fastigheter" (vem är ansvarig förvaltare?)
                                   ├─▶ Teams: notis i kanalen "Felanmälningar"
                                   └─▶ Condition: akut = true
                                          └─ Ja ─▶ Outlook: mejl till ansvarig förvaltare (hög prioritet)
```

Appen skickar bara uppgifterna, aldrig själva bilden. Bilden ligger kvar i den privata lagringen och flödet får bara sökvägen (`bildBlob`). Det betyder att Power Automate aldrig behöver nå lagringskontot, som är stängt för internet.

## 1. SharePoint-listor

Skapa en SharePoint-webbplats, till exempel **Nordvik Förvaltning**, med två listor.

**Felanmälningar**

| Kolumn | Typ | Kommentar |
|---|---|---|
| Title | Enkel rad | Rubriken |
| ArendeId | Enkel rad | Unikt, indexera kolumnen |
| Beskrivning | Flera rader | |
| Kategori | Enkel rad | |
| Akut | Ja/Nej | |
| Fastighet | Enkel rad | |
| Lagenhet | Enkel rad | |
| Hyresgast | Enkel rad | Namn eller e-post från inloggningen |
| Bildsokvag | Enkel rad | Sökväg i lagringen, t.ex. `<oid>/<ärende>/bild.jpg` |
| Status | Val | Ny (standard), Pågår, Åtgärdad |
| Inkommen | Datum och tid | |

**Fastigheter** (koppling fastighet → ansvarig förvaltare)

| Kolumn | Typ |
|---|---|
| Title | Enkel rad (adress, t.ex. Björkvägen 12) |
| Forvaltare | Person |

**Behörigheter på webbplatsen (least privilege):**
- `grp-nordvik-forvaltare`: Redigera (hanterar anmälningarna, ändrar status).
- `grp-nordvik-ekonomi`: Läsa (läsande insyn).
- Hyresgäster: ingen åtkomst. De ser sina egna anmälningar i portalen under *Mina anmälningar*.

## 2. Flödet steg för steg

1. **Trigger: When a HTTP request is received** (premium). Klistra in [trigger-schema.json](trigger-schema.json) under *Request Body JSON Schema*. Välj *Who can trigger the flow: Anyone*. Anropet skyddas av signaturen i URL:en, som därför behandlas som en hemlighet.
2. **Create item** (SharePoint), lista *Felanmälningar*:
   - Title = `rubrik`, ArendeId = `arendeId`, Beskrivning = `beskrivning`, Kategori = `kategoriNamn`, Akut = `akut`, Fastighet = `fastighet`, Lagenhet = `lagenhet`, Hyresgast = `hyresgastNamn`, Bildsokvag = `bildBlob`, Status = Ny, Inkommen = `skapad`.
3. **Get items** (SharePoint), lista *Fastigheter*, Filter Query: `Title eq '@{triggerBody()?['fastighet']}'`, Top Count: 1.
4. **Initialize variable** `forvaltareEpost` (String):
   `@{if(empty(body('Get_items')?['value']), 'forvaltning@<din-tenant>.onmicrosoft.com', first(body('Get_items')?['value'])?['Forvaltare']?['Email'])}`
   Ingen träff ger en gemensam förvaltningsbrevlåda, så ingen anmälan blir utan mottagare.
5. **Post message in a chat or channel** (Teams), Post as: Flow bot, Post in: Channel, team *Nordvik Förvaltning*, kanal *Felanmälningar*:
   `Ny felanmälan @{triggerBody()?['arendeId']}: @{triggerBody()?['rubrik']} (@{triggerBody()?['kategoriNamn']}), @{triggerBody()?['fastighet']} @{triggerBody()?['lagenhet']}. Ansvarig: @{variables('forvaltareEpost')}`
6. **Condition**: `akut` is equal to `true`.
   - **Ja: Send an email (V2)** (Outlook) till `forvaltareEpost`, Importance: High, ämne `AKUT felanmälan: @{triggerBody()?['rubrik']}`, med fastighet, lägenhet, beskrivning och ärendenummer i texten.
7. Spara, och kopiera **HTTP URL** från triggern. Den skickas in vid deploy (`FLOW_URL`) och hamnar som appinställning, aldrig i repot.

## 3. Robusthet

- Appen försöker tre gånger med ökande väntetid om flödet inte svarar (t.ex. throttling vid en vattenläcka med hundratals anmälningar).
- Om alla försök misslyckas sparas anmälan ändå, och en kopia läggs i `felanmalningar/olevererade/` så att ingen anmälan tappas bort.
- Under *Settings* på triggern kan *Concurrency control* slås på för att jämna ut toppar.

## 4. Versionshantering av flödet

Exportera flödet (*Export → Package (.zip)*) och lägg paketet i den här mappen när det är klart. Då finns även integrationsdelen i repot och kan importeras i en ny miljö.
