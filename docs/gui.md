# Scanner mit visueller Kontrolle

Die Makie-Oberfläche läuft als natives GLMakie-Fenster. Links stehen Kamera und
Seitenfolge, in der Mitte die große Dokumentansicht, rechts die Korrekturen.
Der Launcher öffnet das Fenster maximiert; **F11** wechselt ins Vollbild und zurück.
**Ganze Seite** zeigt die vollständige Aufnahme, **Text lesen** vergrößert den
erkannten Textbereich und pausiert die Automatik zur Prüfung.
Mausrad und Ziehen vergrößern bzw. verschieben die Seitenansicht. Die Übersicht
wird verkleinert übertragen; beim Zoomen wird der sichtbare Ausschnitt bis zur
vollen Originalauflösung nachgeladen. OCR-Markierungen behalten ihre ursprünglichen
Pixelkoordinaten. Während ein anderes Bild lädt, können keine Wörter oder
Zuschnittpunkte versehentlich auf dessen Vorgänger angewendet werden.

```julia
using Paperhawk, GLMakie

ocr = PaddleOCR() # eigener Julia-Thread, wiederverwendete GPU-Puffer
archive = DocumentArchive("mein-archiv")
ui = scanner_gui(; archive, ocr, dir="scans/stapel-001", duplex=true)
screen = display(GLMakie.Screen(; title="Paperhawk"), ui.figure)
```

Das Fenster wird auf dem lokalen Desktop geöffnet. Die Julia-Sitzung bleibt
während der Benutzung geöffnet. Nach dem erstmaligen Kompilieren lohnt es sich,
diese Sitzung für weitere Stapel zu behalten. Das Schließen des Fensters beendet
Kamera und Entwurfsverarbeitung; ein von außen übergebener OCR-Runner bzw. ein
Archiv bleiben Eigentum des Aufrufers.

Direkt auf Display `:1` starten, mit begrenztem Speicher und automatischer
Freigabe von OCR und Archiv beim Beenden:

Der lokale Launcher ist auf die **NVIDIA RTX 4000 Ada Generation** festgelegt.
Er prüft das Gerät vor dem Laden der Modelle und bricht bei einer abweichenden
GPU-Auswahl ab. GLMakie und Vulkan verwenden den NVIDIA-Treiber.

```sh
DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/scanner_gui.jl scans/stapel-001 mein-archiv
```

Dabei muss die Sitzung Zugriff auf das X11-Display haben (`XAUTHORITY` aus der
Desktop-Sitzung übernehmen, falls nötig). Die Kamera wird erst mit „Kamera
verbinden“ geöffnet. Für einen anderen Desktop dessen `DISPLAY` verwenden.

Für die Handy-LED als Dauerlicht dem Launcher `--torch` mitgeben. In Julia:
`scanner_gui(; camera_torch=true, ...)` beziehungsweise `PhoneCamera(; torch=true)`.
Die Einstellung gilt beim Öffnen der Kamera; zum Ändern die Kamera neu öffnen.

1. **Kamera verbinden** und das Livebild prüfen. Die Kamera startet pausiert.
2. **Automatik starten**. Bei Duplex: Vorderseite aufnehmen, umdrehen, Rückseite
   aufnehmen, dann das nächste Blatt. Ein Piepton quittiert die Erfassung.
   Auch leere Rückseiten erfassen; sie bleiben als Rückseite zugeordnet.
