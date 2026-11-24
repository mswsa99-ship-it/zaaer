"""Extract an exact set of regular members. Reject traversal, links, extras and duplicate names."""
import pathlib
import sys
import tarfile
archive, destination, *expected = sys.argv[1:]
with tarfile.open(archive, 'r:') as source:
    members = source.getmembers()
    if sorted(m.name for m in members) != sorted(expected) or not all(m.isfile() for m in members):
        raise SystemExit('ERROR: invalid backup archive members')
    for member in members:
        with source.extractfile(member) as src, open(pathlib.Path(destination) / member.name, 'wb') as out:
            while block := src.read(1024 * 1024):
                out.write(block)
