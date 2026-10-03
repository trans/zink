# TODO

## Worldview reads past the end of the object table

Fixed 2026-10-03: `ObjectTable#object_count` bounds the scan by the earliest
property table address. `VM#worldview` uses that count.

`VM#worldview` walks objects 1 to 255 and stops only when an object's
property table address is 0. Past the last real object it decodes property
data as object entries. Zork I has 250 objects (its compile chart,
`zork1.chart` in github.com/historicalsource/zork1, says so), and zink
returns 255; the last five are garbage, e.g.:

```
251: "swa   c "  parent=25
253: "kWpxm"     parent=177
254: "It's "     parent=23
```

Fix: the object table ends where the first property table begins, so
`count = (lowest property table address - object table start) / entry size`
(9 bytes per entry in v1–3, 14 in v4+). Loop to that count.

Found 2026-10-03 while sizing the world state for infocomic's DM (see
infocomic's DM-DESIGN.md).

## For infocomic's DM: globals and raw property data

Added 2026-10-03: `Worldview#globals` maps variable numbers 16–255 to their
values, and `VM#global` reads one global. `WorldObject#property_bytes` holds
the complete bytes for each property; `properties` remains available for
single-byte and first-word values.

infocomic's DM will get a slice of the world each turn (DM-DESIGN.md,
section 3.1). Two things it would need from zink:

- **Global variables.** Read access to the globals table (variables 16 and
  up): score and moves in v3's status line (variables 17 and 18), and the
  flags that conditional exits test (e.g. Zork I's `MAGIC-FLAG`). Only the
  location (variable 16) is exposed today, inside `worldview`.
- **Property length or bytes.** `WorldObject#properties` holds one `UInt16`
  per property, but v3 exits come in five sizes: 1 byte (a room), 2 (a
  "you can't go that way" message), 3 (a routine), 4 (a room, the flag
  global it depends on, a message) and 5 (a room, the door object, a
  message). Decoding the 4- and 5-byte kinds needs the length and all the
  bytes.

## v4/v5 support

Text-mode v4/v5 execution added 2026-10-03. The Solid Gold Zork I v5 story
boots, accepts commands, saves/restores, and opens InvisiClues. Optional
interpreter features still to implement are listed in README.md.

infocomic has the Solid Gold edition of Zork I
(`stories/zork1-invclues-r52-s871125.z5`, release 52, 1987), Zork I with
Infocom's InvisiClues built in (the `HINT` command). This story prompted the
v5 work.