3. In der Mitte erscheint die Aufnahme, zunächst während ihrer Verarbeitung, dann
   bereinigt und mit OCR. Originale werden unabhängig von der OCR-Warteschlange
   gespeichert, damit die nächste Vorschau nicht auf die vorige Texterkennung
   warten muss. „OCR fertig“ bedeutet, dass die Verarbeitung beendet
   ist; es ist keine Qualitätsgarantie. Leere Seiten werden als „Leer erkannt“
   markiert und standardmäßig aus dem PDF ausgelassen.
   Unsichere OCR-Wörter (Konfidenz unter 80/100) sind orange umrandet. Auch eine
   hohe Konfidenz schließt Lesefehler nicht aus. Ohne erkannten Text erscheint
   ein ausdrücklicher Hinweis.
   Die GPU-OCR liest unsichere Zeilen automatisch ein zweites Mal mit 1,5-facher
   Eingabebreite und behält das Ergebnis mit höherer Konfidenz. Das hilft, wenn
   gebogene Zeilen durch die Skalierung zu schmale Buchstaben bekommen.
   Der zusätzliche Versuch bleibt auf die vorhandenen GPU-Puffergrößen begrenzt.
   Wenn keine Blattecken erkannt wurden, erscheint ausdrücklich
   „Blattrand fehlt · Zuschneiden nötig“: Eine manuelle Aufnahme enthält dann
   zunächst das ganze Kamerabild. „Zuschneiden“ korrigiert die vier Ecken.
4. Nach der Sichtprüfung **Geprüft · Archivieren**. Jetzt werden die dauerhaften
   Dokumentnummern in der geprüften Reihenfolge vergeben. Die Originale in
   genau dieser Reihenfolge abheften. Die LLM-Klassifikation läuft nachgelagert.

## Aufnahme, OCR und Zusammenfassung

Julia mit `--threads=4,1` starten: Der interaktive Thread bedient die Oberfläche,
der GPU-Worker gehört zum separaten Standard-Threadpool. `PaddleOCR()` nutzt
standardmäßig diesen Worker; `PaddleOCR(execution=:process)` bleibt ausdrücklich
als Alternative verfügbar. Ein Worker serialisiert die Modellzugriffe und bleibt
auch beim Schließen und erneuten Öffnen eines OCR-Modells auf demselben Thread.

Vier wiederverwendete Aufnahme-Puffer begrenzen die Zahl gleichzeitig im RAM
gehaltener Originale. Zwei Seiten werden parallel gespeichert und verarbeitet.
Wenn alle vier Puffer belegt sind, wartet die nächste Erfassung auf einen freien
Puffer; die Warteschlange wächst nicht unbegrenzt mit großen Bildarrays.
Der Piepton erfolgt erst nach der Übernahme. Die Originalvorschau wird unabhängig
von der OCR früherer Seiten gespeichert. Das bereinigte Bild kann bereits während
der Texterkennung angezeigt werden.

Zuschnitt, optionale UVDoc-Entzerrung, Beleuchtungskorrektur, Weißabgleich,
Kontrast, Leerprüfung, Drehung, OCR-Skalierungen und Textregionen laufen im
Farbmodus auf der GPU. Für UVDoc dasselbe Gerät verwenden:

```julia
dewarper = uvdoc(ocr)
ui = scanner_gui(; archive, ocr, dewarper, dir="scans/stapel-002")
```

Die aufgenommenen Pixel werden einmal hochgeladen. Große Zwischenbilder,
UVDoc-Gitter und Detektor-Wahrscheinlichkeiten bleiben auf der GPU. Zur CPU
kommen die fertige Bildkopie für Datei/GUI sowie kleine OCR-Ergebnisse und
Prüfdaten zurück. Bei gleichbleibender Geometrie werden Mantle-Pläne und Puffer
wiederverwendet; bei einer Größenänderung wird der vorherige Arbeitsbereich
freigegeben. Der Zuschnitt interpoliert aus einem persistenten Float32-Puffer:
Direktes Interpolieren aus gepackten RGB/N0f8-Pixeln löste auf RADV einen
GPU-Speicherzugriffsfehler aus.

