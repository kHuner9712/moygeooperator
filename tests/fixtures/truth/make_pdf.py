#!/usr/bin/env python3
"""Generate tests/fixtures/truth/catalog-text.pdf — a REAL, extractable-text PDF
(SYNTHETIC fixture for the P0.2 extractor pipeline).

Run with pypdf installed:
    python tests/fixtures/truth/make_pdf.py
Writes catalog-text.pdf next to this script.
"""
from pypdf import PdfWriter
from pypdf.generic import DictionaryObject, NameObject, NumberObject, StreamObject

OUT = "catalog-text.pdf"

writer = PdfWriter()
page = writer.add_blank_page(width=612, height=792)

# Raw PDF content-stream operators drawing text with a standard Helvetica font.
content = b"".join(
    [
        b"BT\n/F1 24 Tf\n72 720 Td\n",
        b"(AC-100 Precision Cylinder 5000 PSI) Tj\n",
        b"0 -36 Td\n(AcmePrecision) Tj\n",
        b"0 -36 Td\n(Working pressure 5000 PSI, ISO 9001:2015) Tj\n",
        b"ET\n",
    ]
)

# Register a standard Type1 font as /F1.
font_obj = writer._add_object(
    DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
        }
    )
)
resources = DictionaryObject(
    {NameObject("/Font"): DictionaryObject({NameObject("/F1"): font_obj})}
)
page[NameObject("/Resources")] = resources
# Build a proper stream object carrying the content-stream operators.
stream = StreamObject()
stream.set_data(content)
stream[NameObject("/Length")] = NumberObject(len(content))
page[NameObject("/Contents")] = writer._add_object(stream)

with open(OUT, "wb") as fh:
    writer.write(fh)

print(f"wrote {OUT}")