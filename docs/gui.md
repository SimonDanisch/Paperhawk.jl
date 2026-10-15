# Scanner mit visueller Kontrolle

Paperhawk ist ein natives GLMakie-Fenster. Links stehen Livebild und
Seitenfolge, in der Mitte die große Dokumentansicht, rechts die Korrekturen.
Das Fenster öffnet maximiert; **F11** wechselt ins Vollbild und zurück.
**Ganze Seite** zeigt die vollständige Aufnahme, **Text lesen** vergrößert den
erkannten Textbereich. Mausrad und Ziehen vergrößern und verschieben die
Seitenansicht; der sichtbare Ausschnitt wird bis zur vollen Auflösung nachgeladen.

## Starten

```sh
julia --project=. tools/scanner.jl                    # beste GPU
julia --project=. tools/scanner.jl --gpu "RTX 4000"   # eine bestimmte GPU
```

Weitere Optionen: `--classify` lässt das lokale LLM archivierte Dokumente
zusammenfassen, `--no-torch` lässt die Handy-LED aus. Danach optional der
Entwurfsordner und der Archivordner. Ohne Angaben entsteht ein neuer Entwurf in
`~/Documents/Paperhawk/scans`, archiviert wird nach `~/Documents/Paperhawk/archiv`.
Beide liegen außerhalb des Repositorys, weil sie private Dokumente enthalten.

Aus Julia heraus:

```julia
using Paperhawk
scanner(; select = "RTX 4000", classify = true)
```

`scanner` kehrt zurück, wenn das Fenster geschlossen wird, und gibt dann
Kamera, Entwurf, Archiv und GPU-Speicher frei. Wer die Teile selbst besitzen
will, nimmt `scanner_gui(; ocr, archive, ...)` und zeigt `ui.figure` an.

## Ablauf

1. **Kamera verbinden** und das Livebild prüfen. Die Kamera startet pausiert.
2. **Automatik starten**. Bei Duplex: Vorderseite aufnehmen, umdrehen, Rückseite
   aufnehmen, dann das nächste Blatt. Ein Piepton quittiert die Erfassung.
   Auch leere Rückseiten erfassen; sie bleiben als Rückseite zugeordnet.
   Dasselbe Blatt wird automatisch nie zweimal erfasst; für eine bewusste
   Neuaufnahme gibt es **Einmal erfassen** und **Seite neu aufnehmen**.
3. In der Mitte erscheint die Aufnahme, erst als Original, dann bereinigt und
   gelesen. „OCR fertig“ heißt, dass die Verarbeitung beendet ist, nicht dass
   sie fehlerfrei ist. Leere Seiten werden als „Leer erkannt“ markiert und aus
   dem PDF ausgelassen. Unsichere Wörter (Konfidenz unter 80 von 100) sind orange
   umrandet; ein Klick auf ein Wort öffnet es zur Korrektur. Ohne erkannte
   Blattecken heißt es „Blattrand fehlt · Zuschneiden nötig“, und **Zuschneiden**
   nimmt vier Ecken per Klick.
4. **Neues Dokument**, **Zusammenfügen**, **Früher**, **Später** und
   **Auslassen** ordnen Seiten zu Dokumenten. Jede Änderung lässt sich mit
   **Rückgängig** zurücknehmen; der Entwurf überlebt einen Neustart.
5. **Geprüft · Archivieren** vergibt die dauerhaften Dokumentnummern in der
   geprüften Reihenfolge. Die Originale in genau dieser Reihenfolge abheften.

## Was auf der GPU läuft

Alle Bildverarbeitung läuft über Mantle auf der GPU, ohne CPU-Ersatzweg:

- **Livebild:** Blatterkennung, Kantenvermessung und die Miniaturen für den
  Auslöser, auf einem eigenen Gerät und Thread (`PageDetector`).
- **Seiten:** Entzerren aus dem Kamerabild, optional UVDoc, Beleuchtung,
  Weißabgleich, Kontrast, Leerseitenprüfung, Drehung und die Ausgabe in Farbe,
  Grau oder Schwarzweiß (`process_page`). Ausrichtung und Texterkennung kommen
  aus PPOCRRunner, auf demselben Gerät; die Seite bleibt dazwischen auf der GPU.
- **Vorschau:** die Kacheln der Seitenansicht (`Paperhawk.Previews`).

Jeder dieser Teile ist ein `GPUWorker`: ein Task auf einem eigenen Thread, der
sein Gerät besitzt und Aufträge nacheinander ausführt, denn Mantle reicht Arbeit
nur von dem Thread ein, der das Gerät erzeugt hat. So wartet das Livebild nie
auf die Texterkennung. Julia deshalb mit mehreren Threads starten; das tut
`julia` mit `--threads=auto` oder ohne Angabe bei gesetztem `JULIA_NUM_THREADS`.

Das LLM (`BonsaiClassifier(ocr)`) teilt sich Gerät und Thread der OCR in einem
eigenen Task. Es gibt Vorrang: Solange Seiten in der Warteschlange stehen oder
die Automatik läuft, wartet es vor jedem Prompt-Block und jedem Ausgabetoken.
Bereits eingereichte GPU-Arbeit läuft zu Ende.

Gekrümmte Seiten begradigt UVDoc vor der Bereinigung: `scanner_gui(; dewarp = true)`
oder `process_page(ocr, img; dewarp = true)`. Das Modell wird beim ersten Bedarf
auf dem Gerät der OCR geladen.

## Speicher

Vier wiederverwendete Aufnahmepuffer begrenzen, wie viele Originale gleichzeitig
im RAM liegen; zwei Seiten werden parallel gespeichert und verarbeitet. Sind alle
vier belegt, wartet die nächste Erfassung. Entwurfs-PNGs werden direkt aus den
Pixeln geschrieben und beim Laden in wiederverwendete Puffer gelesen; die
Vorschau behält die letzten vier Seiten dekodiert. Die Seitenverarbeitung
verwendet ihre GPU-Puffer und aufgezeichneten Pläne wieder, solange sich die
Seitengröße nicht ändert.
