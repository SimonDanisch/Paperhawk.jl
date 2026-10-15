# Nummeriertes Dokumentarchiv

Das erste Dokument bekommt automatisch die Nummer **1**, das zweite **2**, und
so weiter. Du heftest die Originale genau in Scan-Reihenfolge in deinen Ordner.
Die Nummer im Suchergebnis entspricht der Position des Dokuments im Ordner.
Ein mehrseitiges Dokument behält eine gemeinsame Nummer. Kategorie, Absender,
Datum, Titel und OCR-Text stehen in einer lokalen SQLite-Datenbank. Eine spätere
Korrektur der Kategorie ändert weder Reihenfolge noch Nummer oder PDF-Pfad.

## Archivieren und Finden

Paperhawk archiviert aus der Oberfläche heraus (**Geprüft · Archivieren**, siehe
`docs/gui.md`). Mit `scanner(; classify = true)` fasst das lokale LLM jedes
archivierte Dokument im Hintergrund zusammen. Ein neues Archiv beginnt bei 1;
beim späteren Weiterarbeiten setzt es die Nummerierung fort. Die Kategorie
dient zum digitalen Finden, abgeheftet wird in Scan-Reihenfolge.

Durchsuchen und korrigieren aus Julia:

```julia
using Paperhawk
archive = DocumentArchive(Paperhawk.data_dir("archiv"))
search_documents(archive, "Stadtwerke März")
search_documents(archive; category="Rechnungen", date_from="2026-01-01", date_to="2026-12-31")
search_documents(archive; number=1)
document_record(archive, 1)
update_document!(archive, 1; title="Strom März 2026", category="Rechnungen")
close(archive)
```

Ohne Oberfläche, mit eigenem Klassifikator auf einer bestimmten GPU:

```julia
classifier = BonsaiClassifier(; select = "RTX 4000")   # Bonsai 2, 27B, ternär quantisiert
archive = DocumentArchive(Paperhawk.data_dir("archiv"); classifier)
records = wait_archive(archive)   # wartet auf die ausstehenden Zusammenfassungen
close(archive); close(classifier)
```

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
gleichzeitig öffnen. Wiederholtes Archivieren derselben Aufnahmen liefert das
bereits archivierte Dokument zurück, auch nach einem unterbrochenen Archivieren.

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
