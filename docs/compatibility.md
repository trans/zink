# Compatibility status

Zink targets the text portions of Z-machine versions 3, 4, and 5. The
[Z-machine Standard 1.1](https://inform-fiction.ifarchive.org/zmachine/standards/z1point1/)
defines the expected behavior.

| Area | Current evidence | Next work |
| --- | --- | --- |
| Core instructions, variables, objects, and properties | Licensed CZECH 0.8 stories pass all non-visual checks: v3 349/349, v4 367/367, v5 406/406. | Add tests when a new story exposes a gap. |
| Real story execution | Zork I/II/III v3 and Solid Gold Zork I v5 were played through scripted sequences. The IF Art Show 2000 `art.z4` passes an optional smoke test. | Broaden v4 and v5 playthroughs. |
| Keyboard input | Line input works. `read_char` uses the first character of a line. | Add a single-key terminal input method; keep scripted I/O deterministic. |
| Command-file input | Output stream 4 records commands in memory. `--record-actions` writes replayable files; `--playback-commands` or `input_stream 1` plays them back and returns to keyboard at EOF. | Extend command-file text support beyond ASCII. |
| Screen | Both text windows render into a linear transcript. Cursor placement and redraws cannot be represented fully there. | Add a terminal screen backend while keeping the transcript backend. |
| Characters and timed input | ASCII text works. Extended ZSCII is incomplete; timed input is unadvertised. | Add character mapping, then timed reads if a story requires them. |
| Media and styles | Colour, sound, graphics, and mouse are unadvertised. Styles are accepted without visual effects. | Implement only with an output backend that can display them. |
| Save files | The VM supports in-memory saves and JSON state export. | Add file-backed or Quetzal saves if standalone players need them. |

Run `crystal spec` for the deterministic checks. To run the external v4 art
story, download the file linked in the README and set `ZINK_ART_V4_STORY` as
shown there. Its binary is not stored in this repository.
