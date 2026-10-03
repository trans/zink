# Zink

Zink is a Crystal interpreter for Z-machine text adventures. It runs text-mode
version 3, 4, and 5 story files and exposes a JSON view of the object tree and
globals.

## Run

Requires Crystal 1.19.1 or newer.

```sh
crystal run src/main.cr -- path/to/story.z5
```

Or build an executable with `just build` and run `bin/zink path/to/story.z5`.
Use `--worldview` to boot a story, submit `look`, and print its state as JSON.
Use `--record-actions FILE` to record commands and keypresses, then
`--playback-commands FILE` to replay them. Playback returns to keyboard input
when the file ends. If a story requests playback without that option, the
console prompts for a command file. `--debug` prints VM instruction addresses
to standard error.

```sh
crystal spec
```

The suite includes the licensed CZECH interpreter checks for v3, v4, and v5. A
separate v4 art story smoke test can be run after downloading
[`art.z4`](https://ifarchive.org/if-archive/games/if-artshow/year2000/art.z4):

```sh
ZINK_ART_V4_STORY=/path/to/art.z4 crystal spec spec/integration/art_v4_spec.cr
```

That story stays outside the repository. The test fixture is the IF Art Show
2000 release (SHA-256 `5bb9d312c61f6af47c7d67fd138adf338ef3dba36163a0177da5904e49d6a962`).

## State API

`Zink::VM#worldview` returns a snapshot of the objects and all 240 global
variables. `Worldview#globals` is keyed by Z-machine variable number (16–255).
Each `WorldObject#property_bytes` entry contains the complete property data;
`properties` retains the one-byte or first-word values. The `location` field
uses global 16 in version 3. Later versions do not reserve a location global,
so their `location` field is zero.

`VM#export_save` and `VM#import_save` transfer execution state. The snapshot is
JSON serializable. `VM#export_save_for_persistence` rewinds to the latest input
instruction so a restored session can wait for a new command.

For embedded playback, pass `command_script:` to `ConsoleIO` or `ScriptedIO`.
Call `VM#select_input_stream(1)` to start playback immediately, or let the story
select it with `input_stream 1`.

## Code layout

- `Memory`, `Header`, and `Story` own story bytes and file metadata.
- `ObjectTable`, `TextDecoder`, and `Parser` handle version-dependent data.
- `VM` owns execution state. Opcode groups live in `src/zink/vm/`.
- `IODevice` handles host input and output. `WindowedIO` renders the upper
  Z-machine window as readable rows on a linear text device.

## Current limits

See [compatibility status](docs/compatibility.md) for tested versions and
prioritized follow-up work.

Zink advertises no colour, sound, graphics, mouse, or timed-input capability.
Transcript and command-file streams are available through `VM#transcript` and
`VM#recorded_commands`; Zink does not write those streams to files automatically.
Extended
ZSCII character mapping and true single-key terminal input are not implemented;
for `read_char`, type a key followed by Enter. Save/restore and auxiliary saves
use memory within a running VM; an application can persist snapshots through the
state API above. Command-file playback supports printable ASCII and bracketed
ZSCII key codes; extended ZSCII text is still incomplete.
The upper window is rendered as a linear transcript, so screen redraws cannot
match a full terminal display.
