"""Regenerates the nbformat goldens of hrafn's notebook tests with nbformat's own writer (pip install nbformat).

    python3 test/notebooks/make-goldens.py runtime/crates/hrafn/tests/fixtures/notebooks

`minimal.edited.ipynb`: minimal.ipynb with the source of cell 1 set to "print('done')\\nprint(2)\\n", written by
`nbformat.write`: what hrafn's writer must produce for the same edit, byte for byte.
"""
import sys
import nbformat

d = sys.argv[1]
nb = nbformat.read(f"{d}/minimal.ipynb", as_version=4)
nb.cells[1].source = "print('done')\nprint(2)\n"
nbformat.write(nb, f"{d}/minimal.edited.ipynb")
print("wrote", f"{d}/minimal.edited.ipynb")