Die gesamte Anwendung ist **nicht allocationsfrei**: Wortlisten, PNG/PDF-Codierung,
GUI und Datenbank benötigen weiterhin Speicher. Die reine aufgewärmte
GPU-Bildbereinigung benötigte im Test 1104 Bytes
Julia-Allokationen und etwa 23 ms für 2481 × 3508 Pixel. Die fertige Farbkopie
belegt bei dieser Größe etwa 26 MB und darf nicht vom nächsten Scan überschrieben
werden. Der Entwurf verwendet dafür zwei eigene Ausgabepuffer, die erst nach
Abschluss von OCR und Dateispeicherung erneut benutzt werden. Direkte Aufrufe
der Seitenverarbeitung liefern weiterhin ein unabhängiges Ergebnisbild.
Graustufen- und Schwarzweiß-Ausgabe entstehen ebenfalls auf der GPU; es gibt
keinen CPU-Bereinigungspfad. Seiten unter 120 Pixeln Kantenlänge werden
abgelehnt. Garbage Collection bleibt eingeschaltet.

Die Entwurfs-PNGs werden direkt aus der vorhandenen Pixelanordnung geschrieben;
Speichern erzeugt keine vollständige Bildkopie. Beim Laden entsteht genau ein
RGB-Ergebnisarray; die Vorschau verwendet bis zu vier dieser Arrays wieder.
Beim Verkleinern bleibt das geliehene Array gesperrt, damit ein parallel ladendes
Bild es nicht überschreibt. Auch die Livebild-Anzeige verwendet ihren Puffer erneut.
Die nativen PNG-Aufrufe erlauben GC auf anderen Threads.
Beim Schließen eines Entwurfs werden dessen Aufnahmepuffer ausdrücklich geleert.
OCR lädt UVDoc und Bonsai erst dann zusätzlich, wenn sie angefordert werden.
Beim Speichern werden die vorhandenen Wortdaten direkt serialisiert; es entstehen
keine neuen Dictionaries für jedes Wort aller bisherigen Seiten.

Zusammenfassung und Kategorie entstehen nach der Archivierung asynchron.
Dokumentnummer, PDF und Volltextsuche sind vorher verfügbar. Ausstehende
Zusammenfassungen stehen in der Oberfläche und werden nach einem Neustart des
Archivs wieder aufgenommen. Optional kann Bonsai denselben GPU-Thread nutzen:

```julia
classifier = BonsaiClassifier(ocr)
archive = DocumentArchive("mein-archiv"; classifier)
```

Während die Kamera-Automatik aktiv ist oder OCR-Aufträge warten, hält Bonsai an.
Zwischen Prompt-Blöcken von 64 Tokens und einzelnen Ausgabetokens gibt es den
Worker frei. Bereits gestartete GPU-Arbeit kann nicht sofort unterbrochen werden.
Die visuelle Seitenprüfung muss nicht auf Zusammenfassungen warten; Modellangaben
bleiben im Archiv nachträglich korrigierbar.

### Native Oberfläche geprüft

Nach dem Layoutumbau bestehen auf Display `:1` **55 GUI-Prüfungen**, einschließlich
1280 × 800 und 1920 × 1080, sichtbarer Bedienelemente, Textvergrößerung,
Wortkorrektur, Rückgängig und Archivierung. Die Vollbilddarstellung wurde
zusätzlich bei 2784 × 1566 mit einer gespeicherten Beispielaufnahme angesehen.
Dieser Layouttest lädt weder OCR- noch Bonsai-Modelle; die Kamera ist ausgeschaltet.

[Vollbild](../gen/scanner-layout-fullscreen.png) ·
[Textansicht](../gen/scanner-layout-text.png) ·
[Testprotokoll](../gen/gui-layout-tests.log).

```sh
DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/test_glmakie.jl --gui-only
```

Vor dem Layoutumbau bestanden 41 GUI-Prüfungen einschließlich Fensterlebenszyklus,
Seitenmenü, OCR-Wortauswahl per Mausklick, Korrektur, Rückgängig und Archivierung.
Vier weitere Prüfungen bestätigen GPU-OCR und Darstellung eines Beispielbriefs
im nativen Fenster (83 Wörter). Dabei wurden auch die zuvor gespiegelte große
Vorschau und das Optionsformat des Vorder-/Rückseiten-Menüs korrigiert.
Der normale Launcher erreichte in diesem Test maximal 3,04 GiB residenten RAM,
bei unveränderten harten Speichergrenzen von 6/12 GiB.

