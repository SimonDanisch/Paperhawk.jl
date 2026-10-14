# Nummeriertes Dokumentarchiv

Das erste Dokument bekommt automatisch die Nummer **1**, das zweite **2**, und
so weiter. Du heftest die Originale genau in Scan-Reihenfolge in deinen Ordner.
Die Nummer im Suchergebnis entspricht der Position des Dokuments im Ordner.
Ein mehrseitiges Dokument behält eine gemeinsame Nummer. Kategorie, Absender,
Datum, Titel und OCR-Text stehen in einer lokalen SQLite-Datenbank. Eine spätere
Korrektur der Kategorie ändert weder Reihenfolge noch Nummer oder PDF-Pfad.

## Vorbereitung

```julia
using Paperhawk

# Einmalig werden die Modellgewichte geladen, danach bleiben sie lokal.
classifier = BonsaiClassifier()   # Bonsai 2, 27B, ternär quantisiert, GPU
archive = DocumentArchive("mein-archiv"; classifier)
```

Ein neues Archiv beginnt bei 1; beim späteren Weiterarbeiten setzt es die
Nummerierung fort. Nummernblätter oder Beschriftungen auf dem Papier sind dafür
nicht nötig. Die Kategorie dient zum digitalen Finden, abgeheftet wird weiterhin
in Scan-Reihenfolge.

## Scannen und Finden

```julia
cam = PhoneCamera()
ocr = PaddleOCR()
# Für Dokumente aus jeweils einem beidseitigen Blatt:
scanner = start(cam; ocr, archive, duplex=true, duplex_order=:interleaved,
                grouping=:sheet, trigger=Trigger(hold=0.25))
# Blatt 1 vorne, Blatt 1 hinten, Blatt 2 vorne, Blatt 2 hinten, …
pdfs = stop!(scanner)
close(cam); close(ocr)

# Die PDFs existieren bereits. Auf die Metadaten nur warten, wenn benötigt:
records = wait_archive(archive)
search_documents(archive, "Stadtwerke März")
search_documents(archive; category="Rechnungen", date_from="2026-01-01", date_to="2026-12-31")
search_documents(archive; number=1)
document_record(archive, 1)
update_document!(archive, 1; title="Strom März 2026", category="Rechnungen")

close(archive)       # ausstehende Klassifikationen abschließen
close(classifier)
```

`grouping=:sheet` vergibt eine Nummer je physischem Blatt. Bei Duplex gehören
Vorder- und Rückseite zusammen. Für Dokumente mit mehreren Blättern verwende
`grouping=:batch` (Standard) und beende den Scan mit `stop!` nach dem jeweiligen
Dokument. Der nächste Scan im selben Archiv erhält die nächste Nummer.

Zwei Aufnahmereihenfolgen werden unterstützt:

- `duplex_order=:interleaved`: ein Blatt vorne aufnehmen, umdrehen, hinten
  aufnehmen, dann das nächste Blatt.
- `duplex_order=:stack`: erst alle Vorderseiten, dann die Rückseiten in
  umgekehrter Blattreihenfolge. Das ist der bisherige Duplex-Ablauf.

Auch leere Rückseiten aufnehmen: Sie werden beim Zusammenstellen entfernt,
ihre Zuordnung zum Blatt bleibt in der Datenbank erhalten. Bei einer ungeraden
Anzahl Duplex-Aufnahmen stoppt die Archivierung vor der Nummernvergabe. Eine
gerade Anzahl beweist allerdings nicht, dass kein Blatt ausgelassen wurde;
die gewählte Reihenfolge muss eingehalten werden. Der Bildinhalt allein kann
Vorder- und Rückseiten nicht eindeutig zuordnen. Die automatische Erkennung
von Dokumentgrenzen bei gemischten mehrblättrigen Dokumenten ist nicht implementiert.
UVDoc kann mit `dewarper=uvdoc()` zugeschaltet werden.

## Dateien und Modell

