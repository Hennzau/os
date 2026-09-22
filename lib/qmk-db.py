#!/usr/bin/env python3
"""compile_commands.json for the QMK keymap, so clangd can read it.

QMK never compiles keymap.c on its own: quantum/keymap_introspection.c
includes it, so QMK's own database (qmk compile --compiledb, written in
QMK_HOME) has no entry for our file. This takes that translation unit's
command - the one the keymap is actually compiled with - and points it at the
keymap in this repo.

Two things make the command unusable as it stands. It was recorded inside the
qmk distrobox, so its `-isystem` paths into the ARM toolchain do not exist out
here; those headers are copied once into ~/.cache/elv-qmk/sysroot and the
paths rewritten. And it carries -Werror and the build's dependency-file
flags, which belong to a build, not to an editor.

The result is written to usr.d/50-containers/, *not* beside keymap.c: that
directory is inside the layer's usr/ tree, and `apply-usr` copies everything
there into the image. clangd looks for compile_commands.json in the file's
directory and every parent, so the layer root works and ships nothing.
"""

import json, os, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYMAP = os.path.join(
    REPO,
    "usr.d/50-containers/usr/share/qmk/userspace/keyboards/splitkb"
    "/halcyon/elora/rev2/keymaps/elv/keymap.c",
)
OUT_DIR = os.path.join(REPO, "usr.d/50-containers")
CACHE = os.path.expanduser("~/.cache/elv-qmk/sysroot")
QMK_HOME = os.environ.get("QMK_HOME", os.path.expanduser("~/qmk_firmware"))
# The unit that #includes the keymap; its command is the keymap's command.
HOST_TU = "quantum/keymap_introspection.c"
# A build's bookkeeping, and -Werror: an editor should not paint a file red
# for a warning the firmware build happens to refuse.
DROP_EXACT = {"-c", "-o", "-MMD", "-MP", "-Werror"}
DROP_WITH_ARG = {"-MF", "-MT", "-o"}


def die(msg):
    print(f"qmk-db: {msg}", file=sys.stderr)
    sys.exit(1)


def sysroot(path):
    """The box's copy of an absolute toolchain path, fetched once."""
    local = CACHE + path
    if not os.path.isdir(local):
        os.makedirs(os.path.dirname(local), exist_ok=True)
        print(f"  fetching {path} from the qmk box")
        if (
            subprocess.run(["podman", "cp", f"qmk:{path}", os.path.dirname(local) + "/"]).returncode
            != 0
        ):
            die(f"could not copy {path} out of the 'qmk' container")
    return local


def main():
    db_path = os.path.join(QMK_HOME, "compile_commands.json")
    if not os.path.exists(db_path):
        die(
            f"{db_path} is missing - build the firmware once with\n"
            "        qmk compile --compiledb -kb splitkb/halcyon/elora/rev2 -km elv"
        )
    db = json.load(open(db_path))
    entries = [e for e in db if e.get("file", "").endswith(HOST_TU)]
    if not entries:
        die(
            f"no {HOST_TU} entry in {db_path} - the database is from a build\n"
            "        that skipped it; touch the keymap and compile again"
        )
    entry = entries[0]
    cmd = entry.get("command")
    toks = cmd.split() if cmd else list(entry["arguments"])

    args, skip = [], False
    for tok in toks:
        if skip:
            skip = False
            continue
        if tok in DROP_WITH_ARG:
            skip = True
            continue
        if tok in DROP_EXACT or tok.endswith(".o") or tok.endswith(HOST_TU):
            continue
        if tok.startswith("/usr/lib/gcc/arm-none-eabi") or tok.startswith("/usr/arm-none-eabi"):
            tok = sysroot(tok)
        args.append(tok)
    # The keymap's own directory first, so its local headers are this repo's.
    args = [args[0], "-I" + os.path.dirname(KEYMAP)] + args[1:] + ["-c", KEYMAP]

    out = os.path.join(OUT_DIR, "compile_commands.json")
    json.dump(
        [{"directory": entry["directory"], "file": KEYMAP, "arguments": args}],
        open(out, "w"),
        indent=1,
    )
    print(
        f"  {os.path.relpath(out, REPO)}: {len(args)} arguments, "
        f"from {HOST_TU} in {os.path.relpath(db_path, os.path.expanduser('~'))}"
    )


main()