[Screenshot](../gen/scanner-glmakie-current.png) ·
[Testprotokoll](../gen/glmakie-test-2026-10-12.log) ·
[Ergebnis](../gen/glmakie-test-2026-10-12.json).
Die Kamera war nicht verbunden; Bonsai lief in diesem GLMakie-Test nicht mit.

```sh
DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/test_glmakie.jl --keep-open
```

Ohne `--keep-open` schließt der Test nach dem Screenshot Fenster und Modelle.

### Bisherige Messungen und Speichergrenzen

Die folgenden Zahlen stammen noch von der früheren WGLMakie-Version und sind
keine Messwerte des nativen GLMakie-Fensters. Die Benchmark-Skripte verwenden
jetzt sichtbare GLMakie-Fenster und schreiben neue Dateien mit `-glmakie-` im
Namen, damit die früheren Ergebnisse erhalten bleiben.

Der normale Launcher auf Ryzen 9 7900X / Radeon RX 7900 XTX lieferte am
12.10.2026 mit 2481 × 3508 Pixeln folgende Werte. Modell, Bildverarbeitung,
Livebild und GUI-Bedienung wurden vor der Messung aufgewärmt:

| Messung | Ergebnis |
| --- | --- |
| GUI, 30 Seiten | 9,15 s, keine Verarbeitungsfehler |
| GUI, 120 Seiten | 36,00 s, keine Verarbeitungsfehler |
| Längster Abstand der Julia-GUI-Ereignisse im 120-Seiten-Lauf | 70 ms |
| Längste Knopf-Reaktion auf Julia-Seite | 8,4 ms |
| Drei separate Stapel ohne GUI, jeweils 6 Seiten | 0,32–0,37 s/Seite |
| Maximaler residenter RAM-Verbrauch des Benchmark-Prozesses | 3,30 GiB |

Eine separate Einzelaufnahme nahm den Bildpuffer in 29 ms an. Die Originaldatei
war nach 77 ms, die bereinigte Datei nach 167 ms und das OCR-Ergebnis nach
431 ms verfügbar. Das sind Dateiverfügbarkeit und Verarbeitungsstand auf
Julia-Seite, keine gemessenen Browser-Darstellungszeiten. Ein schnellerer
Stapel-Durchsatz als die Einzelbild-Latenz entsteht durch überlappende Arbeit.

Die [vollständigen Messwerte](../gen/gpu-pipeline-2026-10-12.json) enthalten
auch GC-Zeiten und die einzelnen Erfassungszeiten. Reproduzierbarer Aufruf aus
einer lokalen Desktop-Sitzung:

```sh
tools/bounded-julia --startup-file=no --project=. tools/run_gpu_benchmark.jl --check-review
```

Dieser Lauf startet GUI und OCR im selben Julia-Prozess. Die Kamera wird durch
Testbilder simuliert; Bonsai ist nicht geladen. Erstmalige Kompilierung kann die
Anzeige weiterhin verzögern; die Zahlen oben gelten für den aufgewärmten Betrieb.

Der zusätzliche [Bonsai-Vergleich](../gen/bonsai-concurrent-2026-10-12.json)
verwendet `BonsaiClassifier(ocr)`: beide Modelle auf demselben GPU-Thread,
echte Klassifikation einer Beispielrechnung, dieselben Speichergrenzen.
Dabei war die Kamera-Automatik ausgeschaltet, damit Bonsai zwischen OCR-Aufträgen
weiterarbeiten durfte. Zusammenfassungen werden erst nach der separat gemessenen
Seitenverarbeitung abgewartet.

| Zustand | Seitenverarbeitung | Längste GUI-Ereignispause |
| --- | --- | --- |
| Nur OCR, 30 Seiten | 9,09 s | 77 ms |
| Bonsai geladen, ohne Auftrag, 30 Seiten | 9,26 s | 32 ms |
| Bonsai-Auftrag gleichzeitig, 30 Seiten | 11,18 s | 181 ms |
| Bonsai-Auftrag gleichzeitig, 120 Seiten | 38,39 s | 220 ms |