`archive.sqlite` enthält Dokumente, OCR-Volltext, Metadaten und eine Tabelle
`sides` mit Blattnummer, Vorder-/Rückseite, Rohdatei und zugehöriger PDF-Seite.
Bei alten Aufnahmen ohne bekannte Paarung bleibt die Seite als `unknown`
gekennzeichnet. Der SQLite-FTS5-Index durchsucht Text und Metadaten und gewichtet
Treffer in Titel und Absender höher. Groß-/Kleinschreibung und Akzente werden
ignoriert; `marz` findet `März`, `versicher` findet `Versicherung`. Suchbegriffe
werden mit UND verbunden; reine Zahlen suchen nach der Dokumentnummer.
Filter: `category`, `sender` (exakt), `number`, `date_from`, `date_to`.
Mit `limit=100, offset=0` lassen sich Ergebnisse seitenweise abrufen.

Daneben enthält das Archiv `documents/000001.pdf`, `text/000001.txt` und
`records/000001.json`. Diese Dateien bleiben die Grundlage für einen Wiederaufbau
der Datenbank. Bestehende Archive werden beim Öffnen automatisch indiziert und
nach einem unterbrochenen Update abgeglichen. In `numbers/` stehen vergebene
Nummern, in `sources/` die Zuordnungen zu Rohaufnahmen. Zum Sichern das Archiv
schließen und den gesamten Ordner kopieren. Nur ein Schreiber kann ein Archiv
gleichzeitig öffnen. Wiederholtes Importieren derselben Rohdateipfade liefert
das bereits archivierte Dokument zurück.

Die Klassifikation liest ausschließlich den OCR-Text lokal über BonsaiRunner.
Sie läuft nach dem Speichern in einer Warteschlange. Modell und OCR teilen sich
die GPU; während gleichzeitiger Verarbeitung können beide langsamer werden.
Ohne `classifier` funktioniert das Archiv ebenfalls; ausstehende Dokumente werden
beim späteren Öffnen mit einem Klassifikator nachgeholt.

Ein Modellfehler lässt PDF, Text und Nummer bestehen. Fehlerhafte Antworten oder
fehlender Text setzen `status="needs_review"`; mit
`retry_classification!(archive, 1)` lässt sich ein Eintrag erneut verarbeiten.
Manuelle Korrekturen haben Vorrang vor einer laufenden Modellantwort. Modellangaben
sind Vorschläge; auch `needs_review=false` garantiert keine inhaltliche Richtigkeit.

Standardmäßig stehen 4096 Tokens für Prompt, OCR-Text und Antwort zur Verfügung.
Zu lange Dokumente werden zur Prüfung markiert, nicht still abgeschnitten.
Bei Bedarf `BonsaiClassifier(context=8192)` verwenden; das benötigt mehr Speicher.
Eigene Kategorien können beim Erstellen eines neuen Archivs mit
`DocumentArchive(path; classifier, categories=["Rechnungen", "Briefe", "Sonstiges"])`
festgelegt werden. Die Auswahl wird in `archive.toml` gespeichert.

## Erprobter Stand

Am 10.10.2026 auf der Radeon RX 7900 XTX getestet: Eine gerenderte
Beispielrechnung wurde mit PP-OCRv6 gelesen, als `000001.pdf` gespeichert und
von Bonsai mit richtigem Absender, Datum und Kategorie versehen. PDF-Speichern
und Einreihen dauerten nach abgeschlossener OCR 0,32 Sekunden, die nachgelagerte
Klassifikation 25 Sekunden. Ein weiterer synthetischer Versicherungsbrief
wurde in 19,3 Sekunden korrekt zugeordnet. Das sind einzelne Beispiele,
kein Qualitätstest über eine größere Dokumentensammlung. Der erste LLM-Aufruf
benötigte einschließlich Kompilierung 60 Sekunden; das erste Laden und OCR
haben zusätzliche Kompilierungskosten.
