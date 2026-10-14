`ocr-curved-footer.png` contains only the generic footer sentence cropped from
a local camera capture; it contains no invoice or personal identifiers.

Expected text: `Diese Rechnung wurde maschinell erstellt und ist ohne Unterschrift gültig`

This exercises PP-OCRv6 medium recognition of a bent baseline. The usual
48-pixel-high input makes its letters too narrow; a wider retry restores the
sentence. Run `tools/test_ocr_retry.jl` on the OCR model's owning GPU thread:

```julia
using Paperhawk
include("tools/test_ocr_retry.jl")
ocr = PaddleOCR()
try
    Paperhawk.ongpu(check_ocr_width_retry, ocr)
finally
    close(ocr)
end
```

Use `tools/bounded-julia` and the current desktop's `DISPLAY`/`XAUTHORITY`, as
with the other GPU checks. Do not start another GPU model beside the scanner.