Alle Seiten wurden verarbeitet. Bonsai lieferte jeweils Kategorie, Absender,
Dokumentdatum und Zusammenfassung korrekt für diese Beispielrechnung.
Aufgewärmt dauerte der Auftrag allein 17,97 s; mit den Seitenstapeln 26,84 s
beziehungsweise 54,09 s. Bei beiden Stapeln war der Auftrag am Anfang und Ende
noch nicht abgeschlossen. Die längste Knopf-Reaktion im gemeinsamen 120-Seiten-Lauf
betrug 48 ms; der residente RAM-Höchststand des gesamten Prozesses 3,62 GiB.
Das ist keine unveränderte Reaktionszeit: gleichzeitige LLM-Arbeit erhöht hier
Scanzeit und einzelne Ereignispausen. Auch der anschließende Lauf mit ruhendem
Bonsai zeigte eine Ereignispause von 174 ms, sodass GPU-Konkurrenz allein diese
Pausen nicht erklärt.

```sh
tools/bounded-julia --startup-file=no --project=. tools/run_bonsai_benchmark.jl
```

Der separate [Automatik-Test](../gen/bonsai-automatic-2026-10-12.json) setzt die
echte `pause!`-Steuerung der GUI ein. Bonsai startet 0,2 s vor der Automatik;
nach deren Ende wird der Auftrag fortgesetzt. 120 Seiten benötigen mit geladenem,
untätigem Bonsai 37,02 s, mit dem bereits gestarteten Auftrag 38,55 s (+4,1 %).
Die Zusammenfassung liegt nach insgesamt 54,66 s korrekt vor. Alle Seiten sind
fehlerfrei verarbeitet; die längste Ereignispause beträgt 212 ms. Die Automatik
eliminiert also weder den gesamten Anlaufaufwand noch alle Ereignispausen.
Dieser Test misst zusätzlich die Zustellung von Ereignissen an den GUI-Thread
(maximal 8,1 ms), keine Navigationsknöpfe: „Nächste“ pausiert die Automatik
absichtlich und würde den getesteten Modus ändern.

```sh
tools/bounded-julia --startup-file=no --project=. tools/run_bonsai_benchmark.jl --automatic
```

Die Messung umfasst simuliertes Livebild und Knopf-Ereignisse auf Julia-Seite,
keine Browser-Darstellung, echte Kamera, UVDoc, PDF-Erzeugung oder Datenbank-Schreibarbeit.

Für lokale Benchmarks `tools/bounded-julia --project=.` verwenden. Das Skript
setzt überprüfbare Betriebssystemgrenzen von 6 GiB für Datenallokationen und
12 GiB für den gesamten virtuellen Adressraum einschließlich GPU-Abbildungen.
`--heap-size-hint=2G` unterstützt die GC, ersetzt diese Grenzen aber nicht.
Auf dem Ryzen 9 7900X verwendet der Launcher `--gcthreads=8,1`; vollständige
GC-Pausen werden dadurch parallel abgearbeitet. Die GC stoppt weiterhin alle
Julia-Threads und ist keine nebenläufige Echtzeit-GC.
Der Launcher begrenzt unter glibc außerdem die Zahl der malloc-Arenen auf zwei
und setzt die mmap-Schwelle auf 128 KiB. Große, nicht gepoolte Bildblöcke können
dadurch nach ihrer Freigabe an das Betriebssystem zurückgehen, statt in
fragmentierten malloc-Arenen zu verbleiben. Das ersetzt keine Freigabe von
Julia- oder GPU-Objekten.
In einer bestehenden Sitzung zuerst `tools/benchmark_limits.jl` laden und
`benchmark_memory_limit()` aufrufen, bevor Modelle geladen werden. Ein zu großer
Test muss abbrechen, statt diese Grenzen anzuheben. Keine vollständige
`Profile.Allocs`-Aufzeichnung für einen Seitenstapel verwenden.

