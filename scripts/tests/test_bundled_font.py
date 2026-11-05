"""The legacy Flutter renderer must load Regular, not the variable Thin origin."""
from pathlib import Path
import struct
import unittest


FONT = Path(__file__).resolve().parents[2] / "client/assets/fonts/NotoSansSC-Regular.ttf"


class BundledFontTest(unittest.TestCase):
    def test_default_face_is_regular_and_retains_the_full_weight_axis(self):
        data = FONT.read_bytes()
        count = struct.unpack_from(">H", data, 4)[0]
        tables = {
            data[offset:offset + 4]: struct.unpack_from(">II", data, offset + 8)
            for offset in range(12, 12 + count * 16, 16)
        }
        os2, _ = tables[b"OS/2"]
        self.assertEqual(struct.unpack_from(">H", data, os2 + 4)[0], 400)
        fvar, _ = tables[b"fvar"]
        start, _, axes, stride = struct.unpack_from(">HHHH", data, fvar + 4)
        weights = []
        for index in range(axes):
            offset = fvar + start + index * stride
            if data[offset:offset + 4] == b"wght":
                weights.append(tuple(value / 65536 for value in
                                     struct.unpack_from(">iii", data, offset + 4)))
        self.assertEqual(weights, [(100, 400, 900)])
        # Reject a damaged or partially written font, including its glyph tables.
        padded = data + bytes((-len(data)) % 4)
        checksum = sum(value[0] for value in struct.iter_unpack(">I", padded)) & 0xffffffff
        self.assertEqual(checksum, 0xB1B0AFBA)


if __name__ == "__main__":
    unittest.main()
