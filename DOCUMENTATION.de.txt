R4CSS
=====

R4CSS.R4P stellt den wiederverwendbaren CSS- und Layoutkern unter der Rolle
`text.css` bereit. Parser und Kaskade liegen in `r4os.css`, Reflow und die
strukturelle Software-Renderliste in `r4os.web_layout`.

Operationen:

1 - Faehigkeiten abfragen
2 - ein CSS-Stylesheet parsen und begrenzte Statistik ausgeben
3 - ein HTML-Dokument samt STYLE-Regeln layouten und Statistik ausgeben
4 - deterministischer CSS-, Kaskaden-, Layout- und Reflow-Selbsttest

Der Zielbestand umfasst Typ-, Klassen-, ID-, Attribut-, Nachfahren- und
Kindselektoren, die benoetigten Struktur- und Zustands-Pseudoklassen,
BEFORE/AFTER-Inhalte, Kaskade, Vererbung, Custom Properties, Boxmodell,
Block-/Inlinefluss sowie einen begrenzten Flex- und Grid-Grundbestand.

R4CSS liegt als R4P-Modul und SDK-Code im Userland. Weder Kernel noch R4DRAW
kennen CSS, DOM oder Webseitenlayout. Die R4P-Komfortoperationen verwenden
einen serialisierten, fest begrenzten Arbeitspuffer.