```julia
include("tools/benchmark_limits.jl")
benchmark_memory_limit()
benchmark_native_allocator() # glibc; vor dem Laden von Scanner/GUI
include("tools/profile_review.jl")
ocr = PaddleOCR()
img = Paperhawk.permutedims(Paperhawk.load("gen/gui-demo-letter.png"))
benchmark_review(img, ocr; pages=2) # Aufwärmen
benchmark_review(img, ocr; pages=6, workers=2)
benchmark_ui(img, ocr)            # GUI-Timer und echte Schaltflächen
```

Der Stapeltest enthält Originalspeicherung, Bildbereinigung, Ausrichtung, OCR
und Speicherung des bereinigten Bilds. Kameratransfer, Kantenerkennung,
PDF-Export und UVDoc sind in dieser Messung nicht enthalten. Die GUI-Messung
verwendet simulierte Kamerabilder; `max_event_gap` misst Julia-Ereignisse,
keine Browser-Bildrate. Kompilierung und Modellinitialisierung separat betrachten.

Messungen in einer länger laufenden MCP-/Revise-Testsitzung sind getrennt zu
bewerten: deren zusätzlich geladener Entwicklungs- und Diagnosezustand erreichte
früher die Datenallokationsgrenze. Ein 1-GiB-GC-Ziel führte außerdem zu häufigen
vollständigen Sammlungen und Pausen von etwa 440 ms. Der normale Launcher nutzt
die oben geprüfte 2-GiB-Einstellung bei unveränderten harten Speichergrenzen.

Die GPU-Prüfungen in `tools/test_gpu_images.jl` vergleichen Bild und OCR mit dem
bisherigen Verfahren, prüfen Rotation, Leerbilder, UVDoc, Zuschnitt, Textregionen,
unabhängige Ergebnisbilder sowie wiederholte Größenwechsel und konstante
Puffer-/Planidentitäten. Bei sechs Größenwechselzyklen und zwölf anschließenden
aufgewärmten OCR-Wiederholungen wuchs der jeweilige GPU-Pool nicht weiter.
Die Messungen ersetzen keinen längeren Betrieb mit der montierten Kamera.

Historische Messungen vor der GPU-Vorverarbeitung stehen in
[`gen/performance-2026-10-12.json`](../gen/performance-2026-10-12.json) und
[`gen/responsiveness-2026-10-12.json`](../gen/responsiveness-2026-10-12.json).

## Fehler korrigieren

Die Blatterkennung versucht bei ungleichmäßiger Beleuchtung zusätzlich lokale
Helligkeitsschwellen und prüft die tatsächlichen Kanten. Dafür ist keine Farbe
nötig. Gewellte Ränder werden innerhalb einer begrenzten Abweichung zugelassen.
Am 13.10.2026 bestanden 26 synthetische Erkennungs-/Auslöseprüfungen und acht
Prüfungen an der montierten Kameraaufnahme (Farbe, Graustufen und reine
Holzausschnitte). Die Erkennung dieser Aufnahme mit 4624 × 3472 Pixeln benötigte
aufgewärmt etwa 65 ms. Das ist die Blatterkennung, nicht Verarbeitung und OCR.
[Prüfprotokoll](../gen/detection-tests.log).

Eine Aufnahme in der Leiste auswählen; die Automatik pausiert dabei.

- **Seite neu aufnehmen:** die richtige Seite unter die Kamera legen und klicken.
  Position und Zuordnung der ausgewählten Aufnahme bleiben erhalten.
- **Davor scannen:** eine fehlende Seite vor der ausgewählten Aufnahme einfügen.
- **90° drehen:** Bild und OCR werden gemeinsam neu verarbeitet.
- **Zuschneiden:** im Originalbild oben links, oben rechts, unten rechts,
  unten links anklicken. Das korrigiert einen falsch erkannten Blattrand.
  Erneutes Klicken auf den Knopf bricht den Zuschnitt ab.
