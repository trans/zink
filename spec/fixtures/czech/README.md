# CZECH test stories

CZECH 0.8 is Amir Karger's Z-machine interpreter check. `README.txt` contains
the original copyright notice and license permitting redistribution with that
notice preserved. The original source, v5 story, and reference output came from
the [IF Archive](https://ifarchive.org/if-archive/interpreters-infocom-zcode/tools/czech_0_8.zip).

`czech.z3` and `czech.z4` were built from the included `czech.inf` with Inform
6.45 using:

```sh
inform6 -v3 czech.inf czech.z3
inform6 -v4 czech.inf czech.z4
```

Frotz and Zink both report 349 passed and 0 failed for v3, 367 and 0 for v4,
and 406 and 0 for v5. The printed visual checks and interpreter header details
vary by terminal.