- **Entfernen**, **Früher**, **Später**: doppelte Aufnahmen entfernen oder die
  Reihenfolge korrigieren. Die Zuordnung als Vorder-/Rückseite separat prüfen.
- **Seite zuordnen:** Vorderseite, Rückseite oder ausdrücklich einseitige Aufnahme.
  Fehlende Rückseiten blockieren die Archivierung, bis die Zuordnung korrigiert ist.
- **Neues Dokument** trennt vor der ausgewählten Seite; **Zusammenfügen** verbindet
  sie mit dem vorigen Dokument. Die anfängliche Zuordnung ist ein Dokument pro Blatt.
- **Ins PDF / auslassen:** eine fälschlich als leer erkannte Seite behalten oder
  eine ungewollte Seite gezielt auslassen.
- Ein OCR-Wort im Bild anklicken, den Text im Eingabefeld korrigieren und Enter
  drücken. Bild und Position der Textebene bleiben erhalten.
- **Rückgängig** nimmt die letzte Änderung zurück (bis zu 20 Schritte pro Sitzung).

Jede Aufnahme und Änderung wird im Entwurf gespeichert. Die Originalbilder
werden bei Korrekturen nicht gelöscht. Zum Fortsetzen denselben `dir` öffnen.
Rückgängig-Verlauf und Kamera-Automatik werden nicht über einen Neustart hinweg
wiederhergestellt. Eine unterbrochene Archivierung lässt sich erneut starten;
bereits zugeteilte Nummern werden dabei wiederverwendet. Nach Beginn der
Archivierung ist der Entwurf gegen weitere Seitenänderungen gesperrt.

**Beenden** bzw. `close(ui)` schließt Kamera und Entwurf. Das Archiv wird
separat mit `close(archive)` geschlossen. Ein erneutes Scannen beginnt mit einem
neuen Entwurfsverzeichnis. Eine zweite GUI darf denselben Entwurf nicht gleichzeitig
öffnen.
`close(archive)` wartet noch ausstehende Klassifikationen ab. Anschließend
`close(classifier)` aufrufen, wenn das Modell nicht weiterverwendet wird.
Selbst übergebene OCR-Modelle mit `close(ocr)` schließen; dadurch werden auch
deren GPU-Pläne, Gewichte und Eingabepuffer freigegeben. Eine GUI, die ihr
OCR-Modell selbst erzeugt hat, schließt es beim Beenden des Entwurfs.
Nach dem Schließen aller Entwürfe und Archive beendet `close_processing!()`
den gemeinsamen Verarbeitungsprozess und gibt dessen GPU-Speicher frei.
Die nächste Modellkonstruktion startet ihn erneut. Explizit übergebene lokale
GPU-Backends behalten ihre bisherige Threadbindung und sind von dieser
Prozesstrennung ausgenommen.

## Was vor dem dauerhaften Einsatz noch geprüft werden muss

Die automatisierten Tests prüfen unter anderem Entwurfswiederaufnahme,
Rückgängig, Ersetzen, Drehung, Wortkorrektur, Dokumentgrenzen, Fehlerbehandlung
und die feste Verbindung zwischen Dokumentnummer und PDF. Am 12.10.2026
bestanden 277 Scanner-Tests, 82 GPU-Prüfungen und 22 GUI-Tests.
Zusätzlich geprüft sind verzögerte Bildantworten nach einem Seitenwechsel,
bedienbare Schaltflächen bei blockierter Bildverarbeitung und das Bewahren
der Originalaufnahme beim Ausfall des Verarbeitungsprozesses. Das ersetzt keine
Erprobung der endgültigen Halterung: Beleuchtung, Verwacklung, stark ähnliche
Seiten und die tatsächliche Geschwindigkeit beim Blättern müssen dort mit
repräsentativen Dokumenten geprüft werden. Die Oberfläche hilft, Fehler direkt
zu sehen und zu korrigieren; sie garantiert keine fehlerfreie OCR.
